import AppKit
import SwiftUI
import ClipCore

@MainActor
final class TextPreviewModel: ObservableObject {
    let item: ClipRecord
    private let store: ClipStore
    private let log: RuntimeLog
    @Published private(set) var text: String?
    @Published private(set) var characterCount = 0
    @Published private(set) var lineCount = 0
    @Published private(set) var loading = true
    @Published private(set) var copying = false
    @Published private(set) var message: String?
    @Published var fontSize: CGFloat = 16
    private var closed = false

    init(item: ClipRecord, store: ClipStore, log: RuntimeLog) {
        self.item = item
        self.store = store
        self.log = log
    }

    func load() async {
        do {
            guard item.kind == .text else { throw ClipError.invalidPayload }
            let (_, data) = try await store.payload(for: item.id)
            let decoded = try await Task.detached(priority: .userInitiated) {
                guard let value = String(data: data, encoding: .utf8) else { throw ClipError.invalidPayload }
                let lines = value.reduce(into: 1) { count, character in
                    if character.isNewline { count += 1 }
                }
                return (value, value.count, lines)
            }.value
            guard !Task.isCancelled, !closed else { return }
            text = decoded.0
            characterCount = decoded.1
            lineCount = decoded.2
            loading = false
            await log.write("text_preview_open", metrics: ["bytes": Double(data.count), "characters": Double(characterCount)])
        } catch {
            guard !Task.isCancelled, !closed else { return }
            loading = false
            message = "文字无法读取，原文件可能已移动或损坏。"
            await log.write("text_preview_failed")
        }
    }

    func copyText(to board: NSPasteboard = .general) async {
        guard !copying, !closed, let text else { return }
        copying = true
        defer { copying = false }
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            message = "复制失败，请重试。"
            await log.write("text_preview_copy_failed")
            return
        }
        message = "全文已复制，可切换到目标应用粘贴。"
        await log.write("text_preview_copied", metrics: ["characters": Double(characterCount)])
    }

    func releaseText() {
        closed = true
        text = nil
        characterCount = 0
        lineCount = 0
    }
}

/// 原生只读文本视图负责选择、换行及可见区域布局；不将全文拆成大量 SwiftUI 子视图。
struct SelectableTextContent: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 0))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 22, height: 20)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textColor = NSColor(red: 33/255, green: 42/255, blue: 54/255, alpha: 1)
        view.backgroundColor = .white
        view.setAccessibilityLabel("完整文字内容")
        view.string = text
        view.font = .systemFont(ofSize: fontSize)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        // 加载后全文不变，字号变化只更新排版，不重复复制／比较整段文本。
        if view.font?.pointSize != fontSize { view.font = .systemFont(ofSize: fontSize) }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        (scroll.documentView as? NSTextView)?.string = ""
        scroll.documentView = nil
    }
}

struct TextPreviewView: View {
    @ObservedObject var model: TextPreviewModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("文字预览").font(.system(size: 16, weight: .semibold))
                    Text(model.loading ? "正在读取全文…" : "\(model.characterCount) 字符 · \(model.lineCount) 行")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { model.fontSize = max(12, model.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                    .help("缩小字号").accessibilityLabel("缩小字号").disabled(model.fontSize <= 12)
                Text("\(Int(model.fontSize)) pt").monospacedDigit().font(.system(size: 12)).frame(width: 40)
                Button { model.fontSize = min(32, model.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                    .help("放大字号").accessibilityLabel("放大字号").disabled(model.fontSize >= 32)
            }.padding(16)
            Divider()
            if let text = model.text {
                SelectableTextContent(text: text, fontSize: model.fontSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.loading {
                ProgressView("正在加载文字…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("无法预览", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                Text(model.message ?? "可选择文字复制，也可直接复制全文")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
                Button { Task { await model.copyText() } } label: {
                    Text(model.copying ? "正在复制…" : "复制全文")
                }.buttonStyle(PrimaryButton()).frame(width: 100).disabled(model.copying || model.text == nil)
                    .accessibilityIdentifier("copyPreviewText")
            }.padding(16)
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(Palette.canvas).foregroundStyle(Palette.ink).preferredColorScheme(.light)
        .task { await model.load() }
        .onDisappear { model.releaseText() }
    }
}
