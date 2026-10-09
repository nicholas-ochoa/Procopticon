#include "CQuickJS.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "quickjs/quickjs.h"

struct qx_engine {
    JSRuntime *rt;
    JSContext *ctx;
    JSClassID row_class;
    /// The object whose fields are the expressions' variables. Its opaque pointer is the row being
    /// evaluated, and NULL in between.
    JSValue row;
    qx_field_getter getter;
    void *context;
    /// Compiled expressions by id; JS_UNDEFINED marks a free slot.
    JSValue *functions;
    int32_t function_count;
    int32_t function_capacity;
    /// When the running script is stopped, in CLOCK_UPTIME_RAW nanoseconds; 0 for no limit.
    uint64_t deadline;
    bool timed_out;
};

struct qx_out {
    JSContext *ctx;
    JSValue value;
    uint32_t length;
};

static int interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    qx_engine *e = opaque;
    if (e->deadline && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > e->deadline) {
        e->timed_out = true;
        return 1;
    }
    return 0;
}

static void start_clock(qx_engine *e, double timeout_seconds) {
    e->timed_out = false;
    e->deadline = timeout_seconds > 0 ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + (uint64_t)(timeout_seconds * 1e9) : 0;
    // The engine may be used from another thread than last time (any of a serial queue's).
    JS_UpdateStackTop(e->rt);
}

static char *copy_string(const char *s) {
    return strdup(s ? s : "");
}

/// The message of an exception ("TypeError: …").
static char *describe(JSContext *ctx, JSValueConst exception) {
    const char *text = JS_ToCString(ctx, exception);
    if (!text) {
        // Converting it threw too.
        JS_FreeValue(ctx, JS_GetException(ctx));
        return copy_string("Unknown error");
    }
    char *message = copy_string(text);
    JS_FreeCString(ctx, text);
    return message;
}

/// Takes the pending exception and returns its message.
static char *take_exception(JSContext *ctx) {
    JSValue exception = JS_GetException(ctx);
    char *message = describe(ctx, exception);
    JS_FreeValue(ctx, exception);
    return message;
}

/// Where a syntax error is, from its stack ("    at <expression>:3:1"); false if it doesn't say.
static bool error_position(JSContext *ctx, JSValueConst exception, int *line, int *column) {
    if (!JS_IsObject(exception)) {
        return false;
    }
    JSValue stack = JS_GetPropertyStr(ctx, exception, "stack");
    bool found = false;
    if (JS_IsString(stack)) {
        const char *text = JS_ToCString(ctx, stack);
        const char *at = text ? strstr(text, "<expression>:") : NULL;
        found = at && sscanf(at + strlen("<expression>:"), "%d:%d", line, column) == 2;
        JS_FreeCString(ctx, text);
    }
    JS_FreeValue(ctx, stack);
    return found;
}

/// The offset of the first closing bracket in `source` that closes nothing, ignoring strings and
/// comments; -1 if there's none.
static long unmatched_closer(const char *source) {
    int depth = 0;
    char quote = 0;
    for (const char *c = source; *c; c++) {
        if (quote) {
            if (*c == '\\' && c[1]) {
                c++;
            } else if (*c == quote) {
                quote = 0;
            }
        } else if (*c == '"' || *c == '\'' || *c == '`') {
            quote = *c;
        } else if (*c == '/' && c[1] == '/') {
            while (c[1] && c[1] != '\n') {
                c++;
            }
        } else if (*c == '(' || *c == '[' || *c == '{') {
            depth++;
        } else if ((*c == ')' || *c == ']' || *c == '}') && --depth < 0) {
            return c - source;
        }
    }
    return -1;
}

/// Takes the pending exception from compiling `source` (which the compiled code starts on line 2)
/// and returns its message, with where in `source` it is. An error after the source, in the code
/// around it, means the expression is incomplete ("cpu >" fails at what follows), or that it closes
/// a parenthesis it didn't open (the wrapper's own).
static char *take_compile_error(JSContext *ctx, const char *source) {
    JSValue exception = JS_GetException(ctx);
    char *message = describe(ctx, exception);
    int line, column;
    if (error_position(ctx, exception, &line, &column)) {
        int lines = 1;
        for (const char *c = source; *c; c++) {
            lines += *c == '\n';
        }
        char *located = NULL;
        long closer = line > lines + 1 ? unmatched_closer(source) : -1;
        if (closer >= 0) {
            // Its line and column in the source.
            line = 2;
            const char *line_start = source;
            for (const char *c = source; c < source + closer; c++) {
                if (*c == '\n') {
                    line++;
                    line_start = c + 1;
                }
            }
            column = (int)(source + closer - line_start) + 1;
            free(message);
            asprintf(&message, "SyntaxError: unexpected '%c'", source[closer]);
        }
        if (line > lines + 1) {
            JSValue name = JS_GetPropertyStr(ctx, exception, "name");
            const char *text = JS_IsString(name) ? JS_ToCString(ctx, name) : NULL;
            asprintf(&located, "%s: incomplete expression", text ? text : "SyntaxError");
            JS_FreeCString(ctx, text);
            JS_FreeValue(ctx, name);
        } else if (line >= 2 && lines == 1) {
            asprintf(&located, "%s (at column %d)", message, column);
        } else if (line >= 2) {
            asprintf(&located, "%s (line %d, column %d)", message, line - 1, column);
        }
        if (located) {
            free(message);
            message = located;
        }
    }
    JS_FreeValue(ctx, exception);
    return message;
}

