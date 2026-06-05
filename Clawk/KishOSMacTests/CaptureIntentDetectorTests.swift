import XCTest
@testable import KishOS

final class CaptureIntentDetectorTests: XCTestCase {
    func testDetectsPhotoRequestAndCleansPrompt() {
        let intent = CaptureIntentDetector.detect(in: "Take a picture and tell me if this plant is healthy")

        XCTAssertEqual(intent?.mediaKind, .photo)
        XCTAssertEqual(intent?.source, .automatic)
        XCTAssertEqual(intent?.prompt, "Tell me if this plant is healthy")
    }

    func testDetectsGlassesSourcePreference() {
        let intent = CaptureIntentDetector.detect(in: "Use the glasses camera and describe this")

        XCTAssertEqual(intent?.mediaKind, .photo)
        XCTAssertEqual(intent?.source, .glassesCamera)
        XCTAssertEqual(intent?.prompt, "Describe this")
    }

    func testDetectsPlainGlassesSourcePreference() {
        let intent = CaptureIntentDetector.detect(in: "Take a picture with glasses")

        XCTAssertEqual(intent?.mediaKind, .photo)
        XCTAssertEqual(intent?.source, .glassesCamera)
        XCTAssertEqual(intent?.prompt, "Look at the attached image and respond.")
    }

    func testDetectsPhoneSourcePreference() {
        let intent = CaptureIntentDetector.detect(in: "Take a photo with my phone and read the label")

        XCTAssertEqual(intent?.mediaKind, .photo)
        XCTAssertEqual(intent?.source, .phoneCamera)
        XCTAssertEqual(intent?.prompt, "Read the label")
    }

    func testPlainTextDoesNotTriggerCapture() {
        XCTAssertNil(CaptureIntentDetector.detect(in: "Summarize this repository"))
    }

    func testVideoIntentIsRecognizedForFutureFlow() {
        let intent = CaptureIntentDetector.detect(in: "Record a video and summarize what happens")

        XCTAssertEqual(intent?.mediaKind, .video)
        XCTAssertEqual(intent?.prompt, "Summarize what happens")
    }
}
