import XCTest
@testable import ProcopticonCore

final class BundleInfoCacheTests: XCTestCase {
    /// Loading many executables' information at once gives what loading each in turn does.
    func testPreloadMatchesLoadingOneByOne() throws {
        let candidates = [
            "/bin/ls", "/bin/sh", "/bin/zsh", "/usr/bin/true", "/usr/bin/env", "/usr/sbin/netstat", "/usr/bin/nettop",
            "/usr/libexec/syslogd", "/sbin/launchd", "/usr/bin/log",
            "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
            "/System/Applications/Calculator.app/Contents/MacOS/Calculator",
            "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit",
            "/nonexistent/Missing.app/Contents/MacOS/Missing",
        ]
        let cache = BundleInfoCache()
        // Twice over: the same executable runs as many processes.
        cache.preload(candidates + candidates)
        for path in candidates {
            let preloaded = cache.info(for: path)
            let direct = BundleInfoCache.load(path)
            XCTAssertEqual(preloaded.bundleIdentifier, direct.bundleIdentifier, path)
            XCTAssertEqual(preloaded.displayName, direct.displayName, path)
            XCTAssertEqual(preloaded.isApplication, direct.isApplication, path)
            XCTAssertEqual(preloaded.isMainExecutable, direct.isMainExecutable, path)
            XCTAssertEqual(preloaded.fileSize, direct.fileSize, path)
        }
        XCTAssertEqual(cache.info(for: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder").bundleIdentifier, "com.apple.finder")
    }

    /// A handful of paths aren't loaded ahead; `info(for:)` still answers for them.
    func testFewPathsAreLeftToInfo() {
        let cache = BundleInfoCache()
        cache.preload(["/bin/ls", "/bin/sh"])
        XCTAssertNotNil(cache.info(for: "/bin/ls").fileSize)
    }
}
