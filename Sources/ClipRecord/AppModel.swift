import AppKit
import SwiftUI
import ClipCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var records: [ClipRecord] = []
    @Published private(set) var busy = false
    @Published var notice: String?
    @Published var search = ""
    @Published var selection: UUID?
    @Published var availableHeight: CGFloat = 800
    @Published var shortcut: Shortcut
    @Published var hotkeyError: String?
    @Published var recordHotkeyError: String?
    @Published var recordingShortcut = false
    @Published var ready = false
    @Published var dropTargeted = false

    let store: ClipStore
    let log: RuntimeLog
    let dataDirectory: URL
    let logDirectory: URL
    let thumbnails = ThumbnailCache()
    var onPaste: ((UUID) -> Void)?
    var onPreview: ((ClipRecord) -> Void)?
    var onSettings: (() -> Void)?
    var onHide: (() -> Void)?
    var onShortcutChange: ((Shortcut) -> Bool)?
    var onChooseImage: (() -> Void)?
    var onSilentRecordResult: ((Bool) -> Void)?
    private let defaults: UserDefaults

    init(dataDirectory: URL, logDirectory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dataDirectory = dataDirectory
        self.logDirectory = logDirectory
        self.store = ClipStore(directory: dataDirectory)
        self.log = RuntimeLog(directory: logDirectory)
        if let data = defaults.data(forKey: "globalShortcut"),
           let value = try? JSONDecoder().decode(Shortcut.self, from: data),
           value.keyCode <= 126, value.keyLabel.count <= 24 {
            shortcut = value
        } else { shortcut = .defaultValue }
    }

    func start() async {
        do {
            records = try await store.load()
            ready = true
            selection = records.first?.id
            await log.write("launch", metrics: ["records": Double(records.count)])
        } catch {
            notice = error.localizedDescription
            await log.write("storage_load_failed")
        }
    }

    var filtered: [ClipRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return records }
        return records.filter {
            $0.preview.localizedStandardContains(query)
            || $0.title.localizedStandardContains(query)
            || ($0.kind == .image && "图片".contains(query))
        }
    }

    var listHeight: CGFloat {
        CGFloat(PanelLayout.listHeight(count: filtered.count, availableHeight: availableHeight,
                                      notice: notice != nil))
    }

    var panelHeight: CGFloat { listHeight + (notice == nil ? 362 : 438) }

    @discardableResult
    func saveCurrent(silently: Bool = false, from board: NSPasteboard = .general) -> Task<Void, Never>? {
        guard !busy, ready else {
            if silently { onSilentRecordResult?(false) }
            return nil
        }
        do { return saveInput(try ClipboardImport.read(from: board), silently: silently) }
        catch { return Task { await recordSaveFailure(error, silently: silently) } }
    }

    @discardableResult
    func saveInput(_ input: ClipboardInput, silently: Bool = false) -> Task<Void, Never>? {
        guard !busy, ready else {
            if silently {
                onSilentRecordResult?(false)
                Task { await log.write("record_skipped", metrics: ["silent": 1, "busy": busy ? 1 : 0, "ready": ready ? 1 : 0]) }
            }
            return nil
        }
        busy = true
        let started = ProcessInfo.processInfo.systemUptime
        return Task {
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    let accessURL: URL?
                    if case .imageFile(let url) = input { accessURL = url } else { accessURL = nil }
                    let scoped = accessURL?.startAccessingSecurityScopedResource() ?? false
                    defer { if scoped { accessURL?.stopAccessingSecurityScopedResource() } }
                    return try ClipboardImport.prepare(input)
                }.value
                records = try await store.save(payload)
                selection = records.first?.id
                if !silently { notice = "已记录到本机" }
                if silently { onSilentRecordResult?(true) }
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                await log.write("record_saved", metrics: ["kind": payload.kind == .image ? 1 : 0,
                                                          "bytes": Double(payload.data.count), "duration_ms": elapsed,
                                                          "records": Double(records.count), "silent": silently ? 1 : 0])
            } catch {
                await recordSaveFailure(error, silently: silently)
            }
            busy = false
        }
    }

    private func recordSaveFailure(_ error: Error, silently: Bool) async {
        if !silently { notice = error.localizedDescription }
        if silently { onSilentRecordResult?(false) }
        let reason: Double
        switch error {
        case ClipError.empty: reason = 1
        case ClipError.oversized: reason = 2
        case ClipError.invalidImage: reason = 3
        default: reason = 4
        }
        await log.write("record_save_failed", metrics: ["silent": silently ? 1 : 0, "reason": reason])
    }

    func delete(_ item: ClipRecord) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                records = try await store.delete(item.id)
                thumbnails.remove(item.id)
                selection = filtered.first?.id
                await log.write("record_deleted")
            } catch { notice = "删除失败，请重试。" }
            busy = false
        }
    }

    func moveSelection(_ offset: Int) {
        let items = filtered
        guard !items.isEmpty else { selection = nil; return }
        let oldIndex = items.firstIndex(where: { $0.id == selection }) ?? (offset > 0 ? -1 : items.count)
        let index = min(items.count - 1, max(0, oldIndex + offset))
        selection = items[index].id
    }

    func pasteSelection() {
        guard let item = filtered.first(where: { $0.id == selection }) ?? filtered.first else { return }
        activateRecord(item)
    }

    func activateRecord(_ item: ClipRecord) {
        selection = item.id
        if item.requiresPreview { onPreview?(item) }
        else { onPaste?(item.id) }
    }

    var selectedIsImage: Bool {
        (filtered.first(where: { $0.id == selection }) ?? filtered.first)?.kind == .image
    }

    var selectedRequiresPreview: Bool {
        (filtered.first(where: { $0.id == selection }) ?? filtered.first)?.requiresPreview == true
    }

    func updateShortcut(_ value: Shortcut) {
        guard onShortcutChange?(value) == true else { return }
        shortcut = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "globalShortcut") }
        recordingShortcut = false
        Task { await log.write("shortcut_updated") }
    }

    func clearTransientState() {
        dropTargeted = false
        search = ""
        notice = nil
        thumbnails.clear()
    }
}

@MainActor
final class ThumbnailCache {
    private let cache = NSCache<NSUUID, NSImage>()
    init() { cache.totalCostLimit = 12 * 1_024 * 1_024; cache.countLimit = 80 }
    func image(for item: ClipRecord, store: ClipStore) async -> NSImage? {
        if let image = cache.object(forKey: item.id as NSUUID) { return image }
        let url = await store.fileURL(for: item)
        let cgImage = await Task.detached(priority: .utility) {
            ImageSupport.thumbnail(at: url, maxPixels: 240)
        }.value
        guard !Task.isCancelled, let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: item.id as NSUUID, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
    func remove(_ id: UUID) { cache.removeObject(forKey: id as NSUUID) }
    func clear() { cache.removeAllObjects() }
}
