import Foundation

/// Plans the fewest moves (plus inserts) that turn one ordering of a list into another, for
/// updating table rows in place. The elements on a longest increasing subsequence of their current
/// positions stay put; each other element moves to just after its predecessor in the target order.
/// Moving whatever belongs at each position instead moved every following row up by one whenever a
/// single row moved down.
public enum ListReorder {
    public enum Step: Equatable, Sendable {
        /// Move the element at `from` so it ends up at `to` (indexes before and after the move).
        case move(from: Int, to: Int)
        /// Insert `target[targetIndex]`, which isn't in the current list, at `at`.
        case insert(at: Int, targetIndex: Int)
    }

    /// Steps that turn `current` into `target`, applied in order. Every element of `current` must
    /// be in `target` (apply removals first); elements must be unique.
    public static func steps<T: Hashable>(from current: [T], to target: [T]) -> [Step] {
        var position: [T: Int] = [:]
        position.reserveCapacity(current.count)
        for (i, element) in current.enumerated() {
            position[element] = i
        }
        // Current positions of the existing elements, in target order.
        let sequence = target.compactMap { position[$0] }
        let staying = Set(longestIncreasingSubsequence(sequence))

        var list = current
        var steps: [Step] = []
        var previous: T?
        for (targetIndex, element) in target.enumerated() {
            defer { previous = element }
            if let original = position[element], staying.contains(original) {
                continue
            }
            let after = previous.flatMap { p in list.firstIndex(of: p) }
            if position[element] != nil {
                let from = list.firstIndex(of: element)!
                list.remove(at: from)
                let to = after.map { $0 < from ? $0 + 1 : $0 } ?? 0
                list.insert(element, at: to)
                if from != to {
                    steps.append(.move(from: from, to: to))
                }
            } else {
                let at = after.map { $0 + 1 } ?? 0
                list.insert(element, at: at)
                steps.append(.insert(at: at, targetIndex: targetIndex))
            }
        }
        return steps
    }

    /// Values (not indexes) of a longest strictly increasing subsequence; patience sorting.
    static func longestIncreasingSubsequence(_ values: [Int]) -> [Int] {
        var tails: [Int] = []          // index into `values` of the smallest tail per length
        var previous = [Int](repeating: -1, count: values.count)
        for (i, v) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < v { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var result: [Int] = []
        var k = tails.last ?? -1
        while k >= 0 {
            result.append(values[k])
            k = previous[k]
        }
        return result.reversed()
    }
}