static void discard_exception(JSContext *ctx) {
    JS_FreeValue(ctx, JS_GetException(ctx));
}

static JSValue field_getter(JSContext *ctx, JSValueConst this_val, int field) {
    qx_engine *e = JS_GetContextOpaque(ctx);
    void *row = JS_GetOpaque(this_val, e->row_class);
    // Outside an evaluation (an expression kept the object somewhere) there's nothing to read.
    if (!row) {
        return JS_UNDEFINED;
    }
    qx_out out = { ctx, JS_UNDEFINED, 0 };
    e->getter(e->context, row, field, &out);
    return out.value;
}

qx_engine *qx_engine_new(const char *const *field_names, int32_t field_count, qx_field_getter getter, void *context,
                         const char *prelude, size_t memory_limit, char **error) {
    qx_engine *e = calloc(1, sizeof *e);
    if (!e) {
        goto fail;
    }
    e->getter = getter;
    e->context = context;
    e->row = JS_UNDEFINED;
    e->rt = JS_NewRuntime();
    if (!e->rt) {
        goto fail;
    }
    JS_SetMemoryLimit(e->rt, memory_limit);
    // Dispatch queue threads have 512 KB stacks; deep recursion must fail well inside one.
    JS_SetMaxStackSize(e->rt, 256 * 1024);
    JS_SetInterruptHandler(e->rt, interrupt_handler, e);
    e->ctx = JS_NewContext(e->rt);
    if (!e->ctx) {
        goto fail;
    }
    JS_SetContextOpaque(e->ctx, e);

    JSClassDef def = { .class_name = "Row" };
    JS_NewClassID(e->rt, &e->row_class);
    if (JS_NewClass(e->rt, e->row_class, &def) < 0) {
        goto fail;
    }
    // Each field is a getter on the rows' prototype, read only when an expression uses it. The
    // prototype has no prototype itself, so `with` finds just the fields there, not toString & co.
    JSValue proto = JS_NewObjectProto(e->ctx, JS_NULL);
    JSCFunctionType function = { .getter_magic = field_getter };
    for (int32_t i = 0; i < field_count; i++) {
        JSValue get = JS_NewCFunction2(e->ctx, function.generic, field_names[i], 0, JS_CFUNC_getter_magic, i);
        JSAtom atom = JS_NewAtom(e->ctx, field_names[i]);
        JS_DefinePropertyGetSet(e->ctx, proto, atom, get, JS_UNDEFINED, JS_PROP_ENUMERABLE);
        JS_FreeAtom(e->ctx, atom);
    }
    JS_SetClassProto(e->ctx, e->row_class, proto);
    e->row = JS_NewObjectClass(e->ctx, e->row_class);

    if (prelude) {
        start_clock(e, 1);
        JSValue result = JS_Eval(e->ctx, prelude, strlen(prelude), "<prelude>", JS_EVAL_TYPE_GLOBAL);
        e->deadline = 0;
        if (JS_IsException(result)) {
            if (error) {
                *error = take_exception(e->ctx);
            } else {
                discard_exception(e->ctx);
            }
            qx_engine_free(e);
            return NULL;
        }
        JS_FreeValue(e->ctx, result);
    }
    return e;

fail:
    if (error) {
        *error = copy_string("Couldn't start the JavaScript engine");
    }
    if (e) {
        qx_engine_free(e);
    }
    return NULL;
}

void qx_engine_free(qx_engine *e) {
    if (e->ctx) {
        for (int32_t i = 0; i < e->function_count; i++) {
            JS_FreeValue(e->ctx, e->functions[i]);
        }
        JS_FreeValue(e->ctx, e->row);
        JS_FreeContext(e->ctx);
    }
    free(e->functions);
    if (e->rt) {
        JS_FreeRuntime(e->rt);
    }
    free(e);
}

