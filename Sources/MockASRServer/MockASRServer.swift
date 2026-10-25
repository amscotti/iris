// swiftlint:disable file_length
// A single-file, dependency-free websocket fixture (SHA-1 + RFC 6455
// framing + the Meta wire shapes); splitting it would obscure the protocol.
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MockASRServer speaks the production voice-transcribe wire shapes
// (JSON handshake, bare {"sessionId"} ACK, transcript events, endStream)
// over ws://127.0.0.1:<port> for manual and integration use.
// Unit tests use an in-process transport fixture instead of this binary.

struct SHA1 {
    static func hash(_ data: Data) -> Data {
        var digest: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        let message = padded([UInt8](data))
        for base in stride(from: 0, to: message.count, by: 64) {
            compress(block: message, base: base, digest: &digest)
        }
        var out = Data()
        for value in digest {
            out.append(UInt8((value >> 24) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }

    private static func padded(_ bytes: [UInt8]) -> [UInt8] {
        var message = bytes
        let bitCount = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0x00) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitCount >> shift) & 0xFF))
        }
        return message
    }

    private static func expandSchedule(block: [UInt8], base: Int) -> [UInt32] {
        var schedule = [UInt32](repeating: 0, count: 80)
        for index in 0..<16 {
            let offset = base + index * 4
            schedule[index] =
                (UInt32(block[offset]) << 24) | (UInt32(block[offset + 1]) << 16)
                | (UInt32(block[offset + 2]) << 8) | UInt32(block[offset + 3])
        }
        for index in 16..<80 {
            schedule[index] = rotateLeft(
                schedule[index - 3] ^ schedule[index - 8] ^ schedule[index - 14] ^ schedule[index - 16],
                by: 1)
        }
        return schedule
    }

    private static func compress(block: [UInt8], base: Int, digest: inout [UInt32]) {
        let schedule = expandSchedule(block: block, base: base)
        var workA = digest[0]
        var workB = digest[1]
        var workC = digest[2]
        var workD = digest[3]
        var workE = digest[4]
        for index in 0..<80 {
            let (roundF, roundK) = functionAndConstant(
                index: index, workB: workB, workC: workC, workD: workD)
            let temp = rotateLeft(workA, by: 5) &+ roundF &+ workE &+ roundK &+ schedule[index]
            workE = workD
            workD = workC
            workC = rotateLeft(workB, by: 30)
            workB = workA
            workA = temp
        }
        digest[0] = digest[0] &+ workA
        digest[1] = digest[1] &+ workB
        digest[2] = digest[2] &+ workC
        digest[3] = digest[3] &+ workD
        digest[4] = digest[4] &+ workE
    }

    private static func functionAndConstant(index: Int, workB: UInt32, workC: UInt32, workD: UInt32) -> (
        UInt32, UInt32
    ) {
        switch index {
        case 0..<20:
            return ((workB & workC) | ((~workB) & workD), 0x5A82_7999)
        case 20..<40:
            return (workB ^ workC ^ workD, 0x6ED9_EBA1)
        case 40..<60:
            return ((workB & workC) | (workB & workD) | (workC & workD), 0x8F1B_BCDC)
        default:
            return (workB ^ workC ^ workD, 0xCA62_C1D6)
        }
    }

    private static func rotateLeft(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}

/// Maximum inbound WebSocket payload this fixture will buffer (1 MiB).
/// Peers exceeding it are dropped instead of driving unbounded `Data` growth.
/// Applies to a reassembled fragmented message as a whole.
let maxInboundFrameBytes = 1 << 20

/// A peer silent this long is disconnected, so an idle client cannot pin a
/// worker thread forever.
let idleTimeoutSeconds = 30

/// Session-id correlation for the ACK: the client may propose its id in the
/// handshake body, in the upgrade URL's query, or both.
enum SessionAck {
    /// The session id the client proposed: the handshake body's `sessionId`
    /// first, then the upgrade URL's `sessionId` query item.
    static func sessionId(inHandshake text: String, requestTarget: String?) -> String? {
        if let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let body = object["sessionId"] as? String, !body.isEmpty
        {
            return body
        }
        guard let target = requestTarget else { return nil }
        let segments = target.split(separator: "?", maxSplits: 1)
        guard segments.count == 2 else { return nil }
        for pair in segments[1].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "sessionId", !parts[1].isEmpty else { continue }
            let raw = String(parts[1])
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }

    static func json(sessionId: String) -> String {
        let object = ["sessionId": sessionId]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return #"{"sessionId":"mock-session"}"# }
        return json
    }
}

struct WebSocketConnection {
    /// One inbound frame, already unmasked.
    private struct Frame {
        var fin: Bool
        var opcode: UInt8
        var payload: Data
    }

