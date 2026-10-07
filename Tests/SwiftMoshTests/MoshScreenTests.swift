import Foundation
import XCTest
@testable import MoshCore

/// Waycar patch 16 (see PROVENANCE.md): the client screen model's parser,
/// with hand-written expectations, and its encoder, round-tripped.
final class MoshScreenTests: XCTestCase {
    // MARK: - Parser

    func testCursorPositionAndPrinting() {
        var screen = MoshScreen(cols: 10, rows: 4)
        screen.apply(bytes("\u{1B}[3;5Habc"))
        XCTAssertEqual(screen.rowTexts, ["", "", "    abc", ""])
        XCTAssertEqual(screen.cursor, .init(row: 2, col: 7))
        screen.apply(bytes("\u{1B}[H"))
        XCTAssertEqual(screen.cursor, .init(row: 0, col: 0))
        screen.apply(bytes("\u{1B}[99;99H"))
        XCTAssertEqual(screen.cursor, .init(row: 3, col: 9), "CUP clamps to the screen")
        screen.apply(bytes("\u{1B}[;3H"))
        XCTAssertEqual(screen.cursor, .init(row: 0, col: 2), "a missing row defaults to 1")
    }

    func testCarriageReturnLineFeedAndBackspace() {
        var screen = MoshScreen(cols: 10, rows: 3)
        screen.apply(bytes("ab\rX"))
        XCTAssertEqual(screen.text(ofRow: 0), "Xb")
        screen.apply(bytes("\u{1B}[1;3H\u{08}c"))
        XCTAssertEqual(screen.text(ofRow: 0), "Xc")
        screen.apply(bytes("\u{08}\u{08}\u{08}\u{08}"))
        XCTAssertEqual(screen.cursor.col, 0, "BS stops at column 0")
        screen.apply(bytes("\u{1B}[1;4H\nd"))
        XCTAssertEqual(screen.rowTexts, ["Xc", "   d", ""], "LF keeps the column")
    }

    func testLineFeedAtTheBottomScrollsTheScreen() {
        var screen = MoshScreen(cols: 4, rows: 3)
        screen.apply(bytes("1\r\n2\r\n3\u{1B}[0;44m\n"))
        XCTAssertEqual(screen.rowTexts, ["2", "3", ""])
        XCTAssertEqual(screen.cursor, .init(row: 2, col: 1), "LF keeps the column")
        XCTAssertEqual(
            screen.lines[2].cells, Array(repeating: .blank(.init(background: .indexed(4))), count: 4),
            "the scrolled-in line takes the current background")
    }

    func testLineFeedInsideAScrollRegionScrollsOnlyTheRegion() {
        var screen = MoshScreen(cols: 4, rows: 5)
        screen.apply(bytes("a\r\nb\r\nc\r\nd\r\ne"))
        screen.apply(bytes("\u{1B}[2;4r"))
        XCTAssertEqual(screen.cursor, .init(row: 0, col: 0), "DECSTBM homes the cursor")
        XCTAssertEqual(screen.scrollRegion, .init(top: 1, bottom: 3))
        screen.apply(bytes("\u{1B}[4;1H\n\n"))
        XCTAssertEqual(screen.rowTexts, ["a", "d", "", "", "e"], "rows outside the region stay")
        screen.apply(bytes("\u{1B}[5;1H\n"))
        XCTAssertEqual(screen.rowTexts, ["a", "d", "", "", "e"], "LF below the region does not scroll")
        screen.apply(bytes("\u{1B}[r"))
        XCTAssertTrue(screen.hasFullScrollRegion)
    }

