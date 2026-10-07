import XCTest
@testable import ProcopticonCore

final class ListReorderTests: XCTestCase {
    /// Applies the steps the way the table does and returns the result.
    private func apply(_ steps: [ListReorder.Step], _ current: [Int], _ target: [Int]) -> [Int] {
        var list = current
        for step in steps {
            switch step {
            case .move(let from, let to):
                let e = list.remove(at: from)
                list.insert(e, at: to)
            case .insert(let at, let targetIndex):
                list.insert(target[targetIndex], at: at)
            }
        }
        return list
    }

    func testOneRowMovingDownIsOneMove() {
        let steps = ListReorder.steps(from: [1, 2, 3, 4, 5], to: [2, 3, 4, 5, 1])
        XCTAssertEqual(steps, [.move(from: 0, to: 4)])
    }

    func testOneRowMovingUpIsOneMove() {
        let steps = ListReorder.steps(from: [1, 2, 3, 4, 5], to: [5, 1, 2, 3, 4])
        XCTAssertEqual(steps, [.move(from: 4, to: 0)])
    }

    func testInsertsAndUnchanged() {
        XCTAssertEqual(ListReorder.steps(from: [1, 2, 3], to: [1, 2, 3]), [])
        let steps = ListReorder.steps(from: [1, 3], to: [0, 1, 2, 3, 4])
        XCTAssertEqual(apply(steps, [1, 3], [0, 1, 2, 3, 4]), [0, 1, 2, 3, 4])
        XCTAssertEqual(steps.count, 3)
    }

    func testRandomReordersReachTheTargetWithMinimalMoves() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let n = Int.random(in: 0...40, using: &rng)
            let current = Array(0..<n).shuffled(using: &rng)
            var target = current.shuffled(using: &rng)
            // Some new elements.
            for extra in 0..<Int.random(in: 0...5, using: &rng) {
                target.insert(1000 + extra, at: Int.random(in: 0...target.count, using: &rng))
            }
            let steps = ListReorder.steps(from: current, to: target)
            XCTAssertEqual(apply(steps, current, target), target)
            let moves = steps.filter { if case .move = $0 { return true } else { return false } }.count
            let positions = target.compactMap { current.firstIndex(of: $0) }
            XCTAssertEqual(moves, current.count - ListReorder.longestIncreasingSubsequence(positions).count)
        }
    }
}
