import AppKit
import XCTest
import ClipCore
@testable import ClipRecord

@MainActor
final class TextPreviewTests: XCTestCase {
    private func makeContext(text: String) async throws -> (AppModel, NSPasteboard, ClipCore.ClipRecord) {
        let name = "ClipRecordTextTests-\(UUID().uuidString)"
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
        board.setString(text, forType: .string)
        await model.saveCurrent(silently: true, from: board)?.value
        return (model, board, try XCTUnwrap(model.records.first))
    }

    func testMultilineTextClickAndReturnOnlyPreview() async throws {
        let (model, board, item) = try await makeContext(text: "第一项\n    保留缩进\n第二项")
        var previewCount = 0
        var pasteCount = 0
        let changeCount = board.changeCount
        model.onPreview = { _ in previewCount += 1 }
        model.onPaste = { _ in pasteCount += 1 }
        model.activateRecord(item)
        model.pasteSelection()
        XCTAssertEqual(previewCount, 2)
        XCTAssertEqual(pasteCount, 0)
        XCTAssertTrue(model.selectedRequiresPreview)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    func testLongSingleLineAndShortTextRouting() async throws {
        let (model, _, item) = try await makeContext(text: String(repeating: "长文本", count: 100))
        XCTAssertTrue(item.requiresPreview)
        XCTAssertEqual(item.preview.count, 240)
        var previewed = false
        model.onPreview = { _ in previewed = true }
        model.activateRecord(item)
        XCTAssertTrue(previewed)
        let (_, _, short) = try await makeContext(text: "简短回复")
        XCTAssertFalse(short.requiresPreview)
    }

    func testFullOriginalNotTruncatedAndCopyIsExplicit() async throws {
        let original = (1...120).map { "\($0). 保留文字、空格和换行\n    第二行" }.joined(separator: "\r\n")
        let (model, board, item) = try await makeContext(text: original)
        let preview = TextPreviewModel(item: item, store: model.store, log: model.log)
        board.clearContents()
        board.setString("do-not-overwrite-on-preview", forType: .string)
        let count = board.changeCount
        await preview.load()
        XCTAssertEqual(preview.text, original)
        XCTAssertGreaterThan(preview.text?.count ?? 0, 240)
        XCTAssertEqual(preview.lineCount, 240)
        XCTAssertEqual(board.changeCount, count)
        await preview.copyText(to: board)
        XCTAssertEqual(board.string(forType: .string), original)
        preview.releaseText()
        XCTAssertNil(preview.text)
        XCTAssertEqual(preview.characterCount, 0)
        let log = try String(contentsOf: model.logDirectory.appendingPathComponent("runtime.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("保留文字"))
    }

    func testClosedPreviewDropsResultAndCannotCopy() async throws {
        let (model, board, item) = try await makeContext(text: "第一行\n第二行")
        let preview = TextPreviewModel(item: item, store: model.store, log: model.log)
        let count = board.changeCount
        preview.releaseText()
        await preview.load()
        await preview.copyText(to: board)
        XCTAssertNil(preview.text)
        XCTAssertEqual(board.changeCount, count)
    }

    func testMissingFileShowsFailureWithoutCopying() async throws {
        let (model, board, item) = try await makeContext(text: "第一行\n第二行")
        try FileManager.default.removeItem(at: await model.store.fileURL(for: item))
        let preview = TextPreviewModel(item: item, store: model.store, log: model.log)
        let count = board.changeCount
        await preview.load()
        XCTAssertFalse(preview.loading)
        XCTAssertNil(preview.text)
        XCTAssertNotNil(preview.message)
        await preview.copyText(to: board)
        XCTAssertEqual(board.changeCount, count)
    }
}
