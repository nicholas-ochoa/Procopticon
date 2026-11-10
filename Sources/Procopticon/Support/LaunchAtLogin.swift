import AppKit
import ServiceManagement
import SwiftUI

/// Opening Procopticon at login, as a login item of the app itself (`SMAppService.mainApp`). macOS
/// keeps the setting, so it shows in *System Settings ▸ General ▸ Login Items* too, and is switched
/// off there as well as here.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        // The user may approve the item, or remove it, in System Settings meanwhile.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LaunchAtLogin.shared.refresh() }
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// On while registered, including while it waits for the user's approval.
    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Only an app bundle can be a login item; not `swift run`.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The Settings rows for `LaunchAtLogin`.
struct LaunchAtLoginRows: View {
    @ObservedObject private var login = LaunchAtLogin.shared

    var body: some View {
        Toggle("Open Procopticon at login", isOn: Binding(get: { login.isEnabled }, set: { login.setEnabled($0) }))
            .disabled(!login.isAvailable)
        if !login.isAvailable {
            Text("Only the app bundle can open at login.")
                .font(.caption).foregroundStyle(.secondary)
        } else if login.status == .requiresApproval {
            HStack {
                Text("Allow Procopticon in Login Items settings to finish turning this on.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items Settings…") { login.openSystemSettings() }
                    .controlSize(.small)
            }
        }
        if let error = login.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }
}
