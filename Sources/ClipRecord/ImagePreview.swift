import AppKit
import SwiftUI
import ClipCore

@MainActor
final class ImagePreviewModel: ObservableObject {
    let item: ClipRecord
    private let store: ClipStore
    private let log: RuntimeLog
    @Published private(set) var image: NSImage?
    @Published private(set) var loading = true
    @Published private(set) var copying = false
    @Published private(set) var message: String?
    @Published var zoom: CGFloat?
    private var closed = false

    init(item: ClipRecord, store: ClipStore, log: RuntimeLog) {
        self.item = item
        self.store = store
        self.log = log
    }

    func load() async {
        let url = await store.fileURL(for: item)
        let width = item.pixelWidth ?? 1
        let height = item.pixelHeight ?? 1
        let cgImage = await Task.detached(priority: .userInitiated) {
            ImageSupport.preview(at: url, width: width, height: height)
        }.value
        guard !Task.isCancelled, !closed else { return }
        loading = false
        guard let cgImage else {
            message = "图片无法读取，原文件可能已移动或损坏。"
            await log.write("image_preview_failed")
            return
        }
        image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        await log.write("image_preview_open", metrics: ["width": Double(cgImage.width), "height": Double(cgImage.height)])
    }

    func copyImage(to board: NSPasteboard = .general) async {
        guard !copying, !closed else { return }
        copying = true
        defer { copying = false }
        do {
            let (record, data) = try await store.payload(for: item.id)
            guard !Task.isCancelled, !closed else { return }
            let type: NSPasteboard.PasteboardType = record.filename.hasSuffix(".png") ? .png : .tiff
            board.clearContents()
            guard board.setData(data, forType: type) else {
                message = "复制失败，请重试。"
                await log.write("image_preview_copy_failed")
                return
            }
            message = "图片已复制，可切换到目标应用粘贴。"
            await log.write("image_preview_copied", metrics: ["bytes": Double(data.count)])
        } catch {
            message = "图片文件无法读取，请重新记录。"
            await log.write("image_preview_copy_failed")
        }
    }

    func releaseImage() {
        closed = true
        image = nil
    }
}

struct ImagePreviewView: View {
    @ObservedObject var model: ImagePreviewModel
    let close: () -> Void
    @State private var fitScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo").foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("图片预览").font(.system(size: 16, weight: .semibold))
                    Text("\(model.item.pixelWidth ?? 0) × \(model.item.pixelHeight ?? 0)")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { changeZoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("缩小").accessibilityLabel("缩小").disabled(model.image == nil)
                Text("\(Int(((model.zoom ?? fitScale) * 100).rounded()))%")
                    .monospacedDigit().font(.system(size: 12)).frame(width: 44)
                Button { changeZoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("放大").accessibilityLabel("放大").disabled(model.image == nil)
                Button("适合窗口") { model.zoom = nil }.disabled(model.image == nil)
                Button("100%") { model.zoom = 1 }.disabled(model.image == nil)
            }.padding(16)
            Divider()
            GeometryReader { geometry in
                if let image = model.image {
                    let scale = model.zoom ?? fittingScale(in: geometry.size, image: image)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                            .accessibilityLabel("放大的图片")
                    }
                    .onAppear { fitScale = fittingScale(in: geometry.size, image: image) }
                    .onChange(of: geometry.size) { _, size in fitScale = fittingScale(in: size, image: image) }
                } else if model.loading {
                    ProgressView("正在加载图片…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("无法预览", systemImage: "photo.badge.exclamationmark")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(Color.white)
            Divider()
            HStack(spacing: 12) {
                Text(model.message ?? "先查看图片，再决定是否复制")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
                Button { Task { await model.copyImage() } } label: {
                    Text(model.copying ? "正在复制…" : "复制图片")
                }.buttonStyle(PrimaryButton()).frame(width: 100).disabled(model.copying || model.image == nil)
                    .accessibilityIdentifier("copyPreviewImage")
            }.padding(16)
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(Palette.canvas).foregroundStyle(Palette.ink).preferredColorScheme(.light)
        .task { await model.load() }
        .onDisappear { model.releaseImage() }
    }

    private func fittingScale(in size: CGSize, image: NSImage) -> CGFloat {
        min(1, min(max(1, size.width - 24) / image.size.width, max(1, size.height - 24) / image.size.height))
    }

    private func changeZoom(by factor: CGFloat) {
        model.zoom = min(4, max(0.1, (model.zoom ?? fitScale) * factor))
    }
}
