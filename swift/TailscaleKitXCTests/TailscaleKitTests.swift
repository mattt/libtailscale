// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import XCTest
@testable import TailscaleKit

final class TailscaleKitTests: XCTestCase {
    var controlURL: String = ""

    override func setUp() async throws {
        if controlURL == "" {
            let (res, buf) = ControlThread.shared.run {
                var buf = [CChar](repeating:0, count: 1024)
                let res = buf.withUnsafeMutableBufferPointer { ptr in
                    return run_control(ptr.baseAddress!, 1024)
                }
                return (res, buf)
            }
            let len = buf.firstIndex(where: { $0 == 0 }) ?? 0
            let str = buf[0..<len]
            controlURL = String(validating: str, as: UTF8.self) ?? ""
            guard !controlURL.isEmpty else {
                throw TailscaleError.invalidControlURL
            }
            if res == 0 {
                print("Started control with url \(controlURL)")
            }
        }
    }

    override func tearDown() async throws {
        ControlThread.shared.run { stop_control() }
    }

    func testV4() async throws {
        try await runConnectionTests(for: .v4)
    }

    func testV6() async throws {
        try await runConnectionTests(for: .v6)
    }

    /// Tests that a message short enough for Data's inline storage arrives
    /// intact.  When the data pointer escaped withUnsafeBytes, the peer got
    /// other bytes; that bug shows only in optimized builds, which
    /// `make -C swift test` uses.
    func testSendShortMessage() async throws {
        try await runConnectionTests(for: .v4, message: Data("ping".utf8))
    }

    func runConnectionTests(for netType: IPAddrType,
                            message want: Data = Data("Hello Tailscale".utf8)) async throws {
        let logger = BlackholeLogger()

        do {
            let ts1 = try TailscaleNode(config: mockConfig(), logger: logger)
            try await ts1.up()

            let ts2 = try TailscaleNode(config: mockConfig(), logger: logger)
            try await ts2.up()

            let ts1_addr = try await ts1.addrs()
            let ts2_addr = try await ts2.addrs()

            print("ts1 addresses are \(ts1_addr)")
            print("ts2_adddreses are \(ts2_addr)")

            let msgReceived = expectation(description: "ex")
            let lisetnerUp = expectation(description: "lisetnerUp")

            var listenerAddr: String?

            switch netType {
            case .v4:
                listenerAddr = ts1_addr.ip4
            case .v6:
                // barnstar: Validity of listener IPs is loadbearing.  accept fails
                // in the C code if you listen on an invalid addr.
                listenerAddr = if let a = ts1_addr.ip6 { "[\(a)]"} else { nil }
            case .none:
                XCTFail("Invalid IP Type")
            }

            guard let ts1Handle = await ts1.tailscale,
                  let ts2Handle = await ts2.tailscale,
                  let listenerAddr else {
                XCTFail("Setup failed")
                return
            }

            // Run a listener in a separate task, wait for the inbound
            // connection and read the data
            Task {
                let listener = try await Listener(tailscale: ts1Handle,
                                                  proto: .tcp,
                                                  address: ":8081",
                                                  logger: logger)
                lisetnerUp.fulfill()
                let inbound = try await listener.accept()
                await listener.close()

                let inboundIP = await inbound.remoteAddress
                let writerAddr = netType == .v4 ? ts2_addr.ip4 : ts2_addr.ip6.map { "[\($0)]" }
                XCTAssertEqual(inboundIP, writerAddr)

                let got = try await inbound.receiveMessage(timeout: 2)
                print("got \(got)")
                XCTAssertEqual(got, want)

                msgReceived.fulfill()
            }

            //Make sure somebody is listening
            await fulfillment(of: [lisetnerUp], timeout: 5.0)

            let outgoing = try await OutgoingConnection(tailscale: ts2Handle,
                                            to: "\(listenerAddr):8081",
                                            proto: .tcp,
                                            logger: logger)
            try await outgoing.connect()

            print("sending \(want)")
            try await outgoing.send(want)

            await fulfillment(of: [msgReceived], timeout: 5.0)

            print("closing  conn")
            await outgoing.close()

            try await ts1.down()
            try await ts2.down()
        } catch {
            XCTFail("Init Failed: \(error)")
        }
    }

    /// A tailnet port for the tests that dial with the C API.
    let testPort = 47420

