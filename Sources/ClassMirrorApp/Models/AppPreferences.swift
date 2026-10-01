import Foundation
import Observation

enum PlayerWindowScale: String, CaseIterable, Identifiable {
    case fit
    case half
    case threeQuarters
    case actual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: "맞춤"
        case .half: "50%"
        case .threeQuarters: "75%"
        case .actual: "100%"
        }
    }

    var multiplier: CGFloat? {
        switch self {
        case .fit: nil
        case .half: 0.5
        case .threeQuarters: 0.75
        case .actual: 1
        }
    }
}

@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        static let receiverName = "receiverName"
        static let receiverDeviceID = "receiverDeviceID"
        static let requiresPIN = "requiresPIN"
        static let peerToPeerEnabled = "peerToPeerEnabled"
        static let didMigratePeerToPeerToOptIn = "didMigratePeerToPeerToOptInV1"
        static let audioEnabled = "audioEnabled"
        static let playerWindowScale = "playerWindowScale"
    }

    var receiverName: String {
        didSet { defaults.set(receiverName, forKey: Key.receiverName) }
    }

    var requiresPIN: Bool {
        didSet { defaults.set(requiresPIN, forKey: Key.requiresPIN) }
    }

    var peerToPeerEnabled: Bool {
        didSet { defaults.set(peerToPeerEnabled, forKey: Key.peerToPeerEnabled) }
    }

    var audioEnabled: Bool {
        didSet { defaults.set(audioEnabled, forKey: Key.audioEnabled) }
    }

    var playerWindowScale: PlayerWindowScale {
        didSet { defaults.set(playerWindowScale.rawValue, forKey: Key.playerWindowScale) }
    }

    let receiverDeviceID: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let savedReceiverName = defaults.string(forKey: Key.receiverName) {
            receiverName = savedReceiverName
        } else {
            let generatedReceiverName = Self.defaultReceiverName()
            receiverName = generatedReceiverName
            defaults.set(generatedReceiverName, forKey: Key.receiverName)
        }
        if let savedDeviceID = defaults.string(forKey: Key.receiverDeviceID) {
            receiverDeviceID = savedDeviceID
        } else {
            let generatedDeviceID = Self.makeDeviceID()
            receiverDeviceID = generatedDeviceID
            defaults.set(generatedDeviceID, forKey: Key.receiverDeviceID)
        }
        requiresPIN = defaults.object(forKey: Key.requiresPIN) as? Bool ?? true
        // AWDL uses the same peer-to-peer radio path that macOS may use when
        // sending its display to an Apple TV. ClassMirror's primary workflow
        // therefore keeps AWDL opt-in and receives the iPad over the LAN.
        // Migrate existing installs once because earlier builds enabled AWDL
        // implicitly, which prevented reliable simultaneous Apple TV output.
        if defaults.bool(forKey: Key.didMigratePeerToPeerToOptIn) {
            peerToPeerEnabled = defaults.object(forKey: Key.peerToPeerEnabled) as? Bool ?? false
        } else {
            peerToPeerEnabled = false
            defaults.set(false, forKey: Key.peerToPeerEnabled)
            defaults.set(true, forKey: Key.didMigratePeerToPeerToOptIn)
        }
        audioEnabled = defaults.object(forKey: Key.audioEnabled) as? Bool ?? true
        playerWindowScale = defaults.string(forKey: Key.playerWindowScale)
            .flatMap(PlayerWindowScale.init(rawValue:)) ?? .fit
    }

    private static func defaultReceiverName() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)
        return "ClassMirror-\(suffix)"
    }

    private static func makeDeviceID() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
