// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import Combine

/// ConnectionState indicates the state of individual TSConnection instances
public enum ConnectionState {
    case idle           ///< Reads and writes are not possible.  Connections will transition to connected automatically
    case connected      ///< Connected and ready to read/write
    case closed         ///< Closed and ready to be disposed of.  Closed connections cannot be reconnected.
    case failed         ///< The attempt to dial the connection failed
}

/// ListenerState indicates the state of individual TSListener instances
public enum ListenerState {
    case idle           ///< Waiting.
    case listening      ///< Listening
    case closed         ///< Closed and ready to be disposed of.
    case failed         ///< The attempt to start the listener failed
}

public typealias TailscaleHandle = Int32
public typealias TailscaleConnection = Int32
public typealias TailscaleListener = Int32

/// Outgoing connections are used to send data to other endpoints
/// on the tailnet.
///
/// For HTTP(s), consider using URLSession.tailscaleSession
public actor OutgoingConnection {
    private var tailscale: TailscaleHandle
    private var proto: NetProtocol
    private var address: String
    private var conn: TailscaleConnection = 0

    private let logger: LogSink

    /// The state of the connection.  Listen for transitions to determine
    /// if the connection may be used for send/receive operations.
    public var state: ConnectionState = .idle

    /// Creates a new outgoing connection
    ///
    /// @param tailscale The tailscale Server to use
    /// @param address The remote address and port
    /// @param proto The ip protocol
    /// @param logger
    ///
    /// @throws TailscaleError on failure
    public init(tailscale: TailscaleHandle,
         to address: String,
         proto: NetProtocol,
         logger: LogSink) async throws {

        self.logger = logger
        self.proto = proto
        self.address = address
        self.tailscale = tailscale
    }

    /// Connects the outgoing connection to the remote.  On success, the
    /// connection state will be .connected.
    ///
    /// @See tailscale_dial in Tailscale.h
    ///
    /// @throws TailscaleError on failure
    public func connect() async throws  {
        let res = tailscale_dial(tailscale, proto.rawValue, address, &conn)

        guard res == 0 else {
            self.state = .failed
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }

        self.state = .connected
    }

    deinit {
        if conn != 0 {
            Darwin.close(conn)
        }
    }

    /// Closes the outgoing connection.  Further sends are not possible.
    /// Connections will be closed on deallocation.  Sets the connection
    /// state to .closed
    public func close() {
        if conn != 0 {
            Darwin.close(conn)
            conn = 0
        }
        state = .closed
    }

    /// Sends all of the given data to the connection.
    ///
    /// The call blocks the actor until the peer accepts every byte or the
    /// timeout passes.  If it throws after it sent part of the data, the
    /// peer has received only a prefix of `data`; close the connection.
    ///
    /// - Parameters:
    ///   - data: The bytes to send.
    ///   - timeout: The longest time to wait, in milliseconds, for the whole
    ///     send.  A negative value waits indefinitely.
    /// - Throws: `TailscaleError.connectionClosed` if the connection is not
    ///   connected, `TailscaleError.posixError` with `ETIMEDOUT` if the
    ///   timeout passes, or with `EPIPE` if the peer has gone away.
    public func send(_ data: Data, timeout: Int32 = kDefaultSendTimeout) throws {
        guard state == .connected else {
            throw TailscaleError.connectionClosed
        }

        try sendAll(data, to: conn, timeout: timeout)
    }
}

/// The default `send(_:timeout:)` timeout, in milliseconds.
public let kDefaultSendTimeout: Int32 = 10_000

/// Writes all of `data` to `fd`, waiting at most `timeout` milliseconds in
/// total for the socket to accept it.  A negative timeout waits indefinitely.
///
/// Before each write, `SO_SNDTIMEO` is set to the time that remains, so a peer
/// that stops reading cannot block the caller beyond the timeout.  (On Darwin,
/// `MSG_DONTWAIT` does not stop a large blocking `send` from waiting for
/// buffer space.)  libtailscale sets `SO_NOSIGPIPE` on connection sockets, so
/// a write after the peer closes fails with `EPIPE`.
func sendAll(_ data: Data, to fd: TailscaleConnection, timeout: Int32) throws {
    let start = DispatchTime.now().uptimeNanoseconds
    let limit = timeout < 0 ? nil : UInt64(timeout) * 1_000_000

    try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < bytes.count {
            // A zero SO_SNDTIMEO means no limit.
            var tv = timeval(tv_sec: 0, tv_usec: 0)
            if let limit {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                guard elapsed < limit else {
                    throw TailscaleError.posixError(POSIXError(.ETIMEDOUT))
                }
                let remaining = limit - elapsed
                tv.tv_sec = Int(remaining / 1_000_000_000)
                tv.tv_usec = Int32(remaining % 1_000_000_000 / 1_000)
                if tv.tv_sec == 0 && tv.tv_usec == 0 {
                    tv.tv_usec = 1
                }
            }
            // Darwin rejects socket options with EINVAL after both directions
            // of the socket shut down.  The write below then fails at once,
            // so it needs no timeout.
            if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                          socklen_t(MemoryLayout<timeval>.size)) != 0, errno != EINVAL {
                throw TailscaleError.fromPosixErrCode(errno)
            }

            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                let err = errno
                // EAGAIN means SO_SNDTIMEO passed; the deadline check above
                // then throws ETIMEDOUT.
                if err == EINTR || err == EAGAIN { continue }
                throw TailscaleError.fromPosixErrCode(err)
            }
            offset += n
        }
    }
}
