import AppKit
import InformerCore
import SwiftUI

struct SecurityTab: View {
    let item: ProcessItem
    @State private var info: SigningInfo?
    @State private var runtime: String = ""

    var body: some View {
        let r = item.record
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionBox(title: "Credentials") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Effective user", "\(UserNames.name(r.uid)) (\(r.uid))")
                        InfoRow("Real user", "\(UserNames.name(r.ruid)) (\(r.ruid))")
                        InfoRow("Saved user", "\(UserNames.name(r.svuid)) (\(r.svuid))")
                        InfoRow("Full name", UserNames.fullName(r.uid))
                        InfoRow("Real group", "\(UserNames.group(r.rgid)) (\(r.rgid))")
                        InfoRow("Group memberships", UserNames.groupList(for: r.uid).joined(separator: ", "))
                        InfoRow("Elevated", r.isElevated ? "Yes (effective root, real user \(UserNames.name(r.ruid)))" : "No")
                        InfoRow("Sandboxed", r.sandboxed == true ? "Yes" : (r.sandboxed == false ? "No" : "Unknown"))
                    }
                }
                SectionBox(title: "Code Signing") {
                    if let info {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                            InfoRow("On-disk signature", info.verificationSummary)
                            InfoRow("Running code", runtime)
                            InfoRow("Identifier", info.identifier ?? "")
                            InfoRow("Team ID", info.teamIdentifier ?? "")
                            InfoRow("Format", info.format ?? "")
                            InfoRow("CDHash", info.cdHash ?? "")
                            InfoRow("Signed", info.signingDate?.formatted(date: .abbreviated, time: .standard) ?? "")
                            InfoRow("Apple signed", info.isAppleSigned ? "Yes" : "No")
                            InfoRow("Notarized", info.isAppleSigned ? "n/a" : (info.isNotarized ? "Yes" : "No"))
                            InfoRow("Hardened runtime", info.hardenedRuntime || (r.csFlags ?? 0) & CodeSigningFlags.runtime != 0 ? "Yes" : "No")
                            InfoRow("Signature flags", CodeSigningFlags.describe(info.flags).joined(separator: ", "))
                            InfoRow("Runtime flags", r.csFlags.map { CodeSigningFlags.describe($0).joined(separator: ", ") } ?? "")
                        }
                        if !info.authorities.isEmpty {
                            Text("Certificate chain").font(.subheadline.weight(.semibold)).padding(.top, 6)
                            ForEach(Array(info.authorities.enumerated()), id: \.offset) { i, a in
                                Text(String(repeating: "    ", count: i) + "↳ " + a).textSelection(.enabled)
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
                SectionBox(title: "Entitlements") {
                    if let xml = info?.entitlementsXML {
                        MonospacedTextView(text: xml).frame(minHeight: 220)
                    } else {
                        Text(info == nil ? "Loading…" : "No entitlements.").foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .task(id: item.key) {
            let path = item.record.path ?? ""
            let pid = item.pid
            info = await Task.detached { CodeSigning.inspect(path: path) }.value
            let v = await Task.detached { CodeSigning.validateRunning(pid: pid) }.value
            runtime = v.valid ? "Valid" : v.detail
        }
    }
}

struct ServiceTab: View {
    let item: ProcessItem
    @ObservedObject private var services = ServiceStore.shared
    @State private var details = ""

    var body: some View {
        let matches = services.items.filter { $0.pid == item.pid }
        VStack(alignment: .leading, spacing: 10) {
            if services.items.isEmpty {
                ProgressView("Loading launchd jobs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                ContentUnavailableView {
                    Label("Not a launchd job", systemImage: "gearshape.2")
                } description: {
                    Text("No launchd service in the system or user domain currently reports PID \(item.pid).")
                } actions: {
                    Button("Show launchd Process Info…") {
                        let pid = item.pid
                        Reports.show(title: "launchctl procinfo \(pid)") {
                            await Reports.runTool("/bin/launchctl", ["procinfo", "\(pid)"], requiresRoot: true)
                        }
                    }
                }
            } else {
                ForEach(matches) { s in
                    SectionBox(title: s.label) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                            InfoRow("Domain", s.domain.displayName)
                            InfoRow("Kind", s.kind.rawValue)
                            InfoRow("Status", s.statusDescription)
                            InfoRow("Start", s.startTypeDescription)
                            InfoRow("Property list", s.plistPath ?? "")
                            InfoRow("Program", s.executable ?? "")
                        }
                        HStack {
                            Button("Service Properties…") { ServicePropertiesWindow.open(s) }
                            Button("Restart Service") { ServiceActions.run(.restart, [s]) }
                            Button("Stop Service") { ServiceActions.run(.stop, [s]) }
                        }
                        .padding(.top, 6)
                    }
                }
                Spacer()
            }
        }
        .padding()
        .task { services.refreshIfNeeded() }
    }
}
