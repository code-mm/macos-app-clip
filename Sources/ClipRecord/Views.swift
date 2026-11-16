import AppKit
import SwiftUI
import ClipCore

enum Palette {
    static let canvas = Color(red: 245/255, green: 246/255, blue: 248/255)
    static let ink = Color(red: 33/255, green: 42/255, blue: 54/255)
    static let graphite = Color(red: 51/255, green: 62/255, blue: 73/255)
    static let muted = Color(red: 98/255, green: 111/255, blue: 127/255)
    static let yellow = Color(red: 1, green: 206/255, blue: 84/255)
    static let pale = Color(red: 1, green: 247/255, blue: 223/255)
    static let line = Color(red: 227/255, green: 231/255, blue: 236/255)
}

struct HeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct BrandIcon: View {
    var size: CGFloat = 30
    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "BrandMark", withExtension: "png"),
              let cgImage = ImageSupport.thumbnail(at: url, maxPixels: 96) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }()
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: "clipboard").font(.system(size: size * 0.8)).foregroundStyle(Palette.graphite)
                .frame(width: size, height: size)
        }
    }
}

struct Keycap: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 40)
            .background(Palette.graphite.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var model: AppModel
    let onHeight: (CGFloat) -> Void
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                BrandIcon()
                Text("剪贴板").font(.system(size: 21, weight: .bold))
                Spacer()
                Keycap(title: model.shortcut.label)
                Button { model.onSettings?() } label: {
                    Image(systemName: "gearshape").font(.system(size: 19))
                }.buttonStyle(.plain).help("设置").accessibilityLabel("设置")
            }.frame(height: 36)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索记录", text: $model.search).textFieldStyle(.plain).font(.system(size: 14))
                    .accessibilityIdentifier("searchRecords")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("清空搜索")
                }
            }.padding(.horizontal, 11).frame(height: 34).background(.white, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))

            PasteCaptureView(model: model).frame(height: 164)

            if let notice = model.notice {
                HStack(spacing: 6) {
                    Text(notice).font(.system(size: 12)).lineLimit(3)
                    Spacer(minLength: 2)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.padding(9).frame(height: 64).background(Palette.pale, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text("已保存").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(model.search.isEmpty ? "\(model.records.count) 条" : "\(model.filtered.count) / \(model.records.count) 条")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.frame(height: 18)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.filtered.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: model.search.isEmpty ? "clipboard" : "magnifyingglass").font(.system(size: 23))
                                Text(model.search.isEmpty ? "还没有记录，保存第一条吧" : "没有找到相关记录").font(.system(size: 13))
                            }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity).frame(height: 94)
                        } else {
                            ForEach(model.filtered) { item in
                                RecordRow(item: item, selected: model.selection == item.id, model: model)
                                    .id(item.id)
                            }
                        }
                    }
                }.frame(height: model.listHeight).background(.white, in: RoundedRectangle(cornerRadius: 11))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .onChange(of: model.selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
            }
            HStack(spacing: 8) {
                Text("↑↓ 选择"); Text(model.selectedRequiresPreview ? "↵ 预览" : "↵ 粘贴"); Text("esc 隐藏")
                Spacer()
                Text("手动记录")
            }.font(.system(size: 11)).foregroundStyle(Palette.muted).frame(height: 18)
        }
        .padding(16).frame(width: 472).fixedSize(horizontal: false, vertical: true).foregroundStyle(Palette.ink)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
        .onAppear { onHeight(model.panelHeight) }
        .onChange(of: model.panelHeight) { _, height in onHeight(height) }
        .onChange(of: model.search) { _, _ in model.selection = model.filtered.first?.id }
        .preferredColorScheme(.light)
    }
}

