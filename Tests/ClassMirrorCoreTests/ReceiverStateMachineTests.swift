import Foundation
import Testing
@testable import ClassMirrorCore

struct ReceiverStateMachineTests {
    @Test
    func serviceMovesFromStoppedToReady() throws {
        var machine = ReceiverStateMachine()

        try machine.handle(.startRequested)
        #expect(machine.snapshot.service == .starting)

        try machine.handle(.serviceStarted(advertisedName: "교실 Mac"))
        #expect(machine.snapshot.service == .ready(advertisedName: "교실 Mac"))
        #expect(machine.snapshot.session == .idle)
    }

    @Test
    func fullConnectionLifecycleReturnsToReadyIdle() throws {
        var machine = ReceiverStateMachine()
        let identity = DeviceIdentity(name: "iPad", model: "iPad Pro")
        let request = ConnectionRequest(
            device: identity,
            pin: "3817",
            expiresAt: Date().addingTimeInterval(60)
        )
        let device = ConnectedDevice(identity: identity)
        let statistics = StreamStatistics(
            framesPerSecond: 30,
            width: 1920,
            height: 1440,
            videoCodec: "H.264",
            audioCodec: "AAC-ELD"
        )

        try machine.handle(.startRequested)
        try machine.handle(.serviceStarted(advertisedName: "교실 Mac"))
        try machine.handle(.authenticationRequested(request))
        #expect(machine.snapshot.session == .authenticating(request))

        try machine.handle(.authenticationAccepted(device))
        #expect(machine.snapshot.session == .connecting(identity))

        try machine.handle(.videoStarted(device, statistics))
        #expect(machine.snapshot.session == .streaming(device, statistics))

        try machine.handle(.disconnected)
        #expect(machine.snapshot.session == .idle)
        #expect(machine.snapshot.service == .ready(advertisedName: "교실 Mac"))
    }

    @Test
    func secondConnectionCannotPreemptActiveSession() throws {
        var machine = ReceiverStateMachine()
        let firstIdentity = DeviceIdentity(name: "교사 iPad")
        let firstDevice = ConnectedDevice(identity: firstIdentity)
        let secondRequest = ConnectionRequest(
            device: DeviceIdentity(name: "학생 iPhone"),
            pin: "1111",
            expiresAt: Date().addingTimeInterval(60)
        )

        try machine.handle(.startRequested)
        try machine.handle(.serviceStarted(advertisedName: "교실 Mac"))
        try machine.handle(.authenticationRequested(ConnectionRequest(
            device: firstIdentity,
            pin: "2222",
            expiresAt: Date().addingTimeInterval(60)
        )))
        try machine.handle(.authenticationAccepted(firstDevice))
        try machine.handle(.videoStarted(firstDevice, StreamStatistics()))

        #expect(throws: ReceiverFailure.self) {
            try machine.handle(.authenticationRequested(secondRequest))
        }
        #expect(machine.snapshot.session == .streaming(firstDevice, StreamStatistics()))
    }

    @Test
    func renewedPINReplacesStaleAuthenticationChallenge() throws {
        var machine = ReceiverStateMachine()
        let identity = DeviceIdentity(name: "교사 iPad")
        let firstRequest = ConnectionRequest(
            device: identity,
            pin: "1234",
            expiresAt: Date().addingTimeInterval(60)
        )
        let renewedRequest = ConnectionRequest(
            device: identity,
            pin: "5678",
            expiresAt: Date().addingTimeInterval(60)
        )

        try machine.handle(.startRequested)
        try machine.handle(.serviceStarted(advertisedName: "교실 Mac"))
        try machine.handle(.authenticationRequested(firstRequest))
        try machine.handle(.authenticationRequested(renewedRequest))

        #expect(machine.snapshot.session == .authenticating(renewedRequest))
    }

    @Test
    func serviceFailureClearsSession() throws {
        var machine = ReceiverStateMachine()
        let failure = ReceiverFailure(
            code: .serviceRegistrationFailed,
            message: "Bonjour 등록 실패"
        )

        try machine.handle(.startRequested)
        try machine.handle(.serviceFailed(failure))

        #expect(machine.snapshot.service == .failed(failure))
        #expect(machine.snapshot.session == .idle)
    }

    @Test
    func connectionWithoutPINMovesDirectlyToStreaming() throws {
        var machine = ReceiverStateMachine()
        let device = ConnectedDevice(identity: DeviceIdentity(name: "교사 iPad"))

        try machine.handle(.startRequested)
        try machine.handle(.serviceStarted(advertisedName: "교실 Mac"))
        try machine.handle(.authenticationAccepted(device))
        #expect(machine.snapshot.session == .connecting(device.identity))

        try machine.handle(.videoStarted(device, StreamStatistics()))
        #expect(machine.snapshot.session == .streaming(device, StreamStatistics()))
    }

    @Test
    func muteAndWindowLevelAreIndependentFromConnection() throws {
        var machine = ReceiverStateMachine()

        try machine.handle(.setAudioMuted(true))
        try machine.handle(.setKeepWindowOnTop(true))

        #expect(machine.snapshot.audioMuted)
        #expect(machine.snapshot.keepWindowOnTop)
        #expect(machine.snapshot.service == .stopped)
    }
}
