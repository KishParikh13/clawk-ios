import XCTest
@testable import KishOS

@MainActor
final class AudioRouteMonitorTests: XCTestCase {
    private func makeMonitor() -> AudioRouteMonitor {
        let suiteName = "AudioRouteMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return AudioRouteMonitor(userDefaults: defaults)
    }

    func testCallSessionStartsInactive() {
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.isCallSessionActive)
        XCTAssertFalse(monitor.wasExternalSeenInCallSession)
    }

    // Force semantics: beginCallSession must activate the call session even when the
    // user has NOT opted into hands-free for dictation. The call always attempts the
    // external route on its own.
    func testBeginCallSessionDoesNotRequirePrefersHandsFreeRoute() async {
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.prefersHandsFreeRoute)

        await monitor.beginCallSession()

        XCTAssertTrue(monitor.isCallSessionActive)
    }

    func testBeginCallSessionStillActivatesWhenPrefersHandsFreeRouteIsOn() async {
        let monitor = makeMonitor()
        monitor.setPrefersHandsFreeRoute(true)
        XCTAssertTrue(monitor.prefersHandsFreeRoute)

        await monitor.beginCallSession()

        XCTAssertTrue(monitor.isCallSessionActive)
    }

    func testEndCallSessionClearsCallState() async {
        let monitor = makeMonitor()
        await monitor.beginCallSession()
        XCTAssertTrue(monitor.isCallSessionActive)

        monitor.endCallSession()

        XCTAssertFalse(monitor.isCallSessionActive)
        XCTAssertFalse(monitor.wasExternalSeenInCallSession)
    }

    func testBeginCallSessionResetsExternalSeenFlag() async {
        let monitor = makeMonitor()
        await monitor.beginCallSession()
        monitor.endCallSession()

        // A fresh call session must start with a clean external-seen slate so P0.3
        // does not report a stale "lost" route from a prior call.
        await monitor.beginCallSession()
        XCTAssertFalse(monitor.wasExternalSeenInCallSession)
    }

    // beginCallSession must not toggle the dictation preference; the two paths are
    // independent (dictation stays gated on prefersHandsFreeRoute).
    func testBeginCallSessionLeavesDictationPreferenceUnchanged() async {
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.prefersHandsFreeRoute)

        await monitor.beginCallSession()

        XCTAssertFalse(monitor.prefersHandsFreeRoute)
    }
}

@MainActor
final class VoiceControllerAudioSessionTests: XCTestCase {
    func testManagesAudioSessionDefaultsTrue() {
        let voice = VoiceController()
        XCTAssertTrue(voice.managesAudioSession)
    }

    func testManagesAudioSessionIsTogglable() {
        let voice = VoiceController()
        voice.managesAudioSession = false
        XCTAssertFalse(voice.managesAudioSession)
        voice.managesAudioSession = true
        XCTAssertTrue(voice.managesAudioSession)
    }
}
