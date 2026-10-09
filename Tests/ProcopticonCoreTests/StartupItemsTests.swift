import XCTest
@testable import ProcopticonCore

final class StartupItemsTests: XCTestCase {
    func testBackgroundTaskManagementRecords() {
        let dump = """
        ========================
         Records for UID 501 : 5EF89DB7-583D-45B2-A8C4-C0E0BDA19EB4
        ========================

         Items:

         #1:
                         UUID: A
                         Name: 1Password
               Developer Name: AgileBits Inc.
              Team Identifier: 2BUA8C4S2C
                         Type: app (0x2)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 2.com.1password.1password
                          URL: /Applications/1Password.app
          Embedded Item Identifiers:
            #1: 4.com.1password.1password-launcher

         #2:
                         UUID: B
                         Name: 1Password Launcher
               Developer Name: AgileBits Inc.
                         Type: login item (0x4)
                        Flags: [ sandboxed ] (0x40)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 4.com.1password.1password-launcher
                          URL: Contents/Library/LoginItems/1Password Launcher.app
            Bundle Identifier: com.1password.1password-launcher
            Parent Identifier: 2.com.1password.1password

         #3:
                         UUID: C
                         Name: nginx
               Developer Name: (null)
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 16.sh.brew.nginx
                          URL: /Library/LaunchDaemons/sh.brew.nginx.plist
              Executable Path: /opt/homebrew/opt/nginx/bin/nginx
                     Last Use: 2026-10-09 10:06:54-05:00
        """
        let items = StartupItems.parseBTM(dump)
        XCTAssertEqual(items.count, 2, "the app record only groups its items")
        let launcher = items.first { $0.name == "1Password Launcher" }
        XCTAssertEqual(launcher?.category, .loginItems)
        XCTAssertEqual(launcher?.path, "/Applications/1Password.app/Contents/Library/LoginItems/1Password Launcher.app")
        XCTAssertEqual(launcher?.parent, "1Password")
        XCTAssertEqual(launcher?.status, "Enabled, not allowed")
        XCTAssertEqual(launcher?.identifier, "com.1password.1password-launcher")
        let nginx = items.first { $0.name == "nginx" }
        XCTAssertEqual(nginx?.category, .backgroundItems)
        XCTAssertEqual(nginx?.kind, "Legacy daemon")
        XCTAssertEqual(nginx?.path, "/opt/homebrew/opt/nginx/bin/nginx")
        XCTAssertEqual(nginx?.identifier, "sh.brew.nginx")
        XCTAssertNil(nginx?.developer)
        XCTAssertEqual(nginx?.lastUsed, ISO8601DateFormatter().date(from: "2026-10-09T15:06:54Z"))
    }

    func testSystemExtensions() {
        let text = "1 extension(s)\n--- com.apple.system_extension.network_extension\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n*\t*\tABCDE12345\tcom.example.vpn.ext (1.2/34)\tExample VPN\t[activated enabled]\n"
        let items = StartupItems.parseSystemExtensions(text)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "Example VPN")
        XCTAssertEqual(items.first?.kind, "Network Extension")
        XCTAssertEqual(items.first?.identifier, "com.example.vpn.ext")
        XCTAssertEqual(items.first?.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(items.first?.status, "Activated Enabled")
    }

    func testCrontab() {
        let text = "# comment\nMAILTO=me\n*/5 * * * * /usr/local/bin/backup --quiet\n@reboot /bin/echo hi\n"
        let items = StartupItems.parseCrontab(text, user: "nicholas", source: "crontab -l")
        XCTAssertEqual(items.map(\.name), ["/usr/local/bin/backup --quiet", "/bin/echo hi"])
        XCTAssertEqual(items.first?.path, "/usr/local/bin/backup")
        XCTAssertTrue(items.first?.details.hasPrefix("*/5 * * * *") == true)
        let system = StartupItems.parseCrontab("0 3 * * * root /usr/sbin/periodic daily", user: nil, source: "/etc/crontab", hasUserField: true)
        XCTAssertEqual(system.first?.user, "root")
        XCTAssertEqual(system.first?.name, "/usr/sbin/periodic daily")
    }

    func testProfiles() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>_computerlevel</key><array><dict>
        <key>ProfileDisplayName</key><string>Wi-Fi</string><key>ProfileIdentifier</key><string>com.example.wifi</string>
        <key>ProfileOrganization</key><string>Example</string>
        <key>ProfileItems</key><array><dict><key>PayloadType</key><string>com.apple.wifi.managed</string></dict></array>
        </dict></array></dict></plist>
        """
        let items = StartupItems.profiles(xml)
        XCTAssertEqual(items.first?.name, "Wi-Fi")
        XCTAssertEqual(items.first?.kind, "Device profile")
        XCTAssertEqual(items.first?.developer, "Example")
        XCTAssertEqual(items.first?.details, "com.apple.wifi.managed")
        XCTAssertTrue(StartupItems.profiles("<plist version=\"1.0\"><dict/></plist>").isEmpty)
    }
}
