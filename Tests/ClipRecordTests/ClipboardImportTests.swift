import AppKit
import XCTest
import ClipCore
import ImageIO
import UniformTypeIdentifiers
@testable import ClipRecord

@MainActor
final class ClipboardImportTests: XCTestCase {
    private func context() async -> (AppModel, NSPasteboard, URL) {
        let name = "ClipRecordImportTests-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let preferences = UserDefaults(suiteName: name)!
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        addTeardownBlock {
            board.releaseGlobally()
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(dataDirectory: root.appendingPathComponent("data"),
                             logDirectory: root.appendingPathComponent("logs"), defaults: preferences)
        await model.start()
        return (model, board, root)
    }

    private func imageData(type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testImageFilePasteRecordsBytesWithoutChangingPasteboard() async throws {
        let (model, board, root) = await context()
        let url = root.appendingPathComponent("example.png")
        let data = try imageData()
        try data.write(to: url)
        XCTAssertTrue(board.writeObjects([url as NSURL]))
        let count = board.changeCount
        await model.saveCurrent(from: board)?.value
        let item = try XCTUnwrap(model.records.first)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.pixelWidth, 40)
        let (_, saved) = try await model.store.payload(for: item.id)
        XCTAssertEqual(saved, data)
        XCTAssertEqual(board.changeCount, count)
    }

    func testChosenJPEGIsNormalizedAndStoredAsImage() async throws {
        let (model, _, root) = await context()
        let url = root.appendingPathComponent("example.jpg")
        try imageData(type: .jpeg).write(to: url)
        await model.saveInput(.imageFile(url))?.value
        let item = try XCTUnwrap(model.records.first)
        XCTAssertEqual(item.kind, .image)
        XCTAssertTrue(item.filename.hasSuffix(".png"))
        let (_, saved) = try await model.store.payload(for: item.id)
        let (width, height) = try ImageSupport.dimensions(saved)
        XCTAssertEqual(width, 40)
        XCTAssertEqual(height, 30)
    }

    func testUnsupportedFileIsRejectedInsteadOfRecordingPath() async throws {
        let (model, board, root) = await context()
        let url = root.appendingPathComponent("notes.txt")
        try Data("file content".utf8).write(to: url)
        XCTAssertTrue(board.writeObjects([url as NSURL]))
        await model.saveCurrent(from: board)?.value
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.notice, "目前支持文字和图片，请选择图片文件。")
    }

    func testMultipleImageFilesAreRejected() async throws {
        let (model, board, root) = await context()
        let first = root.appendingPathComponent("one.png")
        let second = root.appendingPathComponent("two.png")
        let data = try imageData()
        try data.write(to: first)
        try data.write(to: second)
        XCTAssertTrue(board.writeObjects([first as NSURL, second as NSURL]))
        await model.saveCurrent(from: board)?.value
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.notice, "请每次放入一张图片。")
    }

    func testDroppedTextUsesSameLimitsAndPreservesNewlines() async throws {
        let (model, _, _) = await context()
        let text = "拖入文字\n保留换行"
        await model.saveInput(.text(text))?.value
        let record = try XCTUnwrap(model.records.first)
        let (_, saved) = try await model.store.payload(for: record.id)
        XCTAssertEqual(String(data: saved, encoding: .utf8), text)
        await model.saveInput(.text(String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)))?.value
        XCTAssertEqual(model.records.count, 1)
        XCTAssertFalse(model.busy)
    }
}
