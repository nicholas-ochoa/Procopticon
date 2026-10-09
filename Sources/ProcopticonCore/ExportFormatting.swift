import Foundation

/// A typed cell value for export.
public enum ExportValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case number(Double)
    case string(String)

    /// Numbers as numbers, dates as ISO 8601, anything else as the cell's text.
    public init(_ value: Any, text: String) {
        switch value {
        case let v as Double: self = v.isFinite ? .number(v) : .null
        case let v as any BinaryInteger: self = .integer(Int64(truncatingIfNeeded: v))
        case let v as Date: self = .string(v.formatted(.iso8601))
        default: self = .string(text)
        }
    }
}

/// The rows and visible columns of a table, as exported.
public struct ExportTable: Sendable {
    public struct Column: Sendable {
        public var title: String
        public var unit: String?

        public init(title: String, unit: String?) {
            self.title = title
            self.unit = unit
        }
    }

    public var columns: [Column]
    public var rows: [[ExportValue]]

    public init(columns: [Column], rows: [[ExportValue]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// JSON and CSV for exported tables, with typed values: numbers in base units (bytes, bytes/s,
/// percent, seconds), dates in ISO 8601, and null (JSON) or nothing (CSV) for unknown cells.
public enum ExportFormatting {
    /// `{"exported": …, "units": {title: unit}, "<root>": [{title: value, …}, …]}`, keys in column
    /// order.
    public static func json(_ table: ExportTable, root: String, date: Date = Date()) -> String {
        var out = "{\n"
        out += "  \"exported\": \(quote(date.formatted(.iso8601))),\n"
        let units = table.columns.compactMap { c in c.unit.map { "\(quote(c.title)): \(quote($0))" } }
        out += "  \"units\": {" + units.joined(separator: ", ") + "},\n"
        out += "  \(quote(root)): ["
        out += table.rows.enumerated().map { index, row in
            let fields = zip(table.columns, row).map { column, value in "\(quote(column.title)): \(json(value))" }
            return (index == 0 ? "\n" : "") + "    {" + fields.joined(separator: ", ") + "}"
        }.joined(separator: ",\n")
        out += table.rows.isEmpty ? "]\n}\n" : "\n  ]\n}\n"
        return out
    }

    /// RFC 4180: a header row of titles (with units), then one row per item.
    public static func csv(_ table: ExportTable) -> String {
        var lines = [table.columns.map { column in csvField(column.unit.map { "\(column.title) (\($0))" } ?? column.title) }.joined(separator: ",")]
        for row in table.rows {
            lines.append(row.map { value -> String in
                switch value {
                case .null: return ""
                case .integer(let v): return String(v)
                case .number(let v): return number(v)
                case .string(let s): return csvField(s)
                }
            }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func json(_ value: ExportValue) -> String {
        switch value {
        case .null: return "null"
        case .integer(let v): return String(v)
        case .number(let v): return number(v)
        case .string(let s): return quote(s)
        }
    }

    /// Up to six significant decimals, without a trailing ".0" on whole numbers.
    private static func number(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
