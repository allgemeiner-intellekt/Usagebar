//
//  GlobalHotkey.swift
//  JustaUsageBar
//

import AppKit
import Carbon.HIToolbox
import Foundation

nonisolated struct GlobalHotkey: Equatable, Hashable, Codable, Sendable {
    nonisolated struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: UInt32

        static let command = Modifiers(rawValue: 1 << 0)
        static let option  = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift   = Modifiers(rawValue: 1 << 3)

        static let primaryModifiers: Modifiers = [.command, .option, .control]

        init(rawValue: UInt32) {
            self.rawValue = rawValue & 0b1111
        }

        init(nsEventFlags: NSEvent.ModifierFlags) {
            var result: Modifiers = []
            if nsEventFlags.contains(.command) { result.insert(.command) }
            if nsEventFlags.contains(.option) { result.insert(.option) }
            if nsEventFlags.contains(.control) { result.insert(.control) }
            if nsEventFlags.contains(.shift) { result.insert(.shift) }
            self = result
        }

        var hasPrimaryModifier: Bool {
            !intersection(.primaryModifiers).isEmpty
        }

        var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= UInt32(cmdKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.control) { flags |= UInt32(controlKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            return flags
        }

        /// Standard macOS display order: Control, Option, Shift, Command.
        var displayString: String {
            var symbols = ""
            if contains(.control) { symbols.append("⌃") }
            if contains(.option) { symbols.append("⌥") }
            if contains(.shift) { symbols.append("⇧") }
            if contains(.command) { symbols.append("⌘") }
            return symbols
        }
    }

    nonisolated enum ValidationError: Equatable, LocalizedError, Sendable {
        case missingPrimaryModifier
        case modifierOnlyKey
        case reservedSystemShortcut(String)

        var errorDescription: String? {
            switch self {
            case .missingPrimaryModifier:
                return "Include at least one modifier key (⌘, ⌃, or ⌥)."
            case .modifierOnlyKey:
                return "Press a non-modifier key together with your modifiers."
            case .reservedSystemShortcut(let label):
                return "\(label) is reserved by macOS. Choose another shortcut."
            }
        }
    }

    static let escapeKeyCode: UInt32 = UInt32(kVK_Escape)
    static let deleteKeyCode: UInt32 = UInt32(kVK_Delete)
    static let forwardDeleteKeyCode: UInt32 = UInt32(kVK_ForwardDelete)

    static let keyCodeDefaultsKey = "globalHotkeyKeyCode"
    static let modifiersDefaultsKey = "globalHotkeyModifiers"

    let keyCode: UInt32
    let modifiers: Modifiers

    var displayString: String {
        modifiers.displayString + Self.keyLabel(for: keyCode)
    }

    func validate() -> ValidationError? {
        if Self.modifierKeyCodes.contains(keyCode) {
            return .modifierOnlyKey
        }
        guard modifiers.hasPrimaryModifier else {
            return .missingPrimaryModifier
        }
        if Self.reservedShortcuts.contains(self) {
            return .reservedSystemShortcut(displayString)
        }
        return nil
    }

    static func load(from defaults: UserDefaults = .standard) -> GlobalHotkey? {
        guard let rawKeyCode = defaults.object(forKey: keyCodeDefaultsKey) as? NSNumber,
              let rawModifiers = defaults.object(forKey: modifiersDefaultsKey) as? NSNumber else {
            return nil
        }
        let keyCodeInt = rawKeyCode.intValue
        let modifiersInt = rawModifiers.intValue
        guard keyCodeInt >= 0, keyCodeInt <= Int(UInt16.max), modifiersInt >= 0 else {
            return nil
        }
        let candidate = GlobalHotkey(
            keyCode: UInt32(keyCodeInt),
            modifiers: Modifiers(rawValue: UInt32(modifiersInt))
        )
        guard candidate.validate() == nil else {
            return nil
        }
        return candidate
    }

    static func save(_ hotkey: GlobalHotkey?, to defaults: UserDefaults = .standard) {
        if let hotkey {
            defaults.set(Int(hotkey.keyCode), forKey: keyCodeDefaultsKey)
            defaults.set(Int(hotkey.modifiers.rawValue), forKey: modifiersDefaultsKey)
        } else {
            defaults.removeObject(forKey: keyCodeDefaultsKey)
            defaults.removeObject(forKey: modifiersDefaultsKey)
        }
    }

    private static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command),
        UInt32(kVK_RightCommand),
        UInt32(kVK_Shift),
        UInt32(kVK_RightShift),
        UInt32(kVK_CapsLock),
        UInt32(kVK_Option),
        UInt32(kVK_RightOption),
        UInt32(kVK_Control),
        UInt32(kVK_RightControl),
        UInt32(kVK_Function),
    ]

    private static let reservedShortcuts: Set<GlobalHotkey> = [
        // Application & window lifecycle
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_W), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_H), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_H), modifiers: [.command, .option]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command]),
        // App & window switching
        GlobalHotkey(keyCode: UInt32(kVK_Tab), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_Tab), modifiers: [.command, .shift]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: [.command, .shift]),
        // Spotlight, input switching, Force Quit, Lock Screen, Screenshots
        GlobalHotkey(keyCode: UInt32(kVK_Space), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_Space), modifiers: [.command, .option]),
        GlobalHotkey(keyCode: UInt32(kVK_Space), modifiers: [.control]),
        GlobalHotkey(keyCode: UInt32(kVK_Space), modifiers: [.control, .option]),
        GlobalHotkey(keyCode: UInt32(kVK_Escape), modifiers: [.command, .option]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command, .control]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: [.command, .shift]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: [.command, .shift]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: [.command, .shift]),
        // Standard editing & document shortcuts
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_X), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Z), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_Z), modifiers: [.command, .shift]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_N), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_O), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: [.command]),
        GlobalHotkey(keyCode: UInt32(kVK_ANSI_F), modifiers: [.command]),
    ]

    static func keyLabel(for keyCode: UInt32) -> String {
        if let known = keyLabels[keyCode] {
            return known
        }
        return "Key \(keyCode)"
    }

    private static let keyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20",
        UInt32(kVK_ANSI_Keypad0): "Num 0",
        UInt32(kVK_ANSI_Keypad1): "Num 1",
        UInt32(kVK_ANSI_Keypad2): "Num 2",
        UInt32(kVK_ANSI_Keypad3): "Num 3",
        UInt32(kVK_ANSI_Keypad4): "Num 4",
        UInt32(kVK_ANSI_Keypad5): "Num 5",
        UInt32(kVK_ANSI_Keypad6): "Num 6",
        UInt32(kVK_ANSI_Keypad7): "Num 7",
        UInt32(kVK_ANSI_Keypad8): "Num 8",
        UInt32(kVK_ANSI_Keypad9): "Num 9",
        UInt32(kVK_ANSI_KeypadDecimal): "Num .",
        UInt32(kVK_ANSI_KeypadMultiply): "Num *",
        UInt32(kVK_ANSI_KeypadPlus): "Num +",
        UInt32(kVK_ANSI_KeypadClear): "Num Clear",
        UInt32(kVK_ANSI_KeypadDivide): "Num /",
        UInt32(kVK_ANSI_KeypadEnter): "Num ↩",
        UInt32(kVK_ANSI_KeypadMinus): "Num -",
        UInt32(kVK_ANSI_KeypadEquals): "Num =",
    ]
}