    let socketFD: Int32
    /// Request target of the HTTP upgrade ("GET <target> HTTP/1.1"), kept so
    /// the session ACK can echo a sessionId sent as a query item.
    private var requestTarget: String?
    /// Data message being reassembled from fragments (RFC 6455 §5.4).
    private var fragments: (opcode: UInt8, payload: Data)?
    /// Frame bytes read past the HTTP header delimiter (pipelined).
    private var buffered = Data()

    init(socketFD: Int32) {
        self.socketFD = socketFD
    }

    mutating func run(sessionCounter: Int) {
        guard let target = performHandshake() else { return }
        requestTarget = target
        // The first text frame is the handshake and is validated before the
        // session ACK, matching the real service: a bad key gets a 401, not
        // a session id. Control frames (ping/close) may precede it.
        guard let handshakeText = readHandshakeText() else { return }
        if Self.isBadHandshake(handshakeText) {
            sendText(#"{"type":"error","code":401,"message":"Invalid API key."}"#)
            sendClose()
            return
        }
        // Echo the client's session id (handshake body, else the URL query)
        // so a client that sends different ids on the two channels — or the
        // same id on both — sees exactly what the server correlated.
        let sessionId =
            SessionAck.sessionId(inHandshake: handshakeText, requestTarget: requestTarget)
            ?? "mock-session-\(sessionCounter)"
        sendText(SessionAck.json(sessionId: sessionId))
        var audioChunks = 0
        while true {
            guard let (opcode, payload) = readMessage() else { return }
            if handleFrame(opcode, payload, audioChunks: &audioChunks) { return }
        }
    }

    private mutating func readHandshakeText() -> String? {
        while let (opcode, payload) = readMessage() {
            switch opcode {
            case 0x1:
                return String(data: payload, encoding: .utf8)
            case 0x8:
                sendClose(received: payload)
                return nil
            case 0x9:
                sendFrame(opcode: 0xA, payload: payload)
            default:
                return nil
            }
        }
        return nil
    }

    /// Handles one complete message. Returns true when the session is over.
    private mutating func handleFrame(
        _ opcode: UInt8, _ payload: Data, audioChunks: inout Int
    ) -> Bool {
        switch opcode {
        case 0x1:
            guard let text = String(data: payload, encoding: .utf8) else { return false }
            return handleText(text)
        case 0x2:
            audioChunks = noteAudioChunk(audioChunks)
            return false
        case 0x8:
            sendClose(received: payload)
            return true
        case 0x9:
            sendFrame(opcode: 0xA, payload: payload)
            return false
        default:
            return false
        }
    }

    /// Handles one text frame. Returns true when the session is over.
    private func handleText(_ text: String) -> Bool {
        // Parse the marker as JSON: a substring match would also fire on a
        // transcript whose text merely mentions "endStream".
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "endStream"
        else { return false }
        sendText(
            #"{"type":"transcript","transcript":"hello from the mock server","final":false}"#)
        sendText(
            #"{"type":"transcript","transcript":"hello from the mock server","final":true}"#)
        sendClose()
        return true
    }

    /// Returns the upgrade request's target ("/path?query") on success.
    private mutating func performHandshake() -> String? {
        var request = Data()
        var headerEnd: Range<Data.Index>?
        while true {
            guard let chunk = recvSome(maxBytes: 4096), !chunk.isEmpty else { return nil }
            request.append(chunk)
            if let found = request.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = found
                break
            }
            if request.count > 65536 { return nil }
        }
        // Bytes after the delimiter are already WebSocket frames (a client
        // may pipeline the upgrade and its handshake frame); keep them for
        // the frame reader instead of discarding them.
        if let headerEnd {
            buffered.append(request[headerEnd.upperBound...])
            request = Data(request[..<headerEnd.upperBound])
        }
        guard let header = String(data: request, encoding: .utf8) else { return nil }
        var key: String?
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key"
            {
                key = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let key else { return nil }
        let accept = SHA1.hash(Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            .base64EncodedString()
        let response =
            "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        guard sendAll(Data(response.utf8)) else { return nil }
        // Request line: "GET <target> HTTP/1.1".
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let fields = requestLine.split(separator: " ")
        return fields.count >= 2 ? String(fields[1]) : ""
    }

    private func noteAudioChunk(_ count: Int) -> Int {
        if count == 0 {
            sendText(#"{"type":"transcript","transcript":"hello","final":false}"#)
        }
        return count + 1
    }

    /// The handshake's Bearer token: `authorization.accessToken` (Meta shape).
    /// Falls back to a raw substring match so non-JSON handshake shapes
    /// carrying a bad key still exercise the 401 path.
    private static func isBadHandshake(_ text: String) -> Bool {
        if let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let authorization = object["authorization"] as? [String: Any],
            let token = authorization["accessToken"] as? String
        {
            return token.contains("bad-key")
        }
        return text.contains("bad-key")
    }

    private mutating func readExtendedLength(marker: Int) -> Int? {
        let length: Int
        if marker == 126 {
            guard let ext = readExactly(2) else { return nil }
            length = (Int(ext[ext.startIndex]) << 8) | Int(ext[ext.startIndex + 1])
        } else if marker == 127 {
            guard let ext = readExactly(8) else { return nil }
            var value = 0
            for byte in ext { value = (value << 8) | Int(byte) }
            length = value
        } else {
            length = marker
        }
        guard length >= 0, length <= maxInboundFrameBytes else { return nil }
        return length
    }

    /// Next complete message. Data messages are reassembled from fragments;
    /// control frames, which may arrive between fragments, are returned as
    /// they come. Any protocol violation ends the connection.
    private mutating func readMessage() -> (opcode: UInt8, payload: Data)? {
        while true {
            guard let frame = readFrame() else { return nil }
            if frame.opcode >= 0x8 {
                // Control frames are never fragmented and carry at most 125 bytes.
                guard frame.fin, frame.payload.count <= 125 else { return nil }
                return (frame.opcode, frame.payload)
            }
            if frame.opcode == 0x0 {
                // A continuation must extend a message already in progress.
                guard var partial = fragments else { return nil }
                partial.payload.append(frame.payload)
                guard partial.payload.count <= maxInboundFrameBytes else { return nil }
                if frame.fin {
                    fragments = nil
                    return partial
                }
                fragments = partial
                continue
            }
            // A new data message may not start inside another one.
            guard fragments == nil else { return nil }
            if frame.fin { return (frame.opcode, frame.payload) }
            fragments = (frame.opcode, frame.payload)
        }
    }

    private mutating func readFrame() -> Frame? {
        guard let header = readExactly(2) else { return nil }
        let fin = header[header.startIndex] & 0x80 != 0
        // No extensions are negotiated, so every RSV bit must be clear.
        guard header[header.startIndex] & 0x70 == 0 else { return nil }
        let opcode = header[header.startIndex] & 0x0F
        let masked = header[header.startIndex + 1] & 0x80 != 0
        // RFC 6455 requires clients to mask: an unmasked client frame means
        // a non-compliant transport, so drop the connection instead of
        // accepting payload a real server would reject.
        guard masked else {
            fputs("MockASRServer: dropping unmasked client frame\n", stderr)
            return nil
        }
        guard let length = readExtendedLength(marker: Int(header[header.startIndex + 1] & 0x7F)) else {
            return nil
        }
        guard let key = readExactly(4) else { return nil }
        let mask = [UInt8](key)
        guard let payload = readExactly(length) else { return nil }
        var bytes = [UInt8](payload)
        for index in bytes.indices { bytes[index] ^= mask[index % 4] }
        return Frame(fin: fin, opcode: opcode, payload: Data(bytes))
    }
}

extension WebSocketConnection {
    private func sendText(_ text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    private func sendClose(received: Data? = nil) {
        // RFC 6455 §5.5.1: echo the status code the peer sent where there is
        // one, so a test client asserting its own close code is not misled.
        if let received, received.count >= 2 {
            sendFrame(opcode: 0x8, payload: Data(received.prefix(2)))
        } else {
            sendFrame(opcode: 0x8, payload: Data([0x03, 0xE8]))
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var header = Data([0x80 | opcode])
        if payload.count < 126 {
            header.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            header.append(126)
            header.append(UInt8((payload.count >> 8) & 0xFF))
            header.append(UInt8(payload.count & 0xFF))
        } else {
            header.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        _ = sendAll(header)
        _ = sendAll(payload)
    }

    private mutating func readExactly(_ count: Int) -> Data? {
        if count == 0 { return Data() }
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            if !buffered.isEmpty {
                let take = min(buffered.count, count - out.count)
                out.append(buffered.prefix(take))
                buffered.removeFirst(take)
                continue
            }
            guard let chunk = recvSome(maxBytes: count - out.count), !chunk.isEmpty else { return nil }
            out.append(chunk)
        }
        return out
    }

    private func recvSome(maxBytes: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: min(maxBytes, 65536))
        let count = buffer.withUnsafeMutableBytes { pointer in
            recv(socketFD, pointer.baseAddress, pointer.count, 0)
        }
        if count < 0 { return nil }
        if count == 0 { return Data() }
        return Data(buffer.prefix(count))
    }

    @discardableResult
    private func sendAll(_ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return send(socketFD, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent <= 0 { return false }
            offset += sent
        }
        return true
    }
}

func printHelp() {
    print(
        """
        Usage: MockASRServer [--port <port>]
          Speaks the voice-transcribe wire shapes over ws://127.0.0.1:<port>.
          Default port 8080 (valid range 0...65535; 0 asks the OS for a
          free ephemeral port, which is then printed). A handshake whose
          authorization.accessToken contains "bad-key" gets a 401 error.
          Binds 127.0.0.1 only; inbound messages are capped at 1 MiB,
          fragmented messages are reassembled, unmasked client frames are
          dropped per RFC 6455, and peers idle for 30 s are disconnected.
        """)
}

func parsePort(_ text: String) -> Int? {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        (0...65535).contains(value)
    else { return nil }
    return value
}

var port = 8080
var index = CommandLine.arguments.startIndex.advanced(by: 1)
while index < CommandLine.arguments.endIndex {
    let arg = CommandLine.arguments[index]
    // `swift run MockASRServer -- --port 8080` forwards the separator on
    // some toolchains; accept it and keep parsing options.
    if arg != "--" {
        if arg == "--help" || arg == "-h" {
            printHelp()
            exit(0)
        } else if arg == "--port" {
            guard index + 1 < CommandLine.arguments.endIndex,
                let value = parsePort(CommandLine.arguments[index + 1])
            else {
                fputs("MockASRServer: --port requires a numeric value in 0...65535\n", stderr)
                printHelp()
                exit(2)
            }
            port = value
            index += 1
        } else if arg.hasPrefix("-") {
            fputs("MockASRServer: unknown argument: \(arg)\n", stderr)
            printHelp()
            exit(2)
        } else if let value = parsePort(arg) {
            port = value
        } else {
            fputs("MockASRServer: invalid port: \(arg) (expected 0...65535)\n", stderr)
            printHelp()
            exit(2)
        }
    }
    index += 1
}

#if canImport(Darwin)
    let streamType: Int32 = SOCK_STREAM
#else
    let streamType: Int32 = Int32(SOCK_STREAM.rawValue)
#endif

signal(SIGPIPE, SIG_IGN)  // A disconnecting client must not kill the server.
let listenFd = socket(AF_INET, streamType, 0)
guard listenFd >= 0 else { fatalError("socket() failed") }
var reuse: Int32 = 1
setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_in()
address.sin_family = sa_family_t(AF_INET)
address.sin_port = in_port_t(UInt16(port)).bigEndian
// Loopback only: this is a local test fixture, never a LAN service.
address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
func locallyBoundPort(of socketFD: Int32) -> in_port_t {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketFD, $0, &length)
        }
    }
    precondition(result == 0, "getsockname failed")
    return address.sin_port.byteSwapped
}

guard bound == 0 else { fatalError("bind(:\(port)) failed") }
guard listen(listenFd, 16) == 0 else { fatalError("listen() failed") }
let resolvedPort = locallyBoundPort(of: listenFd)
if port == 0 {
    print("MockASRServer listening on ws://127.0.0.1:\(resolvedPort) (ephemeral)")
} else {
    print("MockASRServer listening on ws://127.0.0.1:\(resolvedPort)")
}
fflush(stdout)  // Piped/redirected stdout is block-buffered; the port must be visible immediately.
var sessions = 0
while true {
    let clientFD = accept(listenFd, nil, nil)
    if clientFD < 0 {
        let reason = errno
        if reason == EMFILE || reason == ENFILE {
            fputs("MockASRServer: out of file descriptors; backing off 100ms\n", stderr)
            usleep(100_000)
        }
        continue
    }
    #if canImport(Darwin)
        // Never die writing to a disconnected peer (SO_NOSIGPIPE + SIG_IGN;
        // Linux has no SO_NOSIGPIPE, it uses MSG_NOSIGNAL per send).
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    #endif
    // Bounded reads: recv() fails once the peer has been silent too long.
    var idleTimeout = timeval(tv_sec: idleTimeoutSeconds, tv_usec: 0)
    setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &idleTimeout, socklen_t(MemoryLayout<timeval>.size))
    sessions += 1
    let id = sessions
    // One session per background queue item: handling a connection inline
    // would leave concurrent clients parked in the listen backlog until the
    // first session ends, tripping real-client ACK timeouts.
    DispatchQueue.global().async {
        var connection = WebSocketConnection(socketFD: clientFD)
        connection.run(sessionCounter: id)
        // Half-close write side and drain unread client bytes briefly so the
        // kernel sends FIN rather than RST while the peer reads final frames.
        _ = shutdown(clientFD, Int32(SHUT_WR))
        var drainTimeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &drainTimeout, socklen_t(MemoryLayout<timeval>.size))
        var discard = [UInt8](repeating: 0, count: 1024)
        while recv(clientFD, &discard, discard.count, 0) > 0 {}
        close(clientFD)
    }
}
