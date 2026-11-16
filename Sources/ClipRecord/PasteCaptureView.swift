import AppKit
import SwiftUI

/// Native drag destination wrapping the SwiftUI capture card; no clipboard polling.
struct PasteCaptureView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> CaptureContainer {
        CaptureContainer(model: model)
    }

    func updateNSView(_ view: CaptureContainer, context: Context) {}

    final class CaptureContainer: NSView {
        private let model: AppModel
        private var host: NSHostingView<CaptureCard>!

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
            host = NSHostingView(rootView: CaptureCard(model: model, focus: { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }))
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            registerForDraggedTypes(ClipboardImport.pasteboardTypes)
            setAccessibilityLabel("粘贴记录区")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        @objc func paste(_ sender: Any?) { model.saveCurrent() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard model.ready, !model.busy,
                  sender.draggingPasteboard.availableType(from: ClipboardImport.pasteboardTypes) != nil else { return [] }
            model.dropTargeted = true
            return .copy
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            model.ready && !model.busy ? .copy : []
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { model.dropTargeted = false }
        override func draggingEnded(_ sender: NSDraggingInfo) { model.dropTargeted = false }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { model.ready && !model.busy }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            model.dropTargeted = false
            return model.saveCurrent(from: sender.draggingPasteboard) != nil
        }
    }
}

private struct CaptureCard: View {
    @ObservedObject var model: AppModel
    let focus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: "clipboard").font(.system(size: 24, weight: .medium))
                    .frame(width: 46, height: 46).background(Palette.pale, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.dropTargeted ? "松开即可记录" : "在这里粘贴文字、图片")
                        .font(.system(size: 16, weight: .semibold))
                    Text("拖入内容或按 ⌘V，直接保存到记录")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                Label("文字", systemImage: "text.alignleft")
                Label("图片", systemImage: "photo")
                Spacer()
                Text("双击 F2 静默记录")
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                Button { model.onChooseImage?() } label: {
                    Label("选择图片", systemImage: "photo.badge.plus")
                        .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 36)
                        .background(.white, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
                }.buttonStyle(.plain).disabled(!model.ready || model.busy).accessibilityIdentifier("chooseImage")
                Button { model.saveCurrent() } label: {
                    Label(model.busy ? "正在记录…" : "粘贴记录  ⌘V", systemImage: "clipboard.fill")
                        .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 36)
                        .foregroundStyle(.white).background(Palette.graphite, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(!model.ready || model.busy).accessibilityIdentifier("saveClipboard")
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.dropTargeted ? Palette.pale : Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.dropTargeted ? Palette.yellow : Palette.line,
                                                               style: StrokeStyle(lineWidth: model.dropTargeted ? 2 : 1.3, dash: [5, 4])))
        .foregroundStyle(Palette.ink).preferredColorScheme(.light)
        .contentShape(Rectangle()).onTapGesture(perform: focus)
    }
}
