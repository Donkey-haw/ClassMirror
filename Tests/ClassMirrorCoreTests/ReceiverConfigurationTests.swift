import Testing
@testable import ClassMirrorCore

struct ReceiverConfigurationTests {
    @Test
    func defaultsToLocalNetworkForAppleTVCoexistence() {
        let configuration = ReceiverConfiguration(receiverName: "ClassMirror")

        #expect(configuration.peerToPeerEnabled == false)
    }
}
