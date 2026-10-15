pub const LEFT_SHIFT: u64 = 0xE1;
pub const LEFT_CTRL: u64 = 0xE0;
pub const LEFT_ALT: u64 = 0xE2;
pub const LEFT_GUI: u64 = 0xE3;

/// The US-layout HID keyboard usage for [c], and whether it needs Shift.
pub fn usage_for(c: char) -> Option<(u64, bool)> {
    const SHIFTED_DIGITS: &str = ")!@#$%^&*(";
    Some(match c {
        'a'..='z' => (0x04 + (c as u64 - 'a' as u64), false),
        'A'..='Z' => (0x04 + (c as u64 - 'A' as u64), true),
        '1'..='9' => (0x1E + (c as u64 - '1' as u64), false),
        '0' => (0x27, false),
        '\n' => (0x28, false),
        '\t' => (0x2B, false),
        ' ' => (0x2C, false),
        '-' => (0x2D, false),
        '_' => (0x2D, true),
        '=' => (0x2E, false),
        '+' => (0x2E, true),
        '[' => (0x2F, false),
        '{' => (0x2F, true),
        ']' => (0x30, false),
        '}' => (0x30, true),
        '\\' => (0x31, false),
        '|' => (0x31, true),
        ';' => (0x33, false),
        ':' => (0x33, true),
        '\'' => (0x34, false),
        '"' => (0x34, true),
        '`' => (0x35, false),
        '~' => (0x35, true),
        ',' => (0x36, false),
        '<' => (0x36, true),
        '.' => (0x37, false),
        '>' => (0x37, true),
        '/' => (0x38, false),
        '?' => (0x38, true),
        _ => {
            let i = SHIFTED_DIGITS.find(c)? as u64;
            (if i == 0 { 0x27 } else { 0x1E + i - 1 }, true)
        }
    })
}

/// The HID usage of a named key, matching glint's `KeyName`.
pub fn named(name: &str) -> Option<u64> {
    Some(match name {
        "enter" => 0x28,
        "escape" => 0x29,
        "backspace" => 0x2A,
        "tab" => 0x2B,
        "space" => 0x2C,
        "delete" => 0x4C,
        "right" => 0x4F,
        "left" => 0x50,
        "down" => 0x51,
        "up" => 0x52,
        "a" => 0x04,
        _ => return None,
    })
}

/// The HID usage of a modifier, matching glint's `KeyModifier`.
pub fn modifier(name: &str) -> Option<u64> {
    Some(match name {
        "cmd" => LEFT_GUI,
        "shift" => LEFT_SHIFT,
        "ctrl" => LEFT_CTRL,
        "alt" => LEFT_ALT,
        _ => return None,
    })
}

/// Consumer-page buttons as (usage page, usage, hold ms).
pub fn button(name: &str) -> Option<(u64, u64, u64)> {
    Some(match name {
        "home" => (0x0C, 0x40, 80),
        "lock" | "power" => (0x0C, 0x30, 200),
        "volumeUp" => (0x0C, 0xE9, 80),
        "volumeDown" => (0x0C, 0xEA, 80),
        "mute" => (0x0C, 0xE2, 80),
        "siri" => (0x0C, 0xCF, 1200),
        _ => return None,
    })
}
