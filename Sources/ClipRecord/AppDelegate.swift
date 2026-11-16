import AppKit
import SwiftUI
import Carbon
import ClipCore

final class ClipboardPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var recordFeedback: StatusItemFeedback?
    private var panel: ClipboardPanel?
    private var hosting: NSHostingView<ClipboardPanelView>?
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var previewModel: ImagePreviewModel?
    private var textPreviewModel: TextPreviewModel?
    private var localMonitor: Any?
    private var telemetry: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var model: AppModel!
    private let hotkeys = HotkeyService()
    private var previousApp: NSRunningApplication?
    private var pendingPaste: Task<Void, Never>?
    private var lastResource = ResourceSample.capture()
    private var lastSampleTime = ProcessInfo.processInfo.systemUptime
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var openedAt = 0.0
    private var isClosing = false
    private var measuredHeight: CGFloat = 420

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let arguments = ProcessInfo.processInfo.arguments
        let testIndex = arguments.firstIndex(of: "--data-directory")
        let override = testIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let base = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.codemm.cliprecord", isDirectory: true)
        let logs = override.map { URL(fileURLWithPath: $0).appendingPathComponent("logs", isDirectory: true) }
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/com.codemm.cliprecord", isDirectory: true)
        let preferences = override == nil ? UserDefaults.standard : UserDefaults(suiteName: "com.codemm.cliprecord.qa")!
        model = AppModel(dataDirectory: base, logDirectory: logs, defaults: preferences)
        model.onPaste = { [weak self] id in self?.paste(id) }
        model.onPreview = { [weak self] item in self?.showRecordPreview(item) }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onHide = { [weak self] in self?.hidePanel() }
        model.onShortcutChange = { [weak self] value in self?.registerShortcut(value) ?? false }
        model.onChooseImage = { [weak self] in self?.chooseImage() }
        model.onSilentRecordResult = { [weak self] success in self?.recordFeedback?.show(success: success) }
        hotkeys.onToggle = { [weak self] in
            guard let self else { return }
            Task { await self.model.log.write("hotkey_toggle") }
            // 双击 F1 只开关面板；粘贴必须由点击记录或回车显式触发。
            self.togglePanel()
        }
        hotkeys.onRecord = { [weak self] in
            guard let self else { return }
            Task { await self.model.log.write("record_hotkey") }
            // 只保存，不开关窗口、不激活应用、不触发粘贴。
            self.model.saveCurrent(silently: true)
        }
        _ = registerShortcut(model.shortcut)
        configureMenuBar()
        configureApplicationMenu()
        configureTelemetry()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        Task {
            await model.start()
            if arguments.contains("--settings") { showSettings() }
            else if arguments.contains("--show") { showPanel() }
        }
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "剪贴板")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "剪贴板 · \(model.shortcut.label) 显示/隐藏 · 双击 F2 静默记录"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            recordFeedback = StatusItemFeedback(button: button, log: model.log)
        }
        statusItem = item
    }

    private func configureApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "剪贴板设置…", action: #selector(settingsFromMenu), keyEquivalent: ",").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出剪贴板", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开剪贴板", action: #selector(openFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "设置…", action: #selector(settingsFromMenu), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出剪贴板", action: #selector(quitFromMenu), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else { togglePanel() }
    }

    @objc private func openFromMenu() { showPanel() }
    @objc private func settingsFromMenu() { showSettings() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    private func registerShortcut(_ value: Shortcut) -> Bool {
        let result = hotkeys.register(value)
        if result == noErr {
            model.hotkeyError = nil
            statusItem?.button?.toolTip = "剪贴板 · \(value.label) 显示/隐藏 · 双击 F2 静默记录"
            registerRecordShortcut()
            return true
        }
        if value.keyCode == Shortcut.recordCurrent.keyCode, value.modifiers == 0 {
            model.hotkeyError = "F2 已用于双击静默记录，请选择其他面板快捷键。"
        } else {
            model.hotkeyError = "快捷键注册失败（\(result)），请改用其他组合键；菜单栏仍可打开。"
        }
        if model.recordingShortcut {
            _ = hotkeys.register(model.shortcut)
            model.recordingShortcut = false
        }
        registerRecordShortcut()
        Task { await model.log.write("hotkey_registration_failed", metrics: ["status": Double(result)]) }
        return false
    }

    private func registerRecordShortcut() {
        let result = hotkeys.registerRecordShortcut()
        model.recordHotkeyError = result == noErr ? nil : "双击 F2 注册失败（\(result)），请检查是否被其他软件占用。"
        if result != noErr {
            Task { await model.log.write("record_hotkey_registration_failed", metrics: ["status": Double(result)]) }
        }
    }

    private func togglePanel() {
        pendingPaste?.cancel()
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard model != nil else { return }
        pendingPaste?.cancel()
        if panel?.isVisible == true { return }
        closeSettings()
        let foreground = NSWorkspace.shared.frontmostApplication
        if foreground?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = foreground }
        openedAt = ProcessInfo.processInfo.systemUptime
        model.selection = model.filtered.first?.id
        let screen = statusScreen()
        model.availableHeight = screen.visibleFrame.height
        measuredHeight = model.panelHeight
        let root = ClipboardPanelView(model: model) { [weak self] height in
            guard let self, height > 200, height.isFinite, abs(height - self.measuredHeight) > 0.5 else { return }
            self.measuredHeight = height
            DispatchQueue.main.async { [weak self] in self?.positionPanel() }
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        let window = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 472, height: measuredHeight),
                                     styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "剪贴板"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.delegate = self
        window.contentView = host
        panel = window
        hosting = host
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installPanelMonitors()
        Task { await model.log.write("panel_open", metrics: ["records": Double(model.records.count),
                                                             "height": Double(window.frame.height), "width": Double(window.frame.width)]) }
    }

    private func statusScreen() -> NSScreen {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = statusScreen()
        let visible = screen.visibleFrame
        let height = min(max(320, measuredHeight), visible.height - 12)
        let buttonFrame = statusItem?.button?.window?.frame
        let right = buttonFrame?.maxX ?? visible.maxX
        let x = min(max(visible.minX + 8, right - 472), visible.maxX - 472 - 8)
        let y = visible.maxY - height - 6
        panel.setFrame(NSRect(x: x, y: max(visible.minY, y), width: 472, height: height), display: true)
        Task { await model.log.write("panel_resize", metrics: ["height": Double(height), "rows": Double(model.filtered.count)]) }
    }

    private func installPanelMonitors() {
        removePanelMonitors()
        // Explicit toggle/Esc keeps the panel usable while the user copies from another app.
        // No global mouse monitor is retained by a long-running menu-bar process.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            if event.keyCode == 9, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
                if let editor = self.panel?.firstResponder as? NSTextView, editor.isEditable { return event }
                self.model.saveCurrent()
                return nil
            }
            switch event.keyCode {
            case 53: self.hidePanel(); return nil
            case 125: self.model.moveSelection(1); return nil
            case 126: self.model.moveSelection(-1); return nil
            case 36, 76: self.model.pasteSelection(); return nil
            default: return event
            }
        }
    }

    private func removePanelMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    private func chooseImage() {
        guard let panel, model.ready, !model.busy else { return }
        let picker = NSOpenPanel()
        picker.title = "选择要记录的图片"
        picker.prompt = "记录图片"
        picker.allowedContentTypes = ClipboardImport.imageTypes
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.beginSheetModal(for: panel) { [weak self] result in
            guard result == .OK, let url = picker.url else { return }
            self?.model.saveInput(.imageFile(url))
        }
    }

    private func hidePanel() {
        closeRecordPreview()
        guard let window = panel, !isClosing else { return }
        isClosing = true
        let duration = ProcessInfo.processInfo.systemUptime - openedAt
        removePanelMonitors()
        window.delegate = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        hosting = nil
        panel = nil
        model.clearTransientState()
        isClosing = false
        Task { await model.log.write("panel_close", metrics: ["visible_seconds": duration]) }
    }

    private func showRecordPreview(_ item: ClipRecord) {
        pendingPaste?.cancel()
        closeRecordPreview()
        let screen = panel?.screen ?? statusScreen()
        let size = NSSize(width: min(1000, screen.visibleFrame.width - 60),
                          height: min(820, screen.visibleFrame.height - 60))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = item.kind == .image ? "图片预览" : "文字预览"
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        if item.kind == .image {
            let state = ImagePreviewModel(item: item, store: model.store, log: model.log)
            let view = ImagePreviewView(model: state) { [weak self] in self?.closeRecordPreview() }
            previewModel = state
            window.contentView = NSHostingView(rootView: view)
        } else {
            let state = TextPreviewModel(item: item, store: model.store, log: model.log)
            let view = TextPreviewView(model: state) { [weak self] in self?.closeRecordPreview() }
            textPreviewModel = state
            window.contentView = NSHostingView(rootView: view)
        }
        window.center()
        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeRecordPreview() {
        guard let window = previewWindow else { return }
        previewWindow = nil
        previewModel?.releaseImage()
        textPreviewModel?.releaseText()
        let event = textPreviewModel == nil ? "image_preview_close" : "text_preview_close"
        previewModel = nil
        textPreviewModel = nil
        window.delegate = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        panel?.makeKeyAndOrderFront(nil)
        Task { await model.log.write(event) }
    }

    private func paste(_ id: UUID) {
        guard !model.busy else { return }
        pendingPaste?.cancel()
        let target = previousApp
        pendingPaste = Task { [weak self] in
            guard let self else { return }
            do {
                let (record, data) = try await model.store.payload(for: id)
                try Task.checkCancellation()
                let board = NSPasteboard.general
                let type: NSPasteboard.PasteboardType = record.kind == .text ? .string : (record.filename.hasSuffix(".png") ? .png : .tiff)
                board.clearContents()
                guard board.setData(data, forType: type) else {
                    model.notice = "无法写入系统剪贴板，请重试。"
                    return
                }
                guard let target, !target.isTerminated else {
                    model.notice = "已复制，请回到目标应用按 ⌘V 粘贴。"
                    await model.log.write("paste_copied_no_target")
                    return
                }
                guard AXIsProcessTrusted() else {
                    model.notice = "已复制。请按 ⌘V 粘贴；在设置中允许辅助功能后可直接粘贴。"
                    await model.log.write("paste_copied_permission_needed")
                    return
                }
                hidePanel()
                guard target.activate(options: []) else { return }
                // Wait for real foreground activation; never type Command-V into an unrelated app.
                for _ in 0..<15 {
                    try await Task.sleep(for: .milliseconds(20))
                    try Task.checkCancellation()
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                        let source = CGEventSource(stateID: .combinedSessionState)
                        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
                        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
                        down?.flags = .maskCommand
                        up?.flags = .maskCommand
                        down?.post(tap: .cghidEventTap)
                        up?.post(tap: .cghidEventTap)
                        await model.log.write("paste_sent", metrics: ["kind": record.kind == .image ? 1 : 0])
                        return
                    }
                }
                await model.log.write("paste_focus_timeout")
            } catch is CancellationError {
                // A new user action superseded this paste.
            } catch {
                model.notice = "读取记录失败，请检查数据文件。"
                await model.log.write("paste_failed")
            }
        }
    }

    private func showSettings() {
        pendingPaste?.cancel()
        hidePanel()
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(model: model, close: { [weak self] in self?.closeSettings() },
                                beginRecording: { [weak self] in self?.beginRecording() },
                                cancelRecording: { [weak self] in self?.cancelRecording() })
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "剪贴板设置"
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func beginRecording() {
        hotkeys.suspend()
        model.recordingShortcut = true
    }

    private func cancelRecording() {
        model.recordingShortcut = false
        _ = registerShortcut(model.shortcut)
    }

    private func closeSettings() {
        if model.recordingShortcut { cancelRecording() }
        let window = settingsWindow
        settingsWindow = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === previewWindow { closeRecordPreview() }
        if notification.object as? NSWindow === settingsWindow { closeSettings() }
    }

    private func configureTelemetry() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 300, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.sampleResources() }
        telemetry = timer
        timer.resume()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.model.thumbnails.clear()
            Task { await self.model.log.write("memory_pressure_cache_released") }
        }
        pressureSource = pressure
        pressure.resume()
    }

    private func sampleResources() {
        let sample = ResourceSample.capture()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.001, now - lastSampleTime)
        let cpu = max(0, (sample.cpuSeconds - lastResource.cpuSeconds) / elapsed * 100)
        lastResource = sample
        lastSampleTime = now
        Task {
            let snapshot = await model.store.snapshot()
            await model.log.write("resource_sample", metrics: [
                "resident_mb": Double(sample.residentBytes) / 1_048_576,
                "cpu_percent": cpu, "records": Double(snapshot.count),
                "storage_mb": Double(snapshot.bytes) / 1_048_576,
                "uptime_seconds": now - startedAt, "panel_visible": panel?.isVisible == true ? 1 : 0
            ])
        }
    }

    @objc private func willSleep() { recordFeedback?.stop(); pendingPaste?.cancel(); hidePanel() }
    @objc private func didWake() { _ = registerShortcut(model.shortcut) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        recordFeedback?.stop()
        previewModel?.releaseImage()
        textPreviewModel?.releaseText()
        pendingPaste?.cancel()
        hotkeys.stop()
        removePanelMonitors()
        telemetry?.cancel()
        pressureSource?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil else { return .terminateNow }
        Task {
            await model.log.write("terminate", metrics: ["uptime_seconds": ProcessInfo.processInfo.systemUptime - startedAt])
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