    /// Brings up two nodes, dials the first from the second with the C API,
    /// and returns the accepted connection.  The caller closes `dialed`.
    func connectedPair() async throws -> (listenerNode: TailscaleNode,
                                          dialerNode: TailscaleNode,
                                          accepted: IncomingConnection,
                                          dialed: TailscaleConnection) {
        let logger = BlackholeLogger()

        let ts1 = try TailscaleNode(config: mockConfig(), logger: logger)
        try await ts1.up()
        let ts2 = try TailscaleNode(config: mockConfig(), logger: logger)
        try await ts2.up()

        let ts1Handle = await ts1.tailscale
        let ts2Handle = await ts2.tailscale
        let listenerIP = try await ts1.addrs().ip4
        guard let ts1Handle, let ts2Handle, let listenerIP else {
            throw TailscaleError.badInterfaceHandle
        }

        let listener = try await Listener(tailscale: ts1Handle,
                                          proto: .tcp,
                                          address: ":\(testPort)",
                                          logger: logger)
        async let accepted = listener.accept(timeout: 10)

        var conn: TailscaleConnection = 0
        let res = tailscale_dial(ts2Handle, "tcp", "\(listenerIP):\(testPort)", &conn)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, ts2Handle.getErrorMessage())
        }

        let inbound = try await accepted
        await listener.close()
        return (ts1, ts2, inbound, conn)
    }

    /// Tests that whois on an accepted connection identifies the dialing node.
    func testWhoIs() async throws {
        let (ts1, ts2, inbound, conn) = try await connectedPair()
        defer { Darwin.close(conn) }

        let status = try JSONDecoder().decode(IpnState.Status.self,
                                              from: try await ts2.statusJSON())
        let dialer = try XCTUnwrap(status.SelfStatus)

        let inboundIP = await inbound.remoteAddress
        let remoteAddress = try XCTUnwrap(inboundIP)
        let dialerIP = try await ts2.addrs().ip4
        XCTAssertEqual(remoteAddress, dialerIP)

        let who = try await ts1.whois(remoteAddress)
        XCTAssertEqual(who.Node.StableID, dialer.ID)
        XCTAssertEqual(who.Node.User, dialer.UserID)

        do {
            _ = try await ts1.whois("192.0.2.1")
            XCTFail("whois of an unknown address succeeded")
        } catch TailscaleError.internalError(let details) {
            XCTAssertFalse(try XCTUnwrap(details).isEmpty)
        }

        await inbound.close()
        try await ts1.close()
        try await ts2.close()
    }

    /// Tests that whois accepts an IP:port address.
    func testWhoIsWithPort() async throws {
        let (ts1, ts2, inbound, conn) = try await connectedPair()
        defer { Darwin.close(conn) }

        let status = try JSONDecoder().decode(IpnState.Status.self,
                                              from: try await ts2.statusJSON())
        let dialer = try XCTUnwrap(status.SelfStatus)
        let dialerAddrs = try await ts2.addrs()
        let dialerIP = try XCTUnwrap(dialerAddrs.ip4)

        let who = try await ts1.whois("\(dialerIP):\(testPort + 1)")
        XCTAssertEqual(who.Node.StableID, dialer.ID)
        XCTAssertEqual(who.Node.User, dialer.UserID)

        await inbound.close()
        try await ts1.close()
        try await ts2.close()
    }

    /// Tests that concurrent whois calls on one node all succeed.
    func testConcurrentWhoIs() async throws {
        let (ts1, ts2, inbound, conn) = try await connectedPair()
        defer { Darwin.close(conn) }

        let status = try JSONDecoder().decode(IpnState.Status.self,
                                              from: try await ts2.statusJSON())
        let dialerID = try XCTUnwrap(status.SelfStatus).ID
        let dialerAddrs = try await ts2.addrs()
        let dialerIP = try XCTUnwrap(dialerAddrs.ip4)

        let ids = try await withThrowingTaskGroup(of: Tailcfg.StableNodeID.self) { group in
            for i in 0..<16 {
                let address = i.isMultiple(of: 2) ? dialerIP : "\(dialerIP):\(testPort + i)"
                group.addTask { try await ts1.whois(address).Node.StableID }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(ids, Array(repeating: dialerID, count: 16))

        await inbound.close()
        try await ts1.close()
        try await ts2.close()
    }

    /// Tests that whois on a closed node throws EBADF.
    func testWhoIsAfterClose() async throws {
        let ts1 = try TailscaleNode(config: mockConfig(), logger: BlackholeLogger())
        try await ts1.up()
        let addrs = try await ts1.addrs()
        let ip = try XCTUnwrap(addrs.ip4)
        try await ts1.close()

        do {
            _ = try await ts1.whois(ip)
            XCTFail("whois on a closed node succeeded")
        } catch TailscaleError.posixError(let error, _) {
            XCTAssertEqual(error.code, .EBADF)
        }
    }

    /// Tests that IncomingConnection.send replies to the dialing node.
    func testIncomingSend() async throws {
        let (ts1, ts2, inbound, conn) = try await connectedPair()
        defer { Darwin.close(conn) }

        let ping = Data("ping".utf8)
        let written = ping.withUnsafeBytes { bytes in
            Darwin.write(conn, bytes.baseAddress, bytes.count)
        }
        XCTAssertEqual(written, ping.count)
        let gotPing = try await inbound.receive(timeout: 5000)
        XCTAssertEqual(gotPing, ping)

        let pong = Data("pong".utf8)
        try await inbound.send(pong)

        var p = pollfd(fd: conn, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&p, 1, 5000), 1)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = Darwin.read(conn, &buf, buf.count)
        XCTAssertEqual(n, pong.count)
        XCTAssertEqual(Data(buf.prefix(max(n, 0))), pong)

        await inbound.close()
        try await ts1.close()
        try await ts2.close()
    }

    /// Tests that a send after the peer closes throws EPIPE.  Without
    /// SO_NOSIGPIPE on the connection, the write raises SIGPIPE on this
    /// non-Go thread and terminates the test process.
    func testSendAfterPeerCloses() async throws {
        let (ts1, ts2, inbound, conn) = try await connectedPair()
        Darwin.close(conn)

        // The Go side closes its end of the accepted socketpair only after a
        // write toward the closed dialer fails, so keep sending until it does.
        let deadline = Date().addingTimeInterval(10)
        var sendError: Error?
        while sendError == nil, Date() < deadline {
            do {
                try await inbound.send(Data("ping".utf8), timeout: 1000)
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                sendError = error
            }
        }

        guard case .posixError(let error, _)? = sendError as? TailscaleError else {
            XCTFail("want EPIPE, got \(String(describing: sendError))")
            return
        }
        XCTAssertEqual(error.code, .EPIPE)

        await inbound.close()
        try await ts1.close()
        try await ts2.close()
    }

    /// Tests that a send to a peer that stops reading throws ETIMEDOUT
    /// within its timeout instead of blocking.
    func testSendTimesOut() async throws {
        let (ts1, ts2, inbound, conn) = try await connectedPair()
        defer { Darwin.close(conn) }

        // Much more than the socket and netstack buffers can hold.
        let data = Data(count: 64 << 20)
        let start = Date()
        do {
            try await inbound.send(data, timeout: 2000)
            XCTFail("send to a peer that does not read succeeded")
        } catch TailscaleError.posixError(let error, _) {
            XCTAssertEqual(error.code, .ETIMEDOUT)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 1.9)
        XCTAssertLessThan(elapsed, 10)

        await inbound.close()
        try await ts1.close()
        try await ts2.close()
    }

    /// Tests that send writes a message larger than the socket buffer.
    func testSendLargeMessage() async throws {
        let (ts1, ts2, inbound, conn) = try await connectedPair()
        defer { Darwin.close(conn) }

        let want = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let reader = Task.detached { () -> Data in
            var got = Data()
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while got.count < want.count {
                var p = pollfd(fd: conn, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 10_000) == 1 else { break }
                let n = Darwin.read(conn, &buf, buf.count)
                guard n > 0 else { break }
                got.append(contentsOf: buf.prefix(n))
            }
            return got
        }

        try await inbound.send(want, timeout: 10_000)
        let got = await reader.value
        XCTAssertEqual(got.count, want.count)
        XCTAssertTrue(got == want)

        await inbound.close()
        try await ts1.close()
        try await ts2.close()
    }

    /// Tests that LocalAPIClient.logout logs the node out.
    func testLogout() async throws {
        let logger = BlackholeLogger()
        let ts1 = try TailscaleNode(config: mockConfig(), logger: logger)
        try await ts1.up()

        let api = LocalAPIClient(localNode: ts1, logger: logger)
        let before = try await api.backendStatus()
        XCTAssertEqual(before.BackendState, "Running")

        try await api.logout()
        let after = try await api.backendStatus()
        XCTAssertEqual(after.BackendState, "NeedsLogin")

        try await ts1.close()
    }

    /// Tests that TailscaleNode.logout logs the node out.
    func testNodeLogout() async throws {
        let ts1 = try TailscaleNode(config: mockConfig(), logger: BlackholeLogger())
        try await ts1.up()

        let before = try JSONDecoder().decode(IpnState.Status.self,
                                              from: try await ts1.statusJSON())
        XCTAssertEqual(before.BackendState, "Running")

        try await ts1.logout()
        let after = try JSONDecoder().decode(IpnState.Status.self,
                                             from: try await ts1.statusJSON())
        XCTAssertEqual(after.BackendState, "NeedsLogin")

        try await ts1.close()

        do {
            try await ts1.logout()
            XCTFail("logout on a closed node succeeded")
        } catch TailscaleError.posixError(let error, _) {
            XCTAssertEqual(error.code, .EBADF)
        }
    }

    /// The hostCount here is load bearing.  Each mock host must have a unique
    /// path and hostname.
    var hostCount = 0
    func mockConfig() -> Configuration {
        let temp = getDocumentDirectoryPath().absoluteString + "tailscale\(hostCount)"
        hostCount += 1
        return Configuration(
            hostName: "testHost-\(hostCount)",
            path: temp,
            authKey: nil,
            controlURL: controlURL,
            ephemeral: false)
    }


    /// Tests that we can fetch a URL via our proxy (though this isn't a URL
    /// on the tailnet...)
    func testProxy() async throws {
        let config = mockConfig()
        let logger = BlackholeLogger()

        do {
            let ts1 = try TailscaleNode(config: config, logger: logger)
            try await ts1.up()

            let (sessionConfig, _) = try await URLSessionConfiguration.tailscaleSession(ts1)
            let session = URLSession(configuration: sessionConfig)

            let url = URL(string: "https://tailscale.com")!
            let req = URLRequest(url: url)
            let (data, _) = try await session.data(for: req)

            print("Got proxied data \(data.count)")
            XCTAssert(data.count > 0)
        }
    }

    /// Tests that localAPI is functional
    func testStatus() async throws {
        let config = mockConfig()
        let logger = BlackholeLogger()

        do {
            let ts1 = try TailscaleNode(config: config, logger: logger)
            try await ts1.up()

            // The local node should be running and online
            let api = LocalAPIClient(localNode: ts1, logger: logger)
            let status = try await api.backendStatus()
            XCTAssertEqual(status.BackendState, "Running")

            let peerStatus = status.SelfStatus!
            XCTAssertTrue(peerStatus.Online)
        } catch {
            XCTFail(error.localizedDescription)
        }
    }
}


