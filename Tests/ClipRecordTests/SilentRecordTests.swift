import AppKit
import XCTest
import ImageIO
import UniformTypeIdentifiers
import ClipCore
@testable import ClipRecord

@MainActor
final class SilentRecordTests: XCTestCase {
    private func makeModel() async -> (AppModel, NSPasteboard) {
        let name = "ClipRecordSilentTests-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let preferences = UserDefaults(suiteName: name)!
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        addTeardownBlock {
            preferences.removePersistentDomain(forName: name)
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(dataDirectory: root.appendingPathComponent("data"),
                             logDirectory: root.appendingPathComponent("logs"), defaults: preferences)
        await model.start()
        return (model, board)
    }

    func testSilentTextSavePersistsWithoutClipboardOrUIEffects() async throws {
        let (model, board) = await makeModel()
        board.setString("F2 静默记录测试", forType: .string)
        let changeCount = board.changeCount
        var uiActions = 0
        model.onPaste = { _ in uiActions += 1 }
        model.onSettings = { uiActions += 1 }
        model.onHide = { uiActions += 1 }
        let task = try XCTUnwrap(model.saveCurrent(silently: true, from: board))
        await task.value
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.records.first?.preview, "F2 静默记录测试")
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(uiActions, 0)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "F2 静默记录测试")
        let loaded = try await ClipStore(directory: model.dataDirectory).load()
        XCTAssertEqual(loaded, model.records)
        let log = try String(contentsOf: model.logDirectory.appendingPathComponent("runtime.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("F2 静默记录测试"))
        XCTAssertTrue(log.contains("record_saved"))
    }

    func testSilentDuplicateSaveKeepsOneRecordAndExistingNotice() async throws {
        let (model, board) = await makeModel()
        board.setString("same-content", forType: .string)
        await model.saveCurrent(silently: true, from: board)?.value
        let originalID = model.records.first?.id
        model.notice = "保留当前提示"
        await model.saveCurrent(silently: true, from: board)?.value
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.records.first?.id, originalID)
        XCTAssertEqual(model.notice, "保留当前提示")
    }

    func testEmptyAndInvalidImageStaySilent() async {
        let (model, board) = await makeModel()
        board.clearContents()
        await model.saveCurrent(silently: true, from: board)?.value
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.records.isEmpty)
        board.setData(Data("invalid-image".utf8), forType: .png)
        await model.saveCurrent(silently: true, from: board)?.value
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertFalse(model.busy)
    }

    func testSilentImageSavePreservesOriginalBytes() async throws {
        let (model, board) = await makeModel()
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        board.setData(data as Data, forType: .png)
        let changeCount = board.changeCount
        await model.saveCurrent(silently: true, from: board)?.value
        let record = try XCTUnwrap(model.records.first)
        XCTAssertEqual(record.kind, .image)
        XCTAssertEqual(record.pixelWidth, 32)
        XCTAssertEqual(record.pixelHeight, 24)
        let (_, saved) = try await model.store.payload(for: record.id)
        XCTAssertEqual(saved, data as Data)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertNil(model.notice)
    }

    func testF2CannotBeAssignedToPanelToggle() {
        let service = HotkeyService()
        defer { service.stop() }
        XCTAssertNotEqual(service.register(.recordCurrent), 0)
        XCTAssertEqual(Shortcut.defaultValue.label, "双击 F1")
        XCTAssertEqual(Shortcut.recordCurrent.label, "双击 F2")
    }

    func testSuccessFeedbackOccursAfterIndexIsCommittedAndIncludesDuplicates() async throws {
        let (model, board) = await makeModel()
        board.setString("confirmed-save", forType: .string)
        var results: [Bool] = []
        model.onSilentRecordResult = { success in
            results.append(success)
            XCTAssertTrue(FileManager.default.fileExists(atPath: model.dataDirectory.appendingPathComponent("index.json").path))
            XCTAssertEqual(model.records.count, 1)
        }
        await model.saveCurrent(silently: true, from: board)?.value
        await model.saveCurrent(silently: true, from: board)?.value
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(model.records.count, 1)
        XCTAssertNil(model.notice)
        model.onSilentRecordResult = nil
    }

    func testFailureFeedbackNeverReportsSuccess() async throws {
        let (model, board) = await makeModel()
        var results: [Bool] = []
        model.onSilentRecordResult = { results.append($0) }
        board.clearContents()
        await model.saveCurrent(silently: true, from: board)?.value
        board.setData(Data("bad-image".utf8), forType: .png)
        await model.saveCurrent(silently: true, from: board)?.value
        let index = model.dataDirectory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        board.clearContents()
        board.setString("cannot-commit", forType: .string)
        await model.saveCurrent(silently: true, from: board)?.value
        XCTAssertEqual(results, [false, false, false])
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertNil(model.notice)
    }

    func testOrdinaryButtonSaveDoesNotPlayHotkeyFeedback() async throws {
        let (model, board) = await makeModel()
        var results: [Bool] = []
        model.onSilentRecordResult = { results.append($0) }
        board.setString("button-save", forType: .string)
        await model.saveCurrent(from: board)?.value
        board.clearContents()
        await model.saveCurrent(from: board)?.value
        XCTAssertTrue(results.isEmpty)
    }
}
