import AppKit
import Carbon.HIToolbox
import SnugBarCore

/// Global hotkeys through Carbon's `RegisterEventHotKey`. Needs no permission and no third-party package.
@MainActor
public final class HotkeyCenter {
    public struct Failure: Sendable, CustomStringConvertible {
        public var action: HotkeyAction
        public var hotkey: Hotkey
        public var status: Int32
        public var description: String { "\(hotkey) for \(action.rawValue) could not be registered (\(status))" }
    }

    /// Called on the main actor when a registered hotkey is pressed.
    public var onPress: ((HotkeyAction) -> Void)?
    /// Shortcuts the system refused, usually because another app holds them.
    public private(set) var failures: [Failure] = []

    private var refs: [UInt32: (ref: EventHotKeyRef, action: HotkeyAction)] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x534E_4742 // "SNGB"

    public init() {}

    /// Replaces every registration with `settings`.
    public func apply(_ settings: HotkeySettings) {
        unregisterAll()
        installHandlerIfNeeded()
        failures = []
        for action in HotkeyAction.allCases {
            guard let hotkey = settings[action], hotkey.isValidGlobalHotkey else { continue }
            // A shortcut bound twice fires the first action only.
            if refs.values.contains(where: { settings[$0.action] == hotkey }) { continue }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(hotkey.keyCode), Self.carbonModifiers(hotkey.modifiers),
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs[id] = (ref, action)
            } else {
                failures.append(Failure(action: action, hotkey: hotkey, status: status))
            }
        }
    }

    public func unregisterAll() {
        for entry in refs.values { UnregisterEventHotKey(entry.ref) }
        refs = [:]
    }

    static func carbonModifiers(_ m: Hotkey.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if m.contains(.command) { result |= UInt32(cmdKey) }
        if m.contains(.option) { result |= UInt32(optionKey) }
        if m.contains(.control) { result |= UInt32(controlKey) }
        if m.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            let hotkeyID = id.id
            // Carbon delivers on the main thread.
            MainActor.assumeIsolated {
                if let action = center.refs[hotkeyID]?.action { center.onPress?(action) }
            }
            return noErr
        }, 1, &spec, context, &handler)
    }
}

/// Converts AppKit modifier flags to SnugBar's model (used by the shortcut recorder).
public extension Hotkey.Modifiers {
    init(eventFlags flags: NSEvent.ModifierFlags) {
        var m: Hotkey.Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        self = m
    }
}
