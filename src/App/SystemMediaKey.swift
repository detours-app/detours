import AppKit

enum SystemMediaKey {
    static let dictationKeyCode = 160
    static let f5KeyCode = 96
    static let keyDownFlag = 0xA
    static let systemDefinedSubtype: Int16 = 8

    static func keyCodeIfKeyDown(from event: NSEvent) -> Int? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == systemDefinedSubtype,
              let (keyCode, keyState) = keyCodeAndState(from: event) else {
            return nil
        }

        guard keyState == keyDownFlag else { return nil }
        return keyCode
    }

    static func keyCode(from event: NSEvent) -> Int? {
        guard event.type == .systemDefined else { return nil }
        return keyCodeAndState(from: event)?.keyCode
    }

    static func isCopyKeyCode(_ keyCode: Int) -> Bool {
        keyCode == dictationKeyCode || keyCode == f5KeyCode
    }

    private static func keyCodeAndState(from event: NSEvent) -> (keyCode: Int, keyState: Int)? {
        guard event.type == .systemDefined else { return nil }
        let data1 = UInt32(truncatingIfNeeded: event.data1)
        let keyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyState = Int((data1 & 0x0000FF00) >> 8)
        return (keyCode, keyState)
    }
}
