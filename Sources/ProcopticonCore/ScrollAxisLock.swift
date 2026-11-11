import Foundation

/// Which way a scroll gesture goes, for a table that scrolls both ways.
///
/// A trackpad swipe is never perfectly straight, so a gesture is held to the axis it started
/// along. AppKit does this itself (`NSScrollView.usesPredominantAxisScrolling`), but its choice
/// could outlast the gesture: with a mouse that has two wheels, handled by BetterMouse, the
/// horizontal wheel did nothing after the vertical one had been used (and the other way round)
/// until a click in the window. This lock can't outlive its gesture: it is dropped when a new
/// one begins and when the events pause, and events that belong to no gesture (a plain wheel)
/// are never held to an axis.
public struct ScrollAxisLock: Sendable {
    public enum Axis: Equatable, Sendable {
        case horizontal, vertical
    }

    /// How far a gesture goes, in points, before its axis is settled. The first events of a swipe
    /// are too small to tell.
    static let decisionDistance = 6.0
    /// The pause between events after which a gesture is taken to be over, whatever was said.
    static let expiry: TimeInterval = 0.5

    private var locked: Axis?
    private var travelledX = 0.0
    private var travelledY = 0.0
    private var lastEvent = -TimeInterval.infinity

    public init() {}

    /// The axis an event may scroll along, or nil for both.
    /// - Parameters:
    ///   - inGesture: the event has a gesture or momentum phase (a trackpad, or a wheel made to
    ///     look like one); a plain wheel's events have neither.
    ///   - begins: the event starts a gesture.
    ///   - timestamp: when the event happened, in seconds.
    public mutating func axis(deltaX: Double, deltaY: Double, inGesture: Bool, begins: Bool, timestamp: TimeInterval) -> Axis? {
        guard inGesture else {
            reset()
            return nil
        }
        if begins || timestamp - lastEvent > Self.expiry {
            reset()
        }
        lastEvent = timestamp
        if let locked {
            return locked
        }
        travelledX += abs(deltaX)
        travelledY += abs(deltaY)
        if max(travelledX, travelledY) >= Self.decisionDistance {
            locked = travelledX > travelledY ? .horizontal : .vertical
            return locked
        }
        // Not settled yet: the event goes the way it mostly points.
        if deltaX == 0, deltaY == 0 {
            return nil
        }
        return abs(deltaX) > abs(deltaY) ? .horizontal : .vertical
    }

    private mutating func reset() {
        locked = nil
        travelledX = 0
        travelledY = 0
    }
}
