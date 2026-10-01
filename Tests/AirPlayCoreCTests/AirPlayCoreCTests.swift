import AirPlayCoreC
import Darwin
import Foundation
import Testing

private final class PINRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ pin: String) {
        lock.withLock { storage.append(pin) }
    }

    var pins: [String] {
        lock.withLock { storage }
    }
}

@Suite(.serialized)
struct AirPlayCoreCTests {
    @Test
    func exposesPinnedUpstreamVersion() {
        #expect(String(cString: cm_receiver_version()) == "UxPlay-v1.73.7")
        #expect(String(cString: cm_receiver_upstream_commit()) == "df67c212a433cf6dda3676dd40c097900d24e645")
    }

    @Test
    func createsStoppedReceiver() {
        let callbacks = cm_receiver_callbacks_t()
        let receiver = cm_receiver_create(callbacks)
        #expect(receiver != nil)
        #expect(!cm_receiver_is_running(receiver))
        #expect(cm_receiver_port(receiver) == 0)
        cm_receiver_destroy(receiver)
    }

    @Test
    func startsStopsAndRestartsCleanly() throws {
        let callbacks = cm_receiver_callbacks_t()
        let receiver = try #require(cm_receiver_create(callbacks))
        defer { cm_receiver_destroy(receiver) }

        for iteration in 0 ..< 2 {
            let receiverName = "ClassMirror-CoreTest-\(iteration)-\(UUID().uuidString.prefix(6))"
            let result = receiverName.withCString { name in
                "02:00:00:00:00:02".withCString { deviceID in
                    var configuration = cm_receiver_configuration_t(
                        receiver_name: name,
                        device_id: deviceID,
                        width: 1920,
                        height: 1080,
                        refresh_rate: 60,
                        max_fps: 60,
                        require_pin_each_connection: true,
                        peer_to_peer_enabled: iteration == 1,
                        audio_enabled: true
                    )
                    return cm_receiver_start(receiver, &configuration)
                }
            }

            #expect(result == 0)
            #expect(cm_receiver_is_running(receiver))
            #expect(cm_receiver_port(receiver) > 0)

            cm_receiver_stop(receiver)
            #expect(!cm_receiver_is_running(receiver))
            #expect(cm_receiver_port(receiver) == 0)
        }
    }

    @Test
    func repeatedUnauthenticatedChallengesKeepTheSamePIN() throws {
        let recorder = PINRecorder()
        var callbacks = cm_receiver_callbacks_t()
        callbacks.context = Unmanaged.passUnretained(recorder).toOpaque()
        callbacks.on_pin = { context, pin in
            guard let context, let pin else { return }
            Unmanaged<PINRecorder>
                .fromOpaque(context)
                .takeUnretainedValue()
                .append(String(cString: pin))
        }

        let receiver = try #require(cm_receiver_create(callbacks))
        defer { cm_receiver_destroy(receiver) }

        let receiverName = "ClassMirror-PINTest-\(UUID().uuidString.prefix(6))"
        let result = receiverName.withCString { name in
            "02:00:00:00:00:03".withCString { deviceID in
                var configuration = cm_receiver_configuration_t(
                    receiver_name: name,
                    device_id: deviceID,
                    width: 1920,
                    height: 1080,
                    refresh_rate: 60,
                    max_fps: 60,
                    require_pin_each_connection: true,
                    peer_to_peer_enabled: false,
                    audio_enabled: true
                )
                return cm_receiver_start(receiver, &configuration)
            }
        }
        #expect(result == 0)

        let fileDescriptor = try connectToReceiver(port: cm_receiver_port(receiver))
        defer { Darwin.close(fileDescriptor) }

        let body = try PropertyListSerialization.data(
            fromPropertyList: [
                "deviceID": "11:22:33:44:55:66",
                "eiv": Data(repeating: 0x11, count: 16),
                "ekey": Data(repeating: 0x22, count: 72),
            ],
            format: .binary,
            options: 0
        )

        for sequence in 1 ... 4 {
            try sendPINChallenge(on: fileDescriptor, sequence: sequence, body: body)
        }

        let pins = recorder.pins
        #expect(pins.count == 4)
        #expect(Set(pins).count == 1)
        #expect(pins.first?.count == 4)
    }

    private func connectToReceiver(port: UInt16) throws -> Int32 {
        let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(.ENOTSOCK) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
        return fileDescriptor
    }

    private func sendPINChallenge(on fileDescriptor: Int32, sequence: Int, body: Data) throws {
        let header = """
        SETUP rtsp://127.0.0.1/screen RTSP/1.0\r
        CSeq: \(sequence)\r
        Content-Type: application/x-apple-binary-plist\r
        Content-Length: \(body.count)\r
        \r

        """
        var request = Data(header.utf8)
        request.append(body)

        try request.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fileDescriptor, baseAddress.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
                }
                sent += count
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !response.endsWithHTTPHeader {
            let count = Darwin.recv(fileDescriptor, &buffer, buffer.count, 0)
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET)
            }
            response.append(contentsOf: buffer.prefix(count))
        }
        #expect(String(decoding: response, as: UTF8.self).contains("RTSP/1.0 401"))
    }
}

private extension Data {
    var endsWithHTTPHeader: Bool {
        range(of: Data("\r\n\r\n".utf8)) != nil
    }
}
