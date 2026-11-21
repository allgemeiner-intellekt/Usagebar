import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
func verifyGlobalHotkey() {
    // 1. Validation: require at least one primary modifier (Command, Control, or Option).
    let bareKey = GlobalHotkey(keyCode: UInt32(kVK_ANSI_U), modifiers: [])
    precondition(bareKey.validate() == .missingPrimaryModifier, "Bare key must be rejected")

    let shiftOnly = GlobalHotkey(keyCode: UInt32(kVK_ANSI_U), modifiers: [.shift])
    precondition(shiftOnly.validate() == .missingPrimaryModifier, "Shift-only shortcut must be rejected")

    let modifierOnly = GlobalHotkey(keyCode: UInt32(kVK_Command), modifiers: [.command])
    precondition(modifierOnly.validate() == .modifierOnlyKey, "Modifier-only key code must be rejected")

    // 2. Validation: reject reserved macOS shortcuts.
    let reservedSamples: [GlobalHotkey] = [
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_Tab), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_Space), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_Escape), modifiers: [.command, .option]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command, .control]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: [.command]),
    ]
    for sample in reservedSamples {
        guard case .reservedSystemShortcut = sample.validate() else {
            preconditionFailure("Reserved shortcut \(sample.displayString) must be rejected")
        }
    }

    // 3. Validation & formatting: accept valid combos and format in Apple HIG modifier order.
    let validCombo = GlobalHotkey(
        keyCode: UInt32(kVK_ANSI_U),
        modifiers: [.command, .shift, .option, .control]
    )
    precondition(validCombo.validate() == nil, "Valid multi-modifier combo was rejected")
    precondition(validCombo.displayString == "⌃⌥⇧⌘U", "Unexpected display string: \(validCombo.displayString)")

    let optionSpace = GlobalHotkey(keyCode: UInt32(kVK_Space), modifiers: [.option])
    precondition(optionSpace.validate() == nil, "Option+Space should be allowed")
    precondition(optionSpace.displayString == "⌥Space", "Unexpected Option+Space label: \(optionSpace.displayString)")

    let controlOptionU = GlobalHotkey(keyCode: UInt32(kVK_ANSI_U), modifiers: [.control, .option])
    precondition(controlOptionU.validate() == nil)
    precondition(controlOptionU.displayString == "⌃⌥U")
    precondition(controlOptionU.modifiers.carbonFlags == (UInt32(controlKey) | UInt32(optionKey)))

    // 4. Persistence round-trip in isolated UserDefaults.
    let defaults = UserDefaults.standard
    GlobalHotkey.save(nil, to: defaults)
    precondition(GlobalHotkey.load(from: defaults) == nil, "Cleared hotkey must load as nil")

    GlobalHotkey.save(controlOptionU, to: defaults)
    precondition(GlobalHotkey.load(from: defaults) == controlOptionU, "Saved hotkey failed to round-trip")

    // Corrupted or reserved persisted values must safely load as nil.
    defaults.set(Int(kVK_ANSI_Q), forKey: GlobalHotkey.keyCodeDefaultsKey)
    defaults.set(Int(GlobalHotkey.Modifiers.command.rawValue), forKey: GlobalHotkey.modifiersDefaultsKey)
    precondition(GlobalHotkey.load(from: defaults) == nil, "Reserved persisted shortcut must not load")

    GlobalHotkey.save(nil, to: defaults)

    // 5. Carbon GlobalHotkeyManager lifecycle (register, suspend, resume, unregister).
    let manager = GlobalHotkeyManager()
    defer { manager.unregister() }

    precondition(!manager.register(bareKey), "Manager must refuse invalid shortcuts")
    precondition(manager.registeredHotkey == nil)

    let testHotkey = GlobalHotkey(
        keyCode: UInt32(kVK_F19),
        modifiers: [.control, .option, .shift]
    )
    if manager.register(testHotkey) {
        precondition(manager.registeredHotkey == testHotkey)
        manager.setSuspended(true)
        precondition(manager.registeredHotkey == nil, "Suspending manager must temporarily unregister hotkey")
        manager.setSuspended(false)
        precondition(manager.registeredHotkey == testHotkey, "Resuming manager must re-register hotkey")
        manager.unregister()
        precondition(manager.registeredHotkey == nil)
    }

    print("PASS: global hotkey validation, formatting, persistence, and manager lifecycle")
}
