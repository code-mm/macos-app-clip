import AppKit
import SwiftUI
import ClipCore

// Export real application views using synthetic data only. Never read NSPasteboard.general.
@main
struct ReadmeAssets {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await render()
                app.terminate(nil)
            } catch {
                fputs("README rendering failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    static func render() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let data = root.appendingPathComponent("build/readme-render-data")
        let output = root.appendingPathComponent("docs/media")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // This directory is owned by this script and contains no user records.
        if FileManager.default.fileExists(atPath: data.path) { try FileManager.default.removeItem(at: data) }
        let defaults = UserDefaults(suiteName: "com.codemm.cliprecord.readme")!
        var model = AppModel(dataDirectory: data, logDirectory: data.appendingPathComponent("logs"), defaults: defaults)
        await model.start()
        let note = """
        项目笔记｜把灵感留在手边

        一、随手记录
        双击 F2，保存当前剪贴板中的文字或图片。
        绿色闪烁与清脆提示音，告诉你记录已完成。

        二、快速查找
        双击 F1，打开或隐藏记录面板。
        输入关键词，在保存的内容中快速查找。

        三、看清再复制
        图片可以放大，长文本可以独立阅读。
        确认内容后，再点击复制。

        这是一段公开展示用的虚构笔记。
        """
        await model.saveInput(.text("收到，谢谢！我会整理后回复你。"), silently: true)?.value
        await model.saveInput(.text(note), silently: true)?.value
        let icon = root.appendingPathComponent("docs/design/gray-yellow-v2/clipboard-icon.png")
        await model.saveInput(.imageFile(icon), silently: true)?.value
        await model.saveInput(.text("今日灵感\n让常用的文字和图片，随手记录，随时取用。"), silently: true)?.value
        // Use a fixed demonstration date for reproducible public images.
        let index = data.appendingPathComponent("index.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
        var records = json["records"] as! [[String: Any]]
        let fixedDate = ISO8601DateFormatter().date(from: "2026-11-16T02:30:00Z")!.timeIntervalSinceReferenceDate
        for i in records.indices { records[i]["createdAt"] = fixedDate - Double(i * 60) }
        json["records"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: index)
        model = AppModel(dataDirectory: data, logDirectory: data.appendingPathComponent("logs"), defaults: defaults)
        await model.start()
        model.availableHeight = 1100
        try await capture(ClipboardPanelView(model: model, onHeight: { _ in }),
                          size: NSSize(width: 472, height: model.panelHeight), to: output.appendingPathComponent("main-panel.png"))
        let textItem = model.records.first { $0.preview.hasPrefix("项目笔记") }!
        let text = TextPreviewModel(item: textItem, store: model.store, log: model.log)
        await text.load()
        try await capture(TextPreviewView(model: text, close: {}), size: NSSize(width: 820, height: 650),
                          to: output.appendingPathComponent("text-preview.png"))
        let imageItem = model.records.first { $0.kind == .image }!
        let image = ImagePreviewModel(item: imageItem, store: model.store, log: model.log)
        await image.load()
        try await capture(ImagePreviewView(model: image, close: {}), size: NSSize(width: 820, height: 650),
                          to: output.appendingPathComponent("image-preview.png"))
        let settings = SettingsView(model: model, close: {}, beginRecording: {}, cancelRecording: {})
        let settingsSize = NSHostingView(rootView: settings).fittingSize
        try await capture(settings, size: settingsSize, to: output.appendingPathComponent("settings.png"))
        print("Exported 4 native view images using synthetic records: \(output.path)")
    }

    @MainActor
    static func capture<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.size = size
        host.cacheDisplay(in: host.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}