private struct RecordRow: View {
    let item: ClipRecord
    let selected: Bool
    @ObservedObject var model: AppModel
    @State private var thumbnail: NSImage?
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if item.kind == .text {
                    Text("Aa").font(.system(size: 18, weight: .semibold)).frame(width: 50, height: 48)
                        .background(Palette.pale, in: RoundedRectangle(cornerRadius: 9))
                } else if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 72, height: 48).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Image(systemName: "photo").frame(width: 72, height: 48).background(Palette.pale)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if item.kind == .text {
                    Text(item.preview).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Text(metadata).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected || hovered {
                Image(systemName: item.requiresPreview ? "arrow.up.left.and.arrow.down.right" : "return")
                    .foregroundStyle(Palette.muted).font(.system(size: 14))
            }
        }.padding(.horizontal, 12).frame(height: 81).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.pale : (hovered ? Palette.canvas : .white))
            .overlay(alignment: .leading) { if selected { Capsule().fill(Palette.yellow).frame(width: 3, height: 54) } }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5).padding(.horizontal, 12) }
            .contentShape(Rectangle())
            .onTapGesture { model.activateRecord(item) }
            .onHover { hovered = $0 }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(item.title)，\(metadata)，\(item.requiresPreview ? "点击放大预览" : "点击粘贴")")
            .accessibilityAction { model.activateRecord(item) }
            .contextMenu {
                if item.requiresPreview { Button("放大预览") { model.activateRecord(item) } }
                else { Button("粘贴") { model.onPaste?(item.id) } }
                Button("删除记录", role: .destructive) { model.delete(item) }
            }
            .task(id: item.id) {
                if item.kind == .image { thumbnail = await model.thumbnails.image(for: item, store: model.store) }
            }
            .onDisappear { thumbnail = nil }
    }
    private var metadata: String {
        let time = item.createdAt.formatted(.dateTime.month().day().hour().minute())
        if item.kind == .image {
            return "图片 · \(item.pixelWidth ?? 0) × \(item.pixelHeight ?? 0) · \(time)"
        }
        return "文字 · \(time)"
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    let beginRecording: () -> Void
    let cancelRecording: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                BrandIcon(size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("剪贴板设置").font(.system(size: 22, weight: .bold))
                    Text("按你的习惯，快速呼出与隐藏").font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 13) {
                Text("快捷键").font(.system(size: 16, weight: .semibold))
                HStack {
                    Text("显示 / 隐藏剪贴板").font(.system(size: 14))
                    Spacer()
                    Button(action: beginRecording) {
                        Text(model.recordingShortcut ? "请按组合键…" : model.shortcut.label)
                            .font(.system(size: 14, weight: .medium)).frame(width: 155, height: 34)
                            .background(Palette.pale, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(model.recordingShortcut)
                        .accessibilityLabel("修改显示隐藏快捷键")
                        .overlay {
                            if model.recordingShortcut {
                                ShortcutRecorder(onRecord: model.updateShortcut, onCancel: cancelRecording)
                            }
                        }
                }
                HStack {
                    Text("点击后录入组合键；Esc 取消").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("恢复双击 F1") { model.updateShortcut(.defaultValue) }.buttonStyle(.link)
                }
                Picker("触发方式", selection: Binding(get: { model.shortcut.mode }, set: { mode in
                    var next = model.shortcut; next.mode = mode; model.updateShortcut(next)
                })) {
                    Text("按一次").tag(Shortcut.Mode.single)
                    Text("双击").tag(Shortcut.Mode.double)
                }.pickerStyle(.segmented).disabled(model.recordingShortcut)
                Text("双击间隔为 0.35 秒。若 F1 / F2 被系统作为亮度键使用，请配合 Fn，或在系统键盘设置中启用标准功能键。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if let error = model.hotkeyError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack { Text("静默记录当前剪贴板"); Spacer(); Keycap(title: "双击 F2") }.font(.system(size: 14))
                Text("保存文字或图片，不显示面板，不切换当前应用。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                if let error = model.recordHotkeyError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack { Text("关闭面板"); Spacer(); Keycap(title: "esc") }.font(.system(size: 14))
            }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 6) {
                Text("手动记录，按需保存").font(.system(size: 14, weight: .semibold))
                Text("仅在你操作时读取剪贴板，支持文字与图片。\n历史最多 500 条 / 250 MB，超出后移除最早记录。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
                .background(Palette.pale, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text("运行诊断").font(.system(size: 14, weight: .semibold))
                Text("记录运行事件与资源指标，不记录剪贴板正文；日志最多约 4 MB。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                HStack {
                    Button("打开日志") { NSWorkspace.shared.open(model.logDirectory) }
                    Button("打开数据目录") { NSWorkspace.shared.open(model.dataDirectory) }
                    Spacer()
                    Button("允许快捷粘贴") {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }.help("辅助功能权限用于把内容粘贴到上一个应用")
                }.font(.system(size: 12))
            }
            HStack {
                Button("退出剪贴板") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                Spacer()
                Button("完成", action: close).buttonStyle(PrimaryButton()).frame(width: 92)
            }
        }.padding(24).frame(width: 580).foregroundStyle(Palette.ink).background(Palette.canvas)
            .preferredColorScheme(.light)
    }
}
