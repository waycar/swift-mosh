/// How many terminal columns a printed scalar advances the cursor.
/// (Waycar patch: client screen model.)
///
/// mosh-server lays out its screen with the Host's `wcwidth`, and its
/// diffs skip the cells it believes did not change, so `MoshScreen` must
/// advance the cursor exactly as the Host does or every cell after a
/// disagreement lands one column off. This mirrors a glibc-style
/// `wcwidth` from the standard library's Unicode properties plus the
/// classic East Asian Wide/Fullwidth ranges, so no Unicode data files ship.
enum MoshCharacterWidth {
    /// 0 for combining and format scalars (they join the previous cell),
    /// 2 for wide and emoji-presentation scalars, 1 otherwise. Controls
    /// never reach here: the parser handles them.
    static func columns(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x300 {
            // Latin-1 and friends; U+00AD SOFT HYPHEN is Cf but prints.
            return 1
        }
        if value == 0x200B || (0x1160...0x11FF).contains(value) {
            return 0
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        if scalar.properties.isEmojiPresentation || isWide(value) {
            return 2
        }
        return 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x2E80...0x303E,
        0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
        0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
        0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
        0x1F900...0x1F9FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    private static func isWide(_ value: UInt32) -> Bool {
        wideRanges.contains { $0.contains(value) }
    }
}
