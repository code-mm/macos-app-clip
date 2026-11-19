import AppKit
import ClipCore

/// F2 保存结果的短暂反馈。结束或取消后恢复图标，不留下常驻定时器。
@MainActor
final class StatusItemFeedback {
    private weak var button: NSButton?
    private let normalImage: NSImage?
    private let normalTint: NSColor?
    private let normalAlpha: CGFloat
    private let log: RuntimeLog?
    private let soundPlayer: ((Bool) -> Bool)?
    private lazy var successSound = Self.loadSuccessSound()
    private lazy var failureSound = NSSound(named: "Basso")
    private var flashTask: Task<Void, Never>?

    init(button: NSButton, log: RuntimeLog? = nil, soundPlayer: ((Bool) -> Bool)? = nil) {
        self.button = button
        normalImage = button.image
        normalTint = button.contentTintColor
        normalAlpha = button.alphaValue
        self.log = log
        self.soundPlayer = soundPlayer
    }

    static func loadSuccessSound() -> NSSound? {
        guard let url = Bundle.module.url(forResource: "record-success", withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: false)
    }

    @discardableResult
    func show(success: Bool) -> Task<Void, Never> {
        flashTask?.cancel()
        successSound?.stop()
        failureSound?.stop()
        let soundStarted: Bool
        if let soundPlayer {
            soundStarted = soundPlayer(success)
        } else {
            let sound = success ? successSound : failureSound
            sound?.volume = success ? 1.0 : 0.45
            soundStarted = sound?.play() ?? false
        }
        if let log {
            Task { await log.write("record_feedback", metrics: ["success": success ? 1 : 0,
                                                                "sound_started": soundStarted ? 1 : 0]) }
        }
        let color = success ? NSColor(srgbRed: 0.16, green: 0.78, blue: 0.40, alpha: 1) : NSColor.systemOrange
        let image = NSImage(systemSymbolName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            accessibilityDescription: success ? "剪贴板已记录" : "剪贴板记录未完成")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        // 菜单栏模板图会被系统重着色；彩色反馈必须保留原色。
        image?.isTemplate = false
        button?.image = image
        button?.contentTintColor = color
        button?.alphaValue = normalAlpha
        let task = Task { [weak self] in
            // 两次明暗切换后恢复；即便快速重复触发也只有一个闪烁任务。
            for alpha: CGFloat in [0.2, 1, 0.2, 1] {
                do { try await Task.sleep(for: .milliseconds(220)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.button?.alphaValue = alpha
            }
            do { try await Task.sleep(for: .milliseconds(220)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.restoreIcon()
            self?.flashTask = nil
        }
        flashTask = task
        return task
    }

    func stop() {
        flashTask?.cancel()
        flashTask = nil
        successSound?.stop()
        failureSound?.stop()
        restoreIcon()
    }

    private func restoreIcon() {
        button?.image = normalImage
        button?.contentTintColor = normalTint
        button?.alphaValue = normalAlpha
    }
}
