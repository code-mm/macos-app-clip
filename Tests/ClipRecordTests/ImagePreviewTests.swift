import AppKit
import XCTest
import ImageIO
import UniformTypeIdentifiers
import ClipCore
@testable import ClipRecord

@MainActor
final class ImagePreviewTests: XCTestCase {
    private func makeContext() async throws -> (AppModel, NSPasteboard, Data) {
        let name = "ClipRecordPreviewTests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        addTeardownBlock {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(dataDirectory: directory.appendingPathComponent("data"),
                             logDirectory: directory.appendingPathComponent("logs"), defaults: defaults)
        await model.start()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        board.setData(data as Data, forType: .png)
        await model.saveCurrent(silently: true, from: board)?.value
        return (model, board, data as Data)
    }

    func testClickAndReturnOnImageOnlyPreview() async throws {
        let (model, board, _) = try await makeContext()
        let record = try XCTUnwrap(model.records.first)
        let changeCount = board.changeCount
        var previewCount = 0
        var pasteCount = 0
        model.onPreview = { item in XCTAssertEqual(item.id, record.id); previewCount += 1 }
        model.onPaste = { _ in pasteCount += 1 }
        model.activateRecord(record)
        model.pasteSelection()
        XCTAssertEqual(previewCount, 2)
        XCTAssertEqual(pasteCount, 0)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertTrue(model.selectedIsImage)
    }

    func testPreviewDoesNotCopyUntilExplicitActionAndReleasesImage() async throws {
        let (model, board, original) = try await makeContext()
        let record = try XCTUnwrap(model.records.first)
        board.clearContents()
        board.setString("keep-until-copy", forType: .string)
        let changeCount = board.changeCount
        let preview = ImagePreviewModel(item: record, store: model.store, log: model.log)
        await preview.load()
        XCTAssertNotNil(preview.image)
        XCTAssertEqual(preview.image?.size, NSSize(width: 1200, height: 800))
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "keep-until-copy")
        await preview.copyImage(to: board)
        XCTAssertEqual(board.data(forType: .png), original)
        XCTAssertNotNil(preview.message)
        preview.releaseImage()
        XCTAssertNil(preview.image)
    }

    func testClosedPreviewDiscardsLateLoadAndCannotCopy() async throws {
        let (model, board, _) = try await makeContext()
        let preview = ImagePreviewModel(item: try XCTUnwrap(model.records.first), store: model.store, log: model.log)
        let changeCount = board.changeCount
        preview.releaseImage()
        await preview.load()
        await preview.copyImage(to: board)
        XCTAssertNil(preview.image)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    func testTextStillUsesPaste() async throws {
        let (model, board, _) = try await makeContext()
        board.clearContents()
        board.setString("text record", forType: .string)
        await model.saveCurrent(silently: true, from: board)?.value
        let record = try XCTUnwrap(model.records.first)
        var pasted: UUID?
        var previewCount = 0
        model.onPaste = { pasted = $0 }
        model.onPreview = { _ in previewCount += 1 }
        model.activateRecord(record)
        XCTAssertEqual(pasted, record.id)
        XCTAssertEqual(previewCount, 0)
    }
}