    func testErasesFillWithTheCurrentBackgroundOnly() {
        var screen = MoshScreen(cols: 6, rows: 3)
        screen.apply(bytes("abcdef\r\nghijkl\r\nmnopqr"))
        screen.apply(bytes("\u{1B}[0;1;4;31;42m"))
        let erased = MoshScreen.Cell.blank(.init(background: .indexed(2)))

        screen.apply(bytes("\u{1B}[1;3H\u{1B}[K"))
        XCTAssertEqual(screen.text(ofRow: 0), "ab")
        XCTAssertEqual(screen.lines[0].cells[2], erased)
        screen.apply(bytes("\u{1B}[2;3H\u{1B}[1K"))
        XCTAssertEqual(screen.text(ofRow: 1), "   jkl")
        screen.apply(bytes("\u{1B}[3;2H\u{1B}[2X"))
        XCTAssertEqual(screen.text(ofRow: 2), "m  pqr")
        XCTAssertEqual(screen.cursor, .init(row: 2, col: 1), "ECH leaves the cursor")
        XCTAssertEqual(screen.lines[2].cells[1], erased)
        screen.apply(bytes("\u{1B}[2;1H\u{1B}[2K"))
        XCTAssertEqual(screen.text(ofRow: 1), "")

        screen.apply(bytes("\u{1B}[2;1H\u{1B}[J"))
        XCTAssertEqual(screen.rowTexts, ["ab", "", ""])
        screen.apply(bytes("\u{1B}[1;2H\u{1B}[1J"))
        XCTAssertEqual(screen.rowTexts, ["", "", ""])
        screen.apply(bytes("\u{1B}[0mxyz\u{1B}[0;45m\u{1B}[2J"))
        XCTAssertEqual(screen.rowTexts, ["", "", ""])
        XCTAssertEqual(screen.lines[2].cells[5], .blank(.init(background: .indexed(5))))
    }

    func testAutowrapMarksTheRowSoftWrapped() {
        var screen = MoshScreen(cols: 4, rows: 2)
        screen.apply(bytes("abcd"))
        XCTAssertEqual(screen.cursor, .init(row: 0, col: 3, pendingWrap: true))
        XCTAssertFalse(screen.lines[0].softWrapped, "the wrap waits for the next printable")
        screen.apply(bytes("ef"))
        XCTAssertEqual(screen.rowTexts, ["abcd", "ef"])
        XCTAssertTrue(screen.lines[0].softWrapped)
        XCTAssertEqual(screen.cursor, .init(row: 1, col: 2))

        screen.apply(bytes("gh"))
        screen.apply(bytes("ij"))
        XCTAssertEqual(screen.rowTexts, ["efgh", "ij"], "a wrap at the bottom scrolls")
        XCTAssertTrue(screen.lines[0].softWrapped)

        for clear in ["\r", "\u{1B}[2;4H", "\u{08}", "\n"] {
            var pending = MoshScreen(cols: 4, rows: 3)
            pending.apply(bytes("abcd" + clear))
            XCTAssertFalse(pending.cursor.pendingWrap, "\(clear.debugDescription) clears the pending wrap")
        }
    }

    func testWideCharactersAndHalfOverwrites() {
        var screen = MoshScreen(cols: 6, rows: 2)
        screen.apply(bytes("a中b"))
        XCTAssertEqual(screen.lines[0].cells[1].text, "中")
        XCTAssertEqual(screen.lines[0].cells[1].width, 2)
        XCTAssertEqual(screen.lines[0].cells[2].width, 0)
        XCTAssertEqual(screen.cursor.col, 4)
        XCTAssertEqual(screen.text(ofRow: 0), "a中b")

        screen.apply(bytes("\u{1B}[1;3Hx"))
        XCTAssertEqual(screen.text(ofRow: 0), "a xb", "overwriting the right half clears the left")
        screen.apply(bytes("\u{1B}[1;1H😀\u{1B}[1;1Hy"))
        XCTAssertEqual(screen.text(ofRow: 0), "y xb", "overwriting the left half clears the right")
        XCTAssertTrue(screen.lines[0].cells.allSatisfy { $0.width == 1 })

        var edge = MoshScreen(cols: 3, rows: 2)
        edge.apply(bytes("ab中"))
        XCTAssertEqual(edge.rowTexts, ["ab", "中"], "a wide character that does not fit wraps first")
        XCTAssertTrue(edge.lines[0].softWrapped)
        XCTAssertEqual(edge.cursor, .init(row: 1, col: 2))
    }

