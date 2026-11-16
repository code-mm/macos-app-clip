import Foundation

public struct Shortcut: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case single, double }
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var keyLabel: String
    public var mode: Mode
    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String, mode: Mode) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel; self.mode = mode
    }
    public static let defaultValue = Shortcut(keyCode: 122, modifiers: 0, keyLabel: "F1", mode: .double)
    public static let recordCurrent = Shortcut(keyCode: 120, modifiers: 0, keyLabel: "F2", mode: .double)
    public var label: String {
        var result = ""
        if modifiers & 4096 != 0 { result += "⌃" }
        if modifiers & 2048 != 0 { result += "⌥" }
        if modifiers & 512 != 0 { result += "⇧" }
        if modifiers & 256 != 0 { result += "⌘" }
        result += keyLabel
        return mode == .double ? "双击 \(result)" : result
    }
}

/// Uses key-up to reject held-key autorepeat; one double press produces one toggle.
public struct DoublePressDetector {
    public let interval: TimeInterval
    private var firstPress: TimeInterval?
    private var held = false
    public init(interval: TimeInterval = 0.35) { self.interval = interval }
    public mutating func keyDown(at time: TimeInterval) -> Bool {
        guard !held else { return false }
        held = true
        if let firstPress, time >= firstPress, time - firstPress <= interval {
            self.firstPress = nil
            return true
        }
        firstPress = time
        return false
    }
    public mutating func keyUp() { held = false }
    public mutating func reset() { held = false; firstPress = nil }
}

public enum PanelLayout {
    public static func listHeight(count: Int, availableHeight: Double, notice: Bool) -> Double {
        let desired = count == 0 ? 94.0 : Double(count) * 82.0
        let chrome = notice ? 438.0 : 362.0
        return min(desired, max(70, min(480, availableHeight - chrome - 36)))
    }
}
