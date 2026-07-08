//
//  KeyboardInputSource.swift
//  RimeoAgent (macOS)
//
//  Forces the active keyboard layout to a plain-ASCII English source so that
//  credentials (the sign-in password) can't be typed in a non-Latin layout —
//  the classic "typed my password in Russian and login failed" trap. Called when
//  the password field gains focus (see LinkDeviceView).
//

import Carbon

enum KeyboardInputSource {
    /// Switch the active keyboard layout to English (ABC / U.S., or any ASCII-capable
    /// Latin layout). No-op if the current source is already ASCII-capable or none is
    /// available.
    static func forceEnglish() {
        // Already on a plain-ASCII layout → nothing to do (don't fight the user).
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           isASCIICapableKeyboard(current) {
            return
        }

        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            logger.info("forceEnglish: no input-source list")
            return
        }

        // Prefer ABC, then U.S., then the first ASCII-capable keyboard layout.
        for target in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            if let src = list.first(where: { sourceID($0) == target }) {
                let r = TISSelectInputSource(src)
                logger.info("forceEnglish: selected \(target) status=\(r)")
                return
            }
        }
        if let src = list.first(where: { isASCIICapableKeyboard($0) }) {
            let r = TISSelectInputSource(src)
            logger.info("forceEnglish: selected fallback \(sourceID(src) ?? "?") status=\(r)")
        } else {
            logger.info("forceEnglish: no ASCII-capable keyboard source enabled")
        }
    }

    private static func sourceID(_ src: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func isASCIICapableKeyboard(_ src: TISInputSource) -> Bool {
        // Must be a keyboard layout (not an input method) and ASCII-capable.
        guard let catPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory) else { return false }
        let cat = Unmanaged<CFString>.fromOpaque(catPtr).takeUnretainedValue() as String
        guard cat == (kTISCategoryKeyboardInputSource as String) else { return false }
        guard let asciiPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(asciiPtr).takeUnretainedValue())
    }
}
