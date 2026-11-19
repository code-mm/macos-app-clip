import AppKit
import XCTest
@testable import ClipRecord

@MainActor
final class StatusItemFeedbackTests: XCTestCase {
    func testBundledSuccessSoundCanBeDecodedWithoutPlaying() throws {
        let sound = try XCTUnwrap(StatusItemFeedback.loadSuccessSound())
        XCTAssertEqual(sound.duration, 1.304, accuracy: 0.01)
        XCTAssertFalse(sound.isPlaying)
    }

    func testBlinkFinishesAndRestoresOriginalIcon() async {
        let button = NSButton()
        let original = NSImage(size: NSSize(width: 18, height: 18))
        button.image = original
        var sounds: [Bool] = []
        let feedback = StatusItemFeedback(button: button, soundPlayer: { sounds.append($0); return true })
        let task = feedback.show(success: true)
        XCTAssertFalse(button.image === original)
        XCTAssertEqual(button.image?.isTemplate, false)
        let color = button.contentTintColor?.usingColorSpace(.sRGB)
        XCTAssertEqual(color?.greenComponent ?? 0, 0.78, accuracy: 0.01)
        XCTAssertGreaterThan(color?.greenComponent ?? 0, color?.redComponent ?? 1)
        XCTAssertEqual(sounds, [true])
        await task.value
        XCTAssertTrue(button.image === original)
        XCTAssertEqual(button.alphaValue, 1)
        XCTAssertNil(button.contentTintColor)
    }

    func testRepeatedFeedbackAndStopDoNotLeaveDimmedIcon() async {
        let button = NSButton()
        let original = NSImage(size: NSSize(width: 18, height: 18))
        button.image = original
        var sounds: [Bool] = []
        let feedback = StatusItemFeedback(button: button, soundPlayer: { sounds.append($0); return true })
        let first = feedback.show(success: true)
        let second = feedback.show(success: false)
        XCTAssertEqual(button.contentTintColor, NSColor.systemOrange)
        await first.value
        XCTAssertEqual(sounds, [true, false])
        feedback.stop()
        await second.value
        XCTAssertTrue(button.image === original)
        XCTAssertEqual(button.alphaValue, 1)
        XCTAssertNil(button.contentTintColor)
    }
}
