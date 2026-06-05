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
final class RouteStateDerivationTests: XCTestCase {
    // Convenience wrapper with sensible defaults so each test only sets what it cares about.
    private func derive(
        isUnavailable: Bool = false,
        isExternalActive: Bool = false,
        hasExternalAvailable: Bool = false,
        isCallSessionActive: Bool = false,
        wasExternalSeenInCallSession: Bool = false,
        isAttempting: Bool = false
    ) -> RouteState {
        AudioRouteMonitor.deriveRouteState(
            isUnavailable: isUnavailable,
            isExternalActive: isExternalActive,
            hasExternalAvailable: hasExternalAvailable,
            isCallSessionActive: isCallSessionActive,
            wasExternalSeenInCallSession: wasExternalSeenInCallSession,
            isAttempting: isAttempting
        )
    }

    func testDefaultIsSystem() {
        XCTAssertEqual(derive(), .system)
    }

    func testBlockedWhenUnavailable() {
        XCTAssertEqual(derive(isUnavailable: true), .blocked)
    }

    func testExternalActiveWhenActive() {
        XCTAssertEqual(derive(isExternalActive: true), .externalActive)
    }

    func testExternalAvailableWhenAvailableOutsideCall() {
        XCTAssertEqual(derive(hasExternalAvailable: true), .externalAvailable)
    }

    func testSwitchingWhenAttempting() {
        XCTAssertEqual(derive(isAttempting: true), .switching)
    }

    func testSwitchingWhenExternalAvailableInsideCallButNotYetActive() {
        XCTAssertEqual(
            derive(hasExternalAvailable: true, isCallSessionActive: true),
            .switching
        )
    }

    func testLostInsideCallAfterExternalSeenAndNowGone() {
        XCTAssertEqual(
            derive(
                hasExternalAvailable: false,
                isCallSessionActive: true,
                wasExternalSeenInCallSession: true
            ),
            .lost
        )
    }

    // "lost" requires an active call session. Same flags outside a call → system.
    func testNotLostOutsideCallSession() {
        XCTAssertEqual(
            derive(
                hasExternalAvailable: false,
                isCallSessionActive: false,
                wasExternalSeenInCallSession: true
            ),
            .system
        )
    }

    // "lost" requires the external route to have been seen earlier this session.
    func testNotLostIfExternalNeverSeenInSession() {
        XCTAssertEqual(
            derive(
                hasExternalAvailable: false,
                isCallSessionActive: true,
                wasExternalSeenInCallSession: false
            ),
            .system
        )
    }

    // If the external route is still available again inside the call, it is switching,
    // not lost.
    func testSwitchingNotLostWhenExternalCameBackAvailable() {
        XCTAssertEqual(
            derive(
                hasExternalAvailable: true,
                isCallSessionActive: true,
                wasExternalSeenInCallSession: true
            ),
            .switching
        )
    }

    // MARK: - Priority ordering

    // blocked beats everything, including externalActive.
    func testBlockedBeatsExternalActive() {
        XCTAssertEqual(
            derive(isUnavailable: true, isExternalActive: true),
            .blocked
        )
    }

    // externalActive beats lost: if the route is active it is not lost.
    func testExternalActiveBeatsLost() {
        XCTAssertEqual(
            derive(
                isExternalActive: true,
                hasExternalAvailable: false,
                isCallSessionActive: true,
                wasExternalSeenInCallSession: true
            ),
            .externalActive
        )
    }

    // externalActive beats switching: active route wins over an in-flight attempt.
    func testExternalActiveBeatsSwitching() {
        XCTAssertEqual(
            derive(isExternalActive: true, isAttempting: true),
            .externalActive
        )
    }

    // lost beats switching: when external is seen-but-gone in a call, report lost even
    // if (hypothetically) an attempt is in flight.
    func testLostBeatsSwitching() {
        XCTAssertEqual(
            derive(
                hasExternalAvailable: false,
                isCallSessionActive: true,
                wasExternalSeenInCallSession: true,
                isAttempting: true
            ),
            .lost
        )
    }

    // switching beats externalAvailable when attempting outside a call.
    func testSwitchingBeatsExternalAvailableWhenAttempting() {
        XCTAssertEqual(
            derive(hasExternalAvailable: true, isAttempting: true),
            .switching
        )
    }
}

@MainActor
final class RouteStateLabelTests: XCTestCase {
    private func makeMonitor() -> AudioRouteMonitor {
        let suiteName = "RouteStateLabelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return AudioRouteMonitor(userDefaults: defaults)
    }

    func testRouteStateDefaultsToSystem() {
        XCTAssertEqual(makeMonitor().routeState, .system)
    }

