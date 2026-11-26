import AppKit
import XCTest
@testable import ClipRecord

@MainActor
final class StatusItemFeedbackTests: XCTestCase {
    func testDefaultSuccessSoundIsSystemPing() throws {
        let sound = try XCTUnwrap(StatusItemFeedback.loadSuccessSound())
        XCTAssertEqual(sound.name, "Ping")
        XCTAssertFalse(sound.isPlaying)
    }

    func testMissingOrInvalidLocalSoundFallsBack() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("missing.wav")
        let invalid = folder.appendingPathComponent("invalid.wav")
        try Data("not WAV data".utf8).write(to: invalid)
        let ping = try XCTUnwrap(NSSound(named: "Ping"))
        for url in [missing, invalid] {
            XCTAssertTrue(StatusItemFeedback.loadSuccessSound(localURL: url, fallback: { ping }) === ping)
        }
    }

    func testValidLocalWavUsesOverrideWithoutPlaying() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("record-success.wav")
        // Synthetic 100 ms PCM WAV fixture; no third-party sound ships with tests.
        var data = Data([82,73,70,70,100,6,0,0,87,65,86,69,102,109,116,32,
                         16,0,0,0,1,0,1,0,64,31,0,0,128,62,0,0,2,0,16,0,
                         100,97,116,97,64,6,0,0])
        data.append(Data(repeating: 0, count: 1600))
        try data.write(to: url)
        let sound = try XCTUnwrap(StatusItemFeedback.loadSuccessSound(localURL: url, fallback: { nil }))
        XCTAssertEqual(sound.duration, 0.1, accuracy: 0.02)
        XCTAssertFalse(sound.isPlaying)
    }

    private func makeTemporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
