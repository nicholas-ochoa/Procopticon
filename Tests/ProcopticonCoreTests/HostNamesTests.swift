import XCTest
@testable import ProcopticonCore

final class HostNamesTests: XCTestCase {
    private func split(_ host: String) -> [String] {
        let parts = HostNames.split(host)
        return [parts.prefix, parts.domain]
    }

    func testSplitsAtTheRegisteredDomain() {
        XCTAssertEqual(split("lb-140-82-113-26-iad.github.com"), ["lb-140-82-113-26-iad.", "github.com"])
        XCTAssertEqual(split("server-13-33-21-5.sfo5.r.cloudfront.net"), ["server-13-33-21-5.sfo5.r.", "cloudfront.net"])
        XCTAssertEqual(split("www.bbc.co.uk"), ["www.", "bbc.co.uk"])
        XCTAssertEqual(split("a.b.example.com.au"), ["a.b.", "example.com.au"])
        XCTAssertEqual(split("mail.example.de"), ["mail.", "example.de"])
        XCTAssertEqual(split("host.example.com."), ["host.", "example.com."])
    }

    func testLeavesShortAndUnusualNamesWhole() {
        XCTAssertEqual(split("github.com"), ["", "github.com"])
        XCTAssertEqual(split("bbc.co.uk"), ["", "bbc.co.uk"])
        XCTAssertEqual(split("localhost"), ["", "localhost"])
        XCTAssertEqual(split("my-mac.local"), ["", "my-mac.local"])
        XCTAssertEqual(split(""), ["", ""])
        XCTAssertEqual(split("192.168.1.20"), ["", "192.168.1.20"])
        XCTAssertEqual(split("fe80::1"), ["", "fe80::1"])
        XCTAssertEqual(split("odd..example.com"), ["", "odd..example.com"])
    }

    func testSocketEndpointPeer() {
        var e = SocketEndpoint(family: AF_INET, sockType: SOCK_DGRAM, proto: IPPROTO_UDP, tcpState: -1, localAddress: "*", localPort: 5353,
                               remoteAddress: "*", remotePort: 0, sendQueue: 0, recvQueue: 0, unixPath: "")
        XCTAssertFalse(e.hasPeer)
        XCTAssertEqual(e.summary, "UDP *:5353")
        e.remoteAddress = "2607:6bc0::10"
        e.remotePort = 443
        XCTAssertTrue(e.hasPeer)
        XCTAssertEqual(SocketEndpoint.bracket(e.remoteAddress), "[2607:6bc0::10]")
        XCTAssertEqual(SocketEndpoint.bracket("10.0.0.198"), "10.0.0.198")
    }

    func testLoopbackAndEphemeral() {
        XCTAssertTrue(HostNames.isLoopback("127.0.0.1"))
        XCTAssertTrue(HostNames.isLoopback("::1"))
        XCTAssertFalse(HostNames.isLoopback("*"))
        XCTAssertFalse(HostNames.isLoopback("192.168.1.20"))
        XCTAssertFalse(PortNames.isEphemeral(443))
        XCTAssertFalse(PortNames.isEphemeral(49151))
        XCTAssertTrue(PortNames.isEphemeral(49152))
    }
}