    func testCombiningScalarsJoinThePreviousCell() {
        var screen = MoshScreen(cols: 4, rows: 1)
        screen.apply(bytes("e\u{301}x\u{1B}[1;1H\u{301}"))
        XCTAssertEqual(screen.lines[0].cells[0].text.unicodeScalars.map(\.value), [0x65, 0x301])
        XCTAssertEqual(screen.lines[0].cells[1].text, "x")
        XCTAssertEqual(screen.cursor.col, 0, "a combining scalar does not advance")
        screen.apply(bytes("\u{1B}[1;4Hz\u{20DD}"))
        XCTAssertEqual(screen.lines[0].cells[3].text.unicodeScalars.map(\.value), [0x7A, 0x20DD],
                       "it joins the last column's cell while a wrap is pending")
        screen.apply(bytes("\u{1B}[1;2H中\u{301}"))
        XCTAssertEqual(screen.lines[0].cells[1].text.unicodeScalars.map(\.value), [0x4E2D, 0x301])
    }

    func testCharacterWidths() {
        XCTAssertEqual(MoshCharacterWidth.columns(of: "a"), 1)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "\u{AD}"), 1)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "\u{301}"), 0)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "\u{200B}"), 0)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "\u{200D}"), 0)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "\u{1160}"), 0)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "中"), 2)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "한"), 2)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "\u{FF01}"), 2)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "😀"), 2)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "⌚"), 2)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "─"), 1)
        XCTAssertEqual(MoshCharacterWidth.columns(of: "❯"), 1)
    }

    func testSelectGraphicRenditionForms() {
        var screen = MoshScreen(cols: 4, rows: 1)
        screen.apply(bytes("\u{1B}[0;1;3;4;5;7;8;38;5;200;48;2;1;2;3m"))
        XCTAssertEqual(screen.style, .init(
            attributes: [.bold, .italic, .underline, .blink, .inverse, .invisible],
            foreground: .indexed(200), background: .rgb(1, 2, 3)))
        screen.apply(bytes("\u{1B}[0;33;94m"))
        XCTAssertEqual(screen.style, .init(foreground: .indexed(12)))
        screen.apply(bytes("\u{1B}[0;38;2;9;8;7;101m"))
        XCTAssertEqual(screen.style, .init(foreground: .rgb(9, 8, 7), background: .indexed(9)))
        screen.apply(bytes("\u{1B}[1;2;9;46m\u{1B}[22;29;39;49m"))
        XCTAssertEqual(screen.style, .plain)
        screen.apply(bytes("\u{1B}[0;4;7mA\u{1B}[m"))
        XCTAssertEqual(screen.lines[0].cells[0].style, .init(attributes: [.underline, .inverse]))
        XCTAssertEqual(screen.style, .plain, "an empty SGR resets")
    }

    func testOperatingSystemCommandsWithBellAndStringTerminator() {
        var screen = MoshScreen(cols: 4, rows: 1)
        screen.apply(bytes("\u{1B}]0;both\u{07}"))
        XCTAssertEqual(screen.iconName, "both")
        XCTAssertEqual(screen.windowTitle, "both")
        screen.apply(bytes("\u{1B}]2;título\u{1B}\\\u{1B}]1;icon\u{07}"))
        XCTAssertEqual(screen.windowTitle, "título")
        XCTAssertEqual(screen.iconName, "icon")
        screen.apply(bytes("\u{1B}]52;c;aGVsbG8=\u{1B}\\"))
        XCTAssertEqual(screen.clipboard, "c;aGVsbG8=")
        screen.apply(bytes("\u{1B}]52;c;?\u{07}"))
        XCTAssertEqual(screen.clipboard, "c;aGVsbG8=", "a clipboard query copies nothing")
        XCTAssertEqual(screen.rowTexts, [""], "OSC strings print nothing")
        screen.apply(bytes("\u{07}\u{07}"))
        XCTAssertEqual(screen.bellCount, 2)
    }

    func testModes() {
        var screen = MoshScreen(cols: 4, rows: 1)
        screen.apply(bytes(
            "\u{1B}[?25l\u{1B}[?5h\u{1B}[?2004h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1004h\u{1B}[?1006h\u{1B}[?1h"))
        XCTAssertEqual(screen.modes, .init(
            cursorVisible: false, reverseVideo: true, bracketedPaste: true, mouseReporting: 1002,
            focusEvents: true, mouseEncoding: 1006, applicationCursorKeys: true))
        screen.apply(bytes("\u{1B}[?1000;1015l\u{1B}[?25;1h"))
        XCTAssertNil(screen.modes.mouseReporting, "resetting any reporting mode turns reporting off")
        XCTAssertNil(screen.modes.mouseEncoding)
        XCTAssertTrue(screen.modes.cursorVisible)
        screen.apply(bytes("\u{1B}[?1049h\u{1B}[4h\u{1B}[>4;1m\u{1B}P1$r\u{1B}\\"))
        XCTAssertEqual(screen.rowTexts, [""], "unknown sequences are ignored")
    }

    func testResizeKeepsTheTopLeft() {
        var screen = MoshScreen(cols: 5, rows: 3)
        screen.apply(bytes("abc中\r\ndefgh\r\nijk\u{1B}[2;4r\u{1B}[3;5H"))
        screen.resize(cols: 4, rows: 2)
        XCTAssertEqual(screen.rowTexts, ["abc", "defg"], "a wide character cut in half is cleared")
        XCTAssertEqual(screen.cursor, .init(row: 1, col: 3))
        XCTAssertTrue(screen.hasFullScrollRegion)
        screen.resize(cols: 6, rows: 3)
        XCTAssertEqual(screen.rowTexts, ["abc", "defg", ""])
    }

    func testMalformedInputNeverTraps() {
        var generator = SeededGenerator(seed: 7)
        var screen = MoshScreen(cols: 7, rows: 3)
        for _ in 0..<200 {
            let bytes = (0..<64).map { _ in UInt8.random(in: 0...255, using: &generator) }
            screen.apply(Data(bytes))
        }
        screen.apply(bytes("\u{1B}[99999999999999;-5H\u{1B}[38;5m\u{1B}[48;2;1m\u{1B}]"))
        screen.apply(Data([0xE4, 0xB8, 0x41, 0xF0, 0x9F, 0x98]))
        XCTAssertEqual(screen.lines.count, 3)
        XCTAssertTrue(screen.lines.allSatisfy { $0.cells.count == 7 })
    }

    // MARK: - Encoder

    func testEncodeTurnsAScreenIntoARelatedOne() {
        var generator = SeededGenerator(seed: 0x5EED)
        var scrolled = 0
        for trial in 0..<400 {
            let cols = Int.random(in: 1...24, using: &generator)
            let rows = Int.random(in: 1...10, using: &generator)
            var displayed = MoshScreen(cols: cols, rows: rows)
            displayed.apply(Self.randomVocabulary(cols: cols, rows: rows, steps: 40, using: &generator))
            var target = displayed
            target.apply(Self.randomVocabulary(cols: cols, rows: rows, steps: 25, using: &generator))

            let encoded = MoshScreenEncoder.encode(from: displayed, to: target)
            if String(decoding: encoded, as: UTF8.self).contains("H\n") { scrolled += 1 }
            var shown = displayed
            shown.apply(encoded)
            XCTAssertTrue(shown.rendersEqual(to: target), Self.describe(trial, shown, target))
        }
        XCTAssertGreaterThan(scrolled, 20, "the trials must exercise the scroll replay")
    }

    func testEncodeTurnsAScreenIntoAnUnrelatedOne() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for trial in 0..<300 {
            let cols = Int.random(in: 1...24, using: &generator)
            let rows = Int.random(in: 1...10, using: &generator)
            var displayed = MoshScreen(cols: cols, rows: rows)
            displayed.apply(Self.randomVocabulary(cols: cols, rows: rows, steps: 40, using: &generator))
            let resized = Bool.random(using: &generator)
            let targetCols = resized ? Int.random(in: 1...24, using: &generator) : cols
            let targetRows = resized ? Int.random(in: 1...10, using: &generator) : rows
            var target = MoshScreen(cols: targetCols, rows: targetRows)
            target.apply(Self.randomVocabulary(cols: targetCols, rows: targetRows, steps: 40, using: &generator))

            var shown = displayed
            shown.resize(cols: targetCols, rows: targetRows)
            shown.apply(MoshScreenEncoder.encode(from: displayed, to: target))
            // A clipboard is never cleared, so one only the old screen set stays.
            XCTAssertTrue(
                shown.rendersEqual(to: target, includingClipboard: target.clipboard != nil),
                Self.describe(trial, shown, target))
        }
    }

    func testFullRepaintPaintsOverAnUnrelatedScreen() {
        var generator = SeededGenerator(seed: 0xFACADE)
        for trial in 0..<300 {
            let cols = Int.random(in: 1...24, using: &generator)
            let rows = Int.random(in: 1...10, using: &generator)
            var unrelated = MoshScreen(cols: cols, rows: rows)
            unrelated.apply(Self.randomVocabulary(cols: cols, rows: rows, steps: 40, using: &generator))
            var target = MoshScreen(cols: cols, rows: rows)
            target.apply(Self.randomVocabulary(cols: cols, rows: rows, steps: 40, using: &generator))

            let repaint = MoshScreenEncoder.fullRepaint(of: target)
            unrelated.apply(repaint)
            XCTAssertTrue(
                unrelated.rendersEqual(to: target, includingClipboard: false), Self.describe(trial, unrelated, target))
            XCTAssertFalse(String(decoding: repaint, as: UTF8.self).contains("\u{1B}]52;"),
                           "a repaint never sets the clipboard again")
            XCTAssertFalse(String(decoding: repaint, as: UTF8.self).contains("\u{1B}[2J"),
                           "a repaint does not clear (Ghostty would push the screen into scrollback)")
        }
    }

    func testEncodeReplaysAScrollWithLineFeeds() {
        var displayed = MoshScreen(cols: 8, rows: 4)
        displayed.apply(bytes("line1\r\nline2\r\nline3\r\nline4"))
        var target = displayed
        target.apply(bytes("\r\nline5\r\nline6"))

        let encoded = String(decoding: MoshScreenEncoder.encode(from: displayed, to: target), as: UTF8.self)
        XCTAssertTrue(encoded.hasPrefix("\u{1B}[r\u{1B}[4;1H\n\n"), encoded.debugDescription)
        XCTAssertFalse(encoded.contains("line3"), "rows the scroll moved into place are not rewritten")
        var shown = displayed
        shown.apply(Data(encoded.utf8))
        XCTAssertEqual(shown.rowTexts, ["line3", "line4", "line5", "line6"])
    }

    func testEncodeScrollsARegionAboveAFixedFooter() {
        var displayed = MoshScreen(cols: 8, rows: 5)
        displayed.apply(bytes("a1\r\na2\r\na3\r\n\r\n> input"))
        var target = displayed
        target.apply(bytes("\u{1B}[1;3r\u{1B}[3;1H\na4\u{1B}[r\u{1B}[5;8H"))

        let encoded = String(decoding: MoshScreenEncoder.encode(from: displayed, to: target), as: UTF8.self)
        XCTAssertTrue(encoded.hasPrefix("\u{1B}[1;3r\u{1B}[3;1H\n\u{1B}[r"), encoded.debugDescription)
        XCTAssertFalse(encoded.contains("input"), "the footer below the region is left alone")
        var shown = displayed
        shown.apply(Data(encoded.utf8))
        XCTAssertTrue(shown.rendersEqual(to: target))
    }

    func testEncodeContinuesSoftWrappedRowsWithoutCursorMoves() {
        let displayed = MoshScreen(cols: 4, rows: 3)
        var target = displayed
        target.apply(bytes("abcdefg"))

        var shown = displayed
        shown.apply(MoshScreenEncoder.encode(from: displayed, to: target))
        XCTAssertTrue(shown.rendersEqual(to: target))
        XCTAssertTrue(shown.lines[0].softWrapped, "the terminal soft-wraps the row too")
    }

    // MARK: - Helpers

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    private static func describe(_ trial: Int, _ shown: MoshScreen, _ target: MoshScreen) -> String {
        "trial \(trial): got \(shown.rowTexts) cursor \(shown.cursor) style \(shown.style) modes \(shown.modes), "
            + "want \(target.rowTexts) cursor \(target.cursor) style \(target.style) modes \(target.modes)"
    }

    /// A random run of the vocabulary mosh-server's diffs use.
    static func randomVocabulary(
        cols: Int, rows: Int, steps: Int, using generator: inout SeededGenerator
    ) -> Data {
        let glyphs = ["a", "b", "Z", "0", " ", "~", "─", "❯", "中", "한", "😀", "e\u{301}", "\u{200B}", "é"]
        var out = ""
        func number(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &generator) }
        for _ in 0..<steps {
            switch number(0...16) {
            case 0...4:
                for _ in 0..<number(1...12) {
                    out += glyphs[number(0...(glyphs.count - 1))]
                }
            case 5:
                out += "\u{1B}[\(number(0...(rows + 1)));\(number(0...(cols + 1)))H"
            case 6:
                out += ["\r", "\n", "\u{08}", "\u{07}", "\r\n"][number(0...4)]
            case 7:
                out += randomSGR(using: &generator)
            case 8:
                out += "\u{1B}[\(number(0...2))K"
            case 9:
                out += "\u{1B}[\(number(1...5))X"
            case 10:
                out += "\u{1B}[\(number(0...2))J"
            case 11:
                let top = number(1...rows)
                let bottom = number(top...rows)
                out += "\u{1B}[\(top);\(bottom)r\u{1B}[\(bottom);1H" + String(repeating: "\n", count: number(1...3))
                if Bool.random(using: &generator) { out += "\u{1B}[r" }
            case 12:
                let mode = [1, 5, 25, 1000, 1002, 1003, 1004, 1006, 1015, 2004][number(0...9)]
                out += "\u{1B}[?\(mode)\(Bool.random(using: &generator) ? "h" : "l")"
            case 13:
                let terminator = Bool.random(using: &generator) ? "\u{07}" : "\u{1B}\\"
                out += "\u{1B}]\([0, 1, 2, 52][number(0...3)]);"
                    + (out.count % 2 == 0 ? "c;dGl0bGU=" : "t\(number(0...9))") + terminator
            case 14:
                out += "\u{1B}[\(rows);\(number(1...cols))H" + String(repeating: "\n", count: number(1...3))
            default:
                out += "\r\n"
            }
        }
        return Data(out.utf8)
    }

    private static func randomSGR(using generator: inout SeededGenerator) -> String {
        var params = ["0"]
        for _ in 0..<Int.random(in: 0...3, using: &generator) {
            switch Int.random(in: 0...6, using: &generator) {
            case 0: params.append(["1", "2", "3", "4", "5", "7", "8", "9"].randomElement(using: &generator) ?? "1")
            case 1: params.append("\(Int.random(in: 30...37, using: &generator))")
            case 2: params.append("\(Int.random(in: 40...47, using: &generator))")
            case 3: params.append("\(Int.random(in: 90...97, using: &generator))")
            case 4: params.append("38;5;\(Int.random(in: 0...255, using: &generator))")
            case 5: params.append("48;2;\(Int.random(in: 0...255, using: &generator));7;9")
            default: params.append(["22", "24", "27", "39", "49"].randomElement(using: &generator) ?? "22")
            }
        }
        return "\u{1B}[" + params.joined(separator: ";") + "m"
    }
}

/// SplitMix64: a deterministic generator for reproducible random tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
