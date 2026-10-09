#ifndef CQUICKJS_H
#define CQUICKJS_H

// A small bridge to the vendored QuickJS-ng engine (quickjs/), for evaluating JavaScript
// expressions over rows of named fields: a process's `cpu`, `name`, `memory` and so on. Swift only
// sees this interface, so it never handles JSValues or their reference counts.
//
// Each engine is one QuickJS runtime and context with a memory limit and no host APIs (no files,
// network or timers). It isn't thread-safe: use an engine from one thread, or one serial queue, at
// a time.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

typedef struct qx_engine qx_engine;
/// Receives a field's value; see the qx_out_ functions.
typedef struct qx_out qx_out;

/// Writes field number `field` of `row` to `out` with one of the qx_out_ functions. Writing nothing
/// leaves the field undefined.
typedef void (*qx_field_getter)(void *_Nullable context, void *row, int32_t field, qx_out *out);

/// Creates an engine whose expressions see `field_count` fields named `field_names`, read lazily
/// through `getter` (passed `context`). `prelude`, if given, runs first, e.g. to define constants.
/// Returns NULL if the prelude fails, with a message in *error (free it with free()).
qx_engine *_Nullable qx_engine_new(const char *_Nonnull const *_Nonnull field_names, int32_t field_count,
                                   qx_field_getter getter, void *_Nullable context,
                                   const char *_Nullable prelude, size_t memory_limit,
                                   char *_Nullable *_Nullable error);
void qx_engine_free(qx_engine *engine);

/// Compiles `source`, a JavaScript expression in which the fields are variables. Returns an id for
/// qx_evaluate, or -1 with a message in *error (free it with free()).
int32_t qx_compile(qx_engine *engine, const char *source, double timeout_seconds, char *_Nullable *_Nullable error);
/// Frees a compiled expression.
void qx_release(qx_engine *engine, int32_t id);

typedef enum {
    QX_FALSE = 0,
    QX_TRUE = 1,
    /// The expression threw; *error has the message.
    QX_ERROR = -1,
    /// The expression ran past its time limit and was stopped.
    QX_TIMEOUT = -2,
} qx_result;

/// Evaluates expression `id` with the fields of `row`; true when the result is truthy.
qx_result qx_evaluate(qx_engine *engine, int32_t id, void *row, double timeout_seconds,
                      char *_Nullable *_Nullable error);

void qx_out_number(qx_out *out, double value);
void qx_out_bool(qx_out *out, bool value);
void qx_out_null(qx_out *out);
void qx_out_string(qx_out *out, const char *_Nullable utf8, size_t length);
/// A Date, from seconds since 1970.
void qx_out_date(qx_out *out, double seconds);
/// Starts an empty array; add elements with qx_out_append_string.
void qx_out_array(qx_out *out);
void qx_out_append_string(qx_out *out, const char *_Nullable utf8, size_t length);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
