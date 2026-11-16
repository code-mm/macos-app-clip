import AppKit
import SwiftUI
import Carbon
import ClipCore

@MainActor
final class HotkeyService {
    private var registration: EventHotKeyRef?
    private var recordRegistration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var detector = DoublePressDetector()
    private var recordDetector = DoublePressDetector()
    private var shortcut = Shortcut.defaultValue
    private var singleHeld = false
    private var generation: UInt32 = 0
    private let recordID = UInt32.max
    var onToggle: (() -> Void)?
    var onRecord: (() -> Void)?

    init() {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x434C4950 else { return OSStatus(eventNotHandledErr) }
            let object = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
            let kind = GetEventKind(event)
            let time = GetEventTime(event)
            MainActor.assumeIsolated { object.receive(kind: kind, time: time, id: identifier.id) }
            return noErr
        }, events.count, &events, context, &handler)
    }

    func register(_ value: Shortcut) -> OSStatus {
        // F2 无修饰键始终保留给静默记录，不能同时用作面板开关。
        guard value.keyCode != Shortcut.recordCurrent.keyCode || value.modifiers != 0 else {
            return OSStatus(paramErr)
        }
        if registration != nil, value.keyCode == shortcut.keyCode, value.modifiers == shortcut.modifiers {
            shortcut = value
            detector.reset()
            singleHeld = false
            return noErr
        }
        let nextID = generation &+ 1
        var next: EventHotKeyRef?
        let status = RegisterEventHotKey(value.keyCode, value.modifiers,
                                         EventHotKeyID(signature: 0x434C4950, id: nextID),
                                         GetApplicationEventTarget(), 0, &next)
        guard status == noErr else { return status }
        if let registration { UnregisterEventHotKey(registration) }
        registration = next
        generation = nextID
        shortcut = value
        detector.reset()
        singleHeld = false
        return noErr
    }

    func registerRecordShortcut() -> OSStatus {
        recordDetector.reset()
        if recordRegistration != nil { return noErr }
        return RegisterEventHotKey(Shortcut.recordCurrent.keyCode, 0,
                                   EventHotKeyID(signature: 0x434C4950, id: recordID),
                                   GetApplicationEventTarget(), 0, &recordRegistration)
    }

    func suspend() {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        if let recordRegistration { UnregisterEventHotKey(recordRegistration) }
        recordRegistration = nil
        detector.reset()
        recordDetector.reset()
        singleHeld = false
    }

    private func receive(kind: UInt32, time: TimeInterval, id: UInt32) {
        if id == recordID {
            guard recordRegistration != nil else { return }
            if kind == UInt32(kEventHotKeyReleased) { recordDetector.keyUp() }
            else if kind == UInt32(kEventHotKeyPressed), recordDetector.keyDown(at: time) { onRecord?() }
            return
        }
        guard id == generation else { return }
        if kind == UInt32(kEventHotKeyReleased) {
            detector.keyUp()
            singleHeld = false
            return
        }
        if shortcut.mode == .double {
            if detector.keyDown(at: time) { onToggle?() }
        } else if !singleHeld {
            singleHeld = true
            onToggle?()
        }
    }

    func stop() {
        suspend()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let onRecord: (Shortcut) -> Void
    let onCancel: () -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: RecorderView, context: Context) {}

    final class RecorderView: NSView {
        var onRecord: ((Shortcut) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return }
            guard !event.isARepeat else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let functionLabels: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                                    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let isFunction = functionLabels[event.keyCode] != nil
            guard isFunction || modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { NSSound.beep(); return }
            let label = functionLabels[event.keyCode] ?? (event.keyCode == 49 ? "Space" : event.charactersIgnoringModifiers?.uppercased() ?? "")
            guard !label.isEmpty else { return }
            onRecord?(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label, mode: .single))
        }
    }
}
