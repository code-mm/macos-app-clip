import XCTest
import Foundation
import ImageIO
import CoreGraphics
@testable import ClipCore

final class ClipCoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipRecordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDoublePressRejectsRepeatAndSlowPresses() {
        var detector = DoublePressDetector()
        XCTAssertFalse(detector.keyDown(at: 1))
        XCTAssertFalse(detector.keyDown(at: 1.1), "Holding F1 must not toggle")
        detector.keyUp()
        XCTAssertTrue(detector.keyDown(at: 1.25))
        detector.keyUp()
        XCTAssertFalse(detector.keyDown(at: 2))
        detector.keyUp()
        XCTAssertFalse(detector.keyDown(at: 3))
        detector.keyUp()
        XCTAssertTrue(detector.keyDown(at: 3.2))
        detector.reset()
        XCTAssertFalse(detector.keyDown(at: 3.3))
    }

    func testPanelAndRecordDoublePressesRemainIndependent() {
        var panel = DoublePressDetector()
        var record = DoublePressDetector()
        XCTAssertFalse(panel.keyDown(at: 1))
        panel.keyUp()
        XCTAssertFalse(record.keyDown(at: 1.1), "F1 followed by F2 must not count as a double press")
        record.keyUp()
        XCTAssertTrue(panel.keyDown(at: 1.2))
        panel.keyUp()
        XCTAssertTrue(record.keyDown(at: 1.3))
        XCTAssertFalse(record.keyDown(at: 1.31), "Held F2 must not save repeatedly")
    }

    func testStoreDeduplicatesPersistsAndPrunesPayloads() async throws {
        let directory = try temporaryDirectory()
        let limits = StorageLimits(count: 2, totalBytes: 20, itemBytes: 20)
        let store = ClipStore(directory: directory, limits: limits)
        _ = try await store.load()
        let first = try await store.save(.text("alpha"))
        let firstID = try XCTUnwrap(first.first?.id)
        _ = try await store.save(.text("beta"))
        let duplicate = try await store.save(.text("alpha"))
        XCTAssertEqual(duplicate.count, 2)
        XCTAssertEqual(duplicate.first?.id, firstID)
        let final = try await store.save(.text("gamma"))
        XCTAssertEqual(final.map(\.preview), ["gamma", "alpha"])
        let reload = ClipStore(directory: directory, limits: limits)
        let loaded = try await reload.load()
        XCTAssertEqual(final, loaded)
        let (_, data) = try await reload.payload(for: firstID)
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("items").path).count, 2)
    }

    func testByteLimitAndOversizedWriteLeaveOldIndexIntact() async throws {
        let directory = try temporaryDirectory()
        let store = ClipStore(directory: directory, limits: .init(count: 20, totalBytes: 8, itemBytes: 6))
        _ = try await store.load()
        _ = try await store.save(.text("aaaa"))
        let final = try await store.save(.text("bbbbb"))
        XCTAssertEqual(final.map(\.preview), ["bbbbb"])
        do { _ = try await store.save(.text("1234567")); XCTFail("oversize accepted") }
        catch { XCTAssertTrue(error is ClipError) }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.bytes, 5)
    }

    func testInvalidIndexIsPreservedAndDoesNotDeleteFiles() async throws {
        let directory = try temporaryDirectory()
        let index = directory.appendingPathComponent("index.json")
        let bytes = Data("corrupt-index".utf8)
        try bytes.write(to: index)
        let store = ClipStore(directory: directory)
        do { _ = try await store.load(); XCTFail("invalid index accepted") }
        catch { XCTAssertTrue(error is ClipError) }
        XCTAssertEqual(try Data(contentsOf: index), bytes)
    }

    func testDeleteRemovesFileAndSurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        let store = ClipStore(directory: directory)
        _ = try await store.load()
        let saved = try await store.save(.text("delete me"))
        let item = try XCTUnwrap(saved.first)
        _ = try await store.delete(item.id)
        let reloaded = try await ClipStore(directory: directory).load()
        XCTAssertTrue(reloaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("items/\(item.filename)").path))
    }

    func testHeightGrowsAndClampsToScreen() {
        let empty = PanelLayout.listHeight(count: 0, availableHeight: 900, notice: false)
        let few = PanelLayout.listHeight(count: 3, availableHeight: 900, notice: false)
        let many = PanelLayout.listHeight(count: 500, availableHeight: 900, notice: false)
        XCTAssertLessThan(empty, few)
        XCTAssertLessThan(few, many)
        XCTAssertLessThanOrEqual(many + 362 + 36, 900)
        XCTAssertLessThanOrEqual(PanelLayout.listHeight(count: 500, availableHeight: 600, notice: true) + 438 + 36, 600)
    }

    func testLogRotationRemainsBoundedAndJSONDecodable() async throws {
        let directory = try temporaryDirectory()
        let log = RuntimeLog(directory: directory, maxBytes: 256, backups: 3)
        for index in 0..<100 { await log.write("sample", metrics: ["count": Double(index)]) }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertLessThanOrEqual(urls.count, 4)
        for url in urls {
            let data = try Data(contentsOf: url)
            XCTAssertLessThanOrEqual(data.count, 256)
            for line in data.split(separator: 10) { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: line)) }
        }
    }

    func testSustainedWritesKeepOnly500RecordsAndFiles() async throws {
        let directory = try temporaryDirectory()
        let store = ClipStore(directory: directory)
        _ = try await store.load()
        let before = ResourceSample.capture()
        var saved: [ClipRecord] = []
        for index in 0..<650 { saved = try await store.save(.text("synthetic-stress-\(index)")) }
        let after = ResourceSample.capture()
        XCTAssertEqual(saved.count, 500)
        XCTAssertEqual(saved.first?.preview, "synthetic-stress-649")
        XCTAssertEqual(saved.last?.preview, "synthetic-stress-150")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("items").path)
        XCTAssertEqual(files.count, 500)
        let reloaded = try await ClipStore(directory: directory).load()
        XCTAssertEqual(reloaded.count, 500)
        print("STRESS writes=650 retained=500 resident_before=\(before.residentBytes) resident_after=\(after.residentBytes)")
    }

    func testImageMetadataAndBoundedThumbnail() throws {
        let directory = try temporaryDirectory()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1800, height: 1200, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1800, height: 1200))
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("image.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let (width, height) = try ImageSupport.dimensions(Data(contentsOf: url))
        XCTAssertEqual(width, 1800)
        XCTAssertEqual(height, 1200)
        let thumbnail = try XCTUnwrap(ImageSupport.thumbnail(at: url, maxPixels: 240))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 240)
        XCTAssertThrowsError(try ImageSupport.dimensions(Data("not-an-image".utf8)))
    }

    func testPreviewDecodeRespectsPixelAndMemoryBounds() {
        for (width, height) in [(8000, 5000), (6000, 6000), (1000, 30000), (995, 2129)] {
            let edge = ImageSupport.previewPixelLimit(width: width, height: height)
            let scale = Double(edge) / Double(max(width, height))
            XCTAssertLessThanOrEqual(edge, 4096)
            XCTAssertLessThanOrEqual(Double(width) * Double(height) * scale * scale, 8_000_000)
        }
        XCTAssertEqual(ImageSupport.previewPixelLimit(width: 995, height: 2129), 2129)
    }
}
