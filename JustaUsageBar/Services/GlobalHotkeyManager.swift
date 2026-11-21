//
//  GlobalHotkeyManager.swift
//  JustaUsageBar
//

import Carbon.HIToolbox
import Foundation

nonisolated private let globalHotkeySignature: OSType = 0x5542_4152 // "UBAR"
nonisolated private let globalHotkeyIDValue: UInt32 = 1

nonisolated private func globalHotkeyCarbonCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr,
          hotKeyID.signature == globalHotkeySignature,
          hotKeyID.id == globalHotkeyIDValue else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    // Dispatch onto the next main-loop turn so Carbon finishes handling the
    // keypress before UsagePanel installs its local keyDown monitor.
    Task { @MainActor in
        manager.handleHotKeyPressed()
    }
    return noErr
}

/// Registers a single system-wide hotkey via Carbon's `RegisterEventHotKey`,
/// which works on macOS 14+ without Accessibility or Input Monitoring prompts.
@MainActor
final class GlobalHotkeyManager {
    var onTrigger: () -> Void = {}

    private(set) var registeredHotkey: GlobalHotkey?
    private var desiredHotkey: GlobalHotkey?
    private var isSuspended = false

    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func register(_ hotkey: GlobalHotkey?) -> Bool {
        unregisterCarbonHotKey()
        isSuspended = false

        guard let hotkey else {
            desiredHotkey = nil
            return true
        }

        guard hotkey.validate() == nil else {
            return false
        }

        guard installEventHandlerIfNeeded() else {
            return false
        }

        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: globalHotkeySignature, id: globalHotkeyIDValue)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers.carbonFlags,
            id,
            GetApplicationEventTarget(),
            0,
            &newRef
        )

        guard status == noErr, let newRef else {
            return false
        }

        hotKeyRef = newRef
        registeredHotkey = hotkey
        desiredHotkey = hotkey
        return true
    }

    func unregister() {
        unregisterCarbonHotKey()
        desiredHotkey = nil
        isSuspended = false
    }

    /// Temporarily unregisters the active hotkey while the Settings shortcut
    /// recorder is capturing a new key combination, then restores it when done.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            unregisterCarbonHotKey()
        } else if let desiredHotkey {
            _ = register(desiredHotkey)
        }
    }

    fileprivate func handleHotKeyPressed() {
        guard !isSuspended, registeredHotkey != nil else { return }
        onTrigger()
    }

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil {
            return true
        }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotkeyCarbonCallback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        guard status == noErr, let ref else {
            return false
        }
        eventHandlerRef = ref
        return true
    }

    private func unregisterCarbonHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredHotkey = nil
    }
}
