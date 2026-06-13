// HidKeymap.swift — USB HID Usage Page 7 (Keyboard) codes for printable
// ASCII + a handful of control characters. Non-Latin / IME input is out
// of v1 scope. Reference: USB HID Usage Tables 1.5 §10 (Keyboard 0x07).

import Foundation

struct HidMapping {
    let usage: Int32
    let shift: Bool
}

enum HidKeymap {
    /// Left-shift modifier. Held before / released after a shifted character.
    static let shiftUsage: Int32 = 0xE1

    static func map(_ s: Unicode.Scalar) -> HidMapping? {
        // a..z -> 0x04..0x1D
        if s.value >= 0x61, s.value <= 0x7A {
            return HidMapping(usage: Int32(0x04 + (s.value - 0x61)), shift: false)
        }
        // A..Z -> shifted a..z
        if s.value >= 0x41, s.value <= 0x5A {
            return HidMapping(usage: Int32(0x04 + (s.value - 0x41)), shift: true)
        }
        // 1..9 -> 0x1E..0x26, 0 -> 0x27
        if s.value >= 0x31, s.value <= 0x39 {
            return HidMapping(usage: Int32(0x1E + (s.value - 0x31)), shift: false)
        }
        if s.value == 0x30 {
            return HidMapping(usage: 0x27, shift: false)
        }
        switch s.value {
        case 0x20: return HidMapping(usage: 0x2C, shift: false)  // space
        case 0x0A: return HidMapping(usage: 0x28, shift: false)  // \n -> Enter
        case 0x09: return HidMapping(usage: 0x2B, shift: false)  // \t -> Tab
        case 0x08: return HidMapping(usage: 0x2A, shift: false)  // \b -> Backspace
        // Unshifted symbols.
        case 0x2D: return HidMapping(usage: 0x2D, shift: false)  // -
        case 0x3D: return HidMapping(usage: 0x2E, shift: false)  // =
        case 0x5B: return HidMapping(usage: 0x2F, shift: false)  // [
        case 0x5D: return HidMapping(usage: 0x30, shift: false)  // ]
        case 0x5C: return HidMapping(usage: 0x31, shift: false)  // \
        case 0x3B: return HidMapping(usage: 0x33, shift: false)  // ;
        case 0x27: return HidMapping(usage: 0x34, shift: false)  // '
        case 0x60: return HidMapping(usage: 0x35, shift: false)  // `
        case 0x2C: return HidMapping(usage: 0x36, shift: false)  // ,
        case 0x2E: return HidMapping(usage: 0x37, shift: false)  // .
        case 0x2F: return HidMapping(usage: 0x38, shift: false)  // /
        // Shifted symbols.
        case 0x21: return HidMapping(usage: 0x1E, shift: true)   // !
        case 0x40: return HidMapping(usage: 0x1F, shift: true)   // @
        case 0x23: return HidMapping(usage: 0x20, shift: true)   // #
        case 0x24: return HidMapping(usage: 0x21, shift: true)   // $
        case 0x25: return HidMapping(usage: 0x22, shift: true)   // %
        case 0x5E: return HidMapping(usage: 0x23, shift: true)   // ^
        case 0x26: return HidMapping(usage: 0x24, shift: true)   // &
        case 0x2A: return HidMapping(usage: 0x25, shift: true)   // *
        case 0x28: return HidMapping(usage: 0x26, shift: true)   // (
        case 0x29: return HidMapping(usage: 0x27, shift: true)   // )
        case 0x5F: return HidMapping(usage: 0x2D, shift: true)   // _
        case 0x2B: return HidMapping(usage: 0x2E, shift: true)   // +
        case 0x7B: return HidMapping(usage: 0x2F, shift: true)   // {
        case 0x7D: return HidMapping(usage: 0x30, shift: true)   // }
        case 0x7C: return HidMapping(usage: 0x31, shift: true)   // |
        case 0x3A: return HidMapping(usage: 0x33, shift: true)   // :
        case 0x22: return HidMapping(usage: 0x34, shift: true)   // "
        case 0x7E: return HidMapping(usage: 0x35, shift: true)   // ~
        case 0x3C: return HidMapping(usage: 0x36, shift: true)   // <
        case 0x3E: return HidMapping(usage: 0x37, shift: true)   // >
        case 0x3F: return HidMapping(usage: 0x38, shift: true)   // ?
        default: return nil
        }
    }
}
