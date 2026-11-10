import Foundation

/// Reads saved lists (filters, highlight rules, alert rules) that no longer decode as a whole.
public enum LenientList {
    /// The entries of a JSON array that decode as `T`, in order; nil when `data` isn't a JSON array.
    /// One entry that can't be read (a rule saved by a newer version, say) then costs that entry
    /// rather than the whole list.
    public static func decode<T: Decodable>(_ type: T.Type = T.self, from data: Data) -> [T]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return entries.compactMap { entry in
            guard JSONSerialization.isValidJSONObject(entry),
                  let one = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(T.self, from: one)
        }
    }
}
