/// How many terminal columns a printed scalar advances the cursor.
/// (Waycar patch: client screen model.)
///
/// mosh-server lays out its screen with the Host's `wcwidth`, and its
/// diffs skip the cells it believes did not change, so `MoshScreen` must
/// advance the cursor exactly as the Host does or every cell after a
/// disagreement lands off by a column (2 extra columns for each 👁 in an
/// omp status row autowrapped the model and drifted every later row).
///
/// - Wide (2): `MoshCharacterWidthTable.wide`, generated from the Host
///   libc's `wcwidth` by `Scripts/generate-character-widths.swift`. It is
///   East Asian Width W/F as libc ships it; glibc derives the same set, so
///   Linux Hosts agree. Text-presentation symbols such as U+1F441 👁 and the
///   regional indicators are 1, as the Host says.
/// - Zero (0): general category Mn/Me/Cf (except U+00AD SOFT HYPHEN),
///   U+200B and the Hangul jungseong/jongseong U+1160–11FF, matching glibc
///   and Darwin (U+FE0E/FE0F and U+200D included).
/// - One known divergence: Darwin also zeroes Mc spacing marks; glibc gives
///   them 1, and so does this function.
enum MoshCharacterWidth {
    /// 0 for combining and format scalars (they join the previous cell),
    /// 2 for wide scalars, 1 otherwise. Controls never reach here: the
    /// parser handles them.
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
        return isWide(value) ? 2 : 1
    }

    /// Binary search over the sorted, disjoint generated ranges.
    static func isWide(_ value: UInt32) -> Bool {
        let ranges = MoshCharacterWidthTable.wide
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < ranges.count && ranges[low].contains(value)
    }
}