int32_t qx_compile(qx_engine *e, const char *source, double timeout_seconds, char **error) {
    // The fields are variables through `with`. The line breaks keep a trailing // comment from
    // swallowing the closing parenthesis.
    static const char head[] = "(function (row) { with (row) return (\n";
    static const char tail[] = "\n); })";
    size_t source_length = strlen(source);
    size_t length = sizeof head - 1 + source_length + sizeof tail - 1;
    char *code = malloc(length + 1);
    if (!code) {
        if (error) {
            *error = copy_string("Out of memory");
        }
        return -1;
    }
    memcpy(code, head, sizeof head - 1);
    memcpy(code + sizeof head - 1, source, source_length);
    memcpy(code + sizeof head - 1 + source_length, tail, sizeof tail);

    start_clock(e, timeout_seconds);
    JSValue function = JS_Eval(e->ctx, code, length, "<expression>", JS_EVAL_TYPE_GLOBAL);
    e->deadline = 0;
    free(code);
    if (JS_IsException(function)) {
        if (e->timed_out) {
            discard_exception(e->ctx);
            if (error) {
                *error = copy_string("The expression took too long to compile");
            }
        } else if (error) {
            *error = take_compile_error(e->ctx, source);
        } else {
            discard_exception(e->ctx);
        }
        return -1;
    }
    if (!JS_IsFunction(e->ctx, function)) {
        JS_FreeValue(e->ctx, function);
        if (error) {
            *error = copy_string("Not an expression");
        }
        return -1;
    }

    int32_t id = 0;
    while (id < e->function_count && !JS_IsUndefined(e->functions[id])) {
        id++;
    }
    if (id == e->function_count) {
        if (e->function_count == e->function_capacity) {
            int32_t capacity = e->function_capacity ? e->function_capacity * 2 : 16;
            JSValue *functions = realloc(e->functions, sizeof(JSValue) * (size_t)capacity);
            if (!functions) {
                JS_FreeValue(e->ctx, function);
                if (error) {
                    *error = copy_string("Out of memory");
                }
                return -1;
            }
            e->functions = functions;
            e->function_capacity = capacity;
        }
        e->function_count++;
    }
    e->functions[id] = function;
    return id;
}

void qx_release(qx_engine *e, int32_t id) {
    if (id < 0 || id >= e->function_count) {
        return;
    }
    JS_FreeValue(e->ctx, e->functions[id]);
    e->functions[id] = JS_UNDEFINED;
}

qx_result qx_evaluate(qx_engine *e, int32_t id, void *row, double timeout_seconds, char **error) {
    if (id < 0 || id >= e->function_count || JS_IsUndefined(e->functions[id])) {
        if (error) {
            *error = copy_string("No such expression");
        }
        return QX_ERROR;
    }
    JS_SetOpaque(e->row, row);
    start_clock(e, timeout_seconds);
    JSValue result = JS_Call(e->ctx, e->functions[id], JS_UNDEFINED, 1, &e->row);
    qx_result outcome;
    if (JS_IsException(result)) {
        if (e->timed_out) {
            discard_exception(e->ctx);
            outcome = QX_TIMEOUT;
        } else {
            // Before the clock stops: the exception's toString is script too.
            if (error) {
                *error = take_exception(e->ctx);
            } else {
                discard_exception(e->ctx);
            }
            outcome = QX_ERROR;
        }
    } else {
        outcome = JS_ToBool(e->ctx, result) > 0 ? QX_TRUE : QX_FALSE;
        JS_FreeValue(e->ctx, result);
    }
    e->deadline = 0;
    JS_SetOpaque(e->row, NULL);
    return outcome;
}

static void set_value(qx_out *out, JSValue value) {
    JS_FreeValue(out->ctx, out->value);
    out->value = value;
}

void qx_out_number(qx_out *out, double value) {
    set_value(out, JS_NewNumber(out->ctx, value));
}

void qx_out_bool(qx_out *out, bool value) {
    set_value(out, JS_NewBool(out->ctx, value));
}

void qx_out_null(qx_out *out) {
    set_value(out, JS_NULL);
}

void qx_out_string(qx_out *out, const char *utf8, size_t length) {
    set_value(out, JS_NewStringLen(out->ctx, utf8 ? utf8 : "", utf8 ? length : 0));
}

void qx_out_date(qx_out *out, double seconds) {
    set_value(out, JS_NewDate(out->ctx, seconds * 1000));
}

void qx_out_array(qx_out *out) {
    set_value(out, JS_NewArray(out->ctx));
    out->length = 0;
}

void qx_out_append_string(qx_out *out, const char *utf8, size_t length) {
    if (!JS_IsArray(out->value)) {
        return;
    }
    JSValue element = JS_NewStringLen(out->ctx, utf8 ? utf8 : "", utf8 ? length : 0);
    JS_DefinePropertyValueUint32(out->ctx, out->value, out->length++, element, JS_PROP_C_W_E);
}
