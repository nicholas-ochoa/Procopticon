import AppKit
import ProcopticonCore

/// Holds process list updates while any menu is open (menu bar, toolbar and context menus). A
/// refresh rebuilds the process table on the main thread, which made open menus lag behind the
/// pointer and could change their items while they were open.
@MainActor
final class MenuTracking {
    static let shared = MenuTracking()
    private var openMenus = 0
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuTracking.shared.changed(by: 1) }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuTracking.shared.changed(by: -1) }
        })
    }

    private func changed(by delta: Int) {
        openMenus = max(0, openMenus + delta)
        ProcessStore.shared.holdsUpdates = openMenus > 0
    }
}