/// Runs the tstestcontrol calls on one thread that never calls TailscaleKit.
///
/// The test bundle links two Go runtimes: libtailscale's in TailscaleKit and
/// tstestcontrol's.  On darwin/arm64, both keep the current goroutine in the
/// same thread-local slot, and a C thread that calls into Go stays bound to
/// that runtime's M after the call returns.  If a thread that called
/// TailscaleKit later calls stop_control, tstestcontrol's runtime uses the
/// other runtime's goroutine and crashes with errors such as "unknown caller
/// pc" or "bad sweepgen in refill".
final class ControlThread: @unchecked Sendable {
    static let shared = ControlThread()

    private let condition = NSCondition()
    private var jobs: [() -> Void] = []

    private init() {
        let thread = Thread { [unowned self] in
            while true {
                condition.lock()
                while jobs.isEmpty {
                    condition.wait()
                }
                let job = jobs.removeFirst()
                condition.unlock()
                job()
            }
        }
        thread.name = "tstestcontrol"
        thread.start()
    }

    /// Runs `body` on the control thread and waits for its result.
    func run<T>(_ body: @escaping () -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        condition.lock()
        jobs.append {
            box.value = body()
            done.signal()
        }
        condition.signal()
        condition.unlock()
        done.wait()
        return box.value!
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

func getDocumentDirectoryPath() -> URL {
    let arrayPaths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let docDirectoryPath = arrayPaths[0]
    return docDirectoryPath
}