    // The only RouteState reachable on a fresh macOS monitor without mutating private
    // AVAudioSession state is `.system`. Assert the production computed labels directly
    // for that case (no mirror, real code under test).
    func testSystemLabelsFromLiveMonitor() {
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.routeState, .system)
        XCTAssertEqual(monitor.routeStateLabel, "Phone audio")
        XCTAssertEqual(monitor.callRouteLabel, "Phone")
    }

    // Exhaustive label mapping for every RouteState, asserted directly against the
    // production static `AudioRouteMonitor.routeStateLabel(for:kind:)`. This catches a
    // typo or missing case in the REAL switch (the instance computed property delegates
    // to this static). `.externalActive` is exercised with real `kind` values.
    func testRouteStateLabelMappingIsExhaustive() {
        let cases: [(RouteState, AudioRouteKind, String)] = [
            (.system, .system, "Phone audio"),
            (.externalAvailable, .system, "External available"),
            (.externalActive, .glasses, "Glasses"),
            (.externalActive, .bluetooth, "Bluetooth"),
            (.externalActive, .headset, "Headset"),
            (.switching, .system, "Switching…"),
            (.lost, .system, "Lost · phone audio"),
            (.blocked, .system, "Audio blocked")
        ]
        for (state, kind, expected) in cases {
            XCTAssertEqual(
                AudioRouteMonitor.routeStateLabel(for: state, kind: kind),
                expected,
                "routeStateLabel for \(state)/\(kind)"
            )
        }
    }

    func testCallRouteLabelMappingIsExhaustive() {
        let cases: [(RouteState, AudioRouteKind, String)] = [
            (.system, .system, "Phone"),
            (.externalAvailable, .system, "External ready"),
            (.externalActive, .glasses, "Glasses"),
            (.externalActive, .bluetooth, "Bluetooth"),
            (.switching, .system, "Switching…"),
            (.lost, .system, "Lost · phone"),
            (.blocked, .system, "Blocked")
        ]
        for (state, kind, expected) in cases {
            XCTAssertEqual(
                AudioRouteMonitor.callRouteLabel(for: state, kind: kind),
                expected,
                "callRouteLabel for \(state)/\(kind)"
            )
        }
    }
}

@MainActor
final class RouteNameClassificationTests: XCTestCase {
    // These names hit the REAL production classifier `AudioRouteMonitor.classifyRouteName`,
    // which reuses the same `isGlassesLikeName` / `isExternalLikeName` patterns the live
    // route path uses (no mirror).
    //
    // NOTE: the exact route names iOS reports for the Ray-Ban Meta Gen 3 over Bluetooth
    // HFP are NOT yet confirmed. The strings below are our best guess at Gen 3 names.
    // Hardware QA must record the real observed names (see
    // .context/rayban-meta-gen3-route-matrix.md) and tighten these patterns if the real
    // names differ.

    func testGlassesLikeNamesClassifyAsGlasses() {
        let glassesNames = [
            "Ray-Ban Meta",
            "RB Meta",
            "Ray-Ban Meta Gen 3",
            "rayban",
            "Meta glasses",
            "Glasses"
        ]
        for name in glassesNames {
            XCTAssertEqual(
                AudioRouteMonitor.classifyRouteName(name),
                .glasses,
                "expected \(name) to classify as .glasses"
            )
        }
    }

    func testNonGlassesNamesDoNotClassifyAsGlasses() {
        let nonGlassesNames = [
            "AirPods Pro",
            "iPhone Microphone",
            "MacBook Pro Microphone",
            "Beats"
        ]
        for name in nonGlassesNames {
            XCTAssertNotEqual(
                AudioRouteMonitor.classifyRouteName(name),
                .glasses,
                "expected \(name) NOT to classify as .glasses"
            )
        }
    }

    // The classifier still falls back to the external/bluetooth name logic for known
    // external accessories, and to the provided fallback for plain built-in names.
    func testExternalNamesClassifyAsBluetoothNotGlasses() {
        XCTAssertEqual(AudioRouteMonitor.classifyRouteName("AirPods Pro"), .bluetooth)
        XCTAssertEqual(AudioRouteMonitor.classifyRouteName("Beats"), .bluetooth)
    }

    func testNonExternalNameUsesFallback() {
        XCTAssertEqual(
            AudioRouteMonitor.classifyRouteName("MacBook Pro Microphone", fallback: .builtIn),
            .builtIn
        )
        XCTAssertEqual(AudioRouteMonitor.classifyRouteName("iPhone Microphone"), .unknown)
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
