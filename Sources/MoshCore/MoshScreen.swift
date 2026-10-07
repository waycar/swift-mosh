import Foundation

/// The client's copy of one mosh screen state. (Waycar patch: client screen
/// model.)
///
/// mosh-server sends every state as terminal bytes that turn the screen of
/// an older state (the diff's base) into the new one, skipping cells the two
/// share and scrolling with LF. When acks trail the server's patience the
/// base is the client's last *acknowledged* state, older than the screen it
/// already shows, so those bytes are only right when applied to a copy of
/// that base. `MoshClientSession` keeps one `MoshScreen` per recent state
/// and repaints Ghostty from them (`MoshScreenEncoder`).
///
/// Written clean-room from ECMA-48 / xterm semantics for the vocabulary
/// mosh-server's diffs use (see PROVENANCE.md); anything else is ignored.
/// A value type: copying is cheap, rows are copy-on-write, and mutating one
/// row copies only that row.
struct MoshScreen: Sendable {
    enum Color: Hashable, Sendable {
        case `default`
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    struct Attributes: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let bold = Attributes(rawValue: 1 << 0)
        static let faint = Attributes(rawValue: 1 << 1)
        static let italic = Attributes(rawValue: 1 << 2)
        static let underline = Attributes(rawValue: 1 << 3)
        static let blink = Attributes(rawValue: 1 << 4)
        static let inverse = Attributes(rawValue: 1 << 5)
        static let invisible = Attributes(rawValue: 1 << 6)
        static let strikethrough = Attributes(rawValue: 1 << 7)
    }

    struct Style: Hashable, Sendable {
        var attributes: Attributes = []
        var foreground: Color = .default
        var background: Color = .default

        static let plain = Style()
    }

    struct Cell: Hashable, Sendable {
        /// The base character plus any combining scalars; empty for a blank
        /// (a printed space is stored blank too).
        var text: String
        /// 1, 2 for a wide character, 0 for the right half of one.
        var width: UInt8
        var style: Style

        static let blank = Cell(text: "", width: 1, style: .plain)

        static func blank(_ style: Style) -> Cell {
            Cell(text: "", width: 1, style: style)
        }
    }

    struct Row: Hashable, Sendable {
        var cells: [Cell]
        /// The row's text continued onto the next row by autowrap.
        var softWrapped = false

        init(cols: Int, fill: Cell = .blank) {
            cells = Array(repeating: fill, count: cols)
        }
    }

    struct Cursor: Hashable, Sendable {
        var row = 0
        var col = 0
        /// A character was printed in the last column: the next printable
        /// wraps first. `col` stays on the last column meanwhile.
        var pendingWrap = false
    }

    /// Inclusive, zero-based rows.
    struct ScrollRegion: Hashable, Sendable {
        var top: Int
        var bottom: Int
    }

    struct Modes: Hashable, Sendable {
        var cursorVisible = true
        var reverseVideo = false
        var bracketedPaste = false
        /// The mouse-reporting mode set last (1000–1003); resetting any of
        /// them turns reporting off, as in Ghostty.
        var mouseReporting: Int?
        var focusEvents = false
        /// The mouse encoding set last (1005, 1006, 1015); resetting any of
        /// them returns to the default encoding.
        var mouseEncoding: Int?
        var applicationCursorKeys = false
    }

    /// Bounds a hostile or garbled resize to an allocation the device holds.
    static let maxColumns = 512
    static let maxRows = 256
    /// Bounds the combining scalars one cell collects.
    static let maxScalarsPerCell = 16
    /// Bounds an OSC string (titles, clipboard) the parser collects.
    static let maxOSCBytes = 256 * 1024

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var lines: [Row]
    private(set) var cursor = Cursor()
    /// The current rendition: printed cells take it, erases take its
    /// background.
    private(set) var style = Style.plain
    private(set) var scrollRegion: ScrollRegion
    private(set) var modes = Modes()
    private(set) var iconName = ""
    private(set) var windowTitle = ""
    /// The last OSC 52 payload (`selection;base64`), nil until one arrives.
    private(set) var clipboard: String?
    private(set) var bellCount = 0

    init(cols: Int, rows: Int) {
        let cols = min(max(cols, 1), Self.maxColumns)
        let rows = min(max(rows, 1), Self.maxRows)
        self.cols = cols
        self.rows = rows
        lines = Array(repeating: Row(cols: cols), count: rows)
        scrollRegion = ScrollRegion(top: 0, bottom: rows - 1)
    }

    var hasFullScrollRegion: Bool {
        scrollRegion == ScrollRegion(top: 0, bottom: rows - 1)
    }

    /// Whether the two screens show the same thing: cells, the cursor, the
    /// current rendition, the scroll region, modes, titles and (unless
    /// excluded) the clipboard. Soft-wrap flags and bells are not compared.
    func rendersEqual(to other: MoshScreen, includingClipboard: Bool = true) -> Bool {
        cols == other.cols && rows == other.rows
            && cursor == other.cursor && style == other.style
            && scrollRegion == other.scrollRegion && modes == other.modes
            && iconName == other.iconName && windowTitle == other.windowTitle
            && (!includingClipboard || clipboard == other.clipboard)
            && lines.indices.allSatisfy { lines[$0].cells == other.lines[$0].cells }
    }

    /// Row `row`'s text, blanks as spaces, trailing spaces trimmed.
    func text(ofRow row: Int) -> String {
        var text = ""
        for cell in lines[row].cells where cell.width != 0 {
            text += cell.text.isEmpty ? " " : cell.text
        }
        while text.last == " " { text.removeLast() }
        return text
    }

    /// Every row's text (see `text(ofRow:)`).
    var rowTexts: [String] {
        (0..<rows).map(text(ofRow:))
    }

    // MARK: - Host messages

    /// Applies one state's host ops in order: resizes and diff bytes.
    mutating func apply(_ ops: [MoshHostOp]) {
        for op in ops {
            switch op {
            case .hostBytes(let bytes):
                apply(bytes)
            case .resize(let cols, let rows):
                resize(cols: Int(cols), rows: Int(rows))
            case .echoAck:
                break
            }
        }
    }

    /// Runs `bytes` through the terminal parser. Never traps: malformed or
    /// unknown input is dropped. A sequence cut off at the end is dropped.
    mutating func apply(_ bytes: Data) {
        var parser = Parser()
        for byte in bytes {
            parser.feed(byte, into: &self)
        }
    }

    /// Resizes the grid the way mosh-server's resized states were observed
    /// to assume: keeps the top-left content, pads or truncates, clamps the
    /// cursor and resets the scroll region.
    mutating func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = min(max(newCols, 1), Self.maxColumns)
        let newRows = min(max(newRows, 1), Self.maxRows)
        guard newCols != cols || newRows != rows else { return }
        if newCols != cols {
            for index in lines.indices {
                if newCols < cols {
                    lines[index].cells.removeSubrange(newCols...)
                    if lines[index].cells[newCols - 1].width == 2 {
                        lines[index].cells[newCols - 1] = .blank
                    }
                } else {
                    lines[index].cells.append(contentsOf: repeatElement(.blank, count: newCols - cols))
                }
            }
        }
        if newRows < rows {
            lines.removeSubrange(newRows...)
        } else if newRows > rows {
            lines.append(contentsOf: repeatElement(Row(cols: newCols), count: newRows - rows))
        }
        cols = newCols
        rows = newRows
        cursor.row = min(cursor.row, newRows - 1)
        cursor.col = min(cursor.col, newCols - 1)
        cursor.pendingWrap = false
        scrollRegion = ScrollRegion(top: 0, bottom: newRows - 1)
    }

    // MARK: - Printing

    private mutating func print(_ scalar: Unicode.Scalar) {
        if (0x80...0x9F).contains(scalar.value) { return } // C1 controls
        var width = MoshCharacterWidth.columns(of: scalar)
        if width == 0 {
            attachCombining(scalar)
            return
        }
        if width == 2, cols < 2 { width = 1 }
        if cursor.pendingWrap {
            wrapToNextLine()
        }
        if width == 2, cursor.col == cols - 1 {
            // A wide character does not fit in the last column: it wraps
            // first, leaving that column blank.
            clearWideFragments(row: cursor.row, columns: cursor.col..<cols)
            lines[cursor.row].cells[cursor.col] = .blank
            wrapToNextLine()
        }
        let row = cursor.row
        let col = cursor.col
        clearWideFragments(row: row, columns: col..<(col + width))
        let text = scalar == " " ? "" : String(Character(scalar))
        lines[row].cells[col] = Cell(text: text, width: UInt8(width), style: style)
        if width == 2 {
            lines[row].cells[col + 1] = Cell(text: "", width: 0, style: style)
        }
        if col + width >= cols {
            cursor.col = cols - 1
            cursor.pendingWrap = true
        } else {
            cursor.col = col + width
        }
    }

    /// A zero-width scalar joins the cell printed last; with none before
    /// it on the row it is dropped.
    private mutating func attachCombining(_ scalar: Unicode.Scalar) {
        var col: Int
        if cursor.pendingWrap {
            col = cursor.col
        } else {
            guard cursor.col > 0 else { return }
            col = cursor.col - 1
        }
        if lines[cursor.row].cells[col].width == 0, col > 0 {
            col -= 1
        }
        var cell = lines[cursor.row].cells[col]
        guard cell.text.unicodeScalars.count < Self.maxScalarsPerCell else { return }
        if cell.text.isEmpty { cell.text = " " }
        cell.text.unicodeScalars.append(scalar)
        lines[cursor.row].cells[col] = cell
    }

    private mutating func wrapToNextLine() {
        lines[cursor.row].softWrapped = true
        cursor.col = 0
        index()
    }

    /// Overwriting or erasing either half of a wide character clears the
    /// other half.
    private mutating func clearWideFragments(row: Int, columns: Range<Int>) {
        guard !columns.isEmpty else { return }
        if columns.lowerBound > 0, lines[row].cells[columns.lowerBound].width == 0 {
            lines[row].cells[columns.lowerBound - 1] = .blank
        }
        if columns.upperBound < cols, lines[row].cells[columns.upperBound].width == 0 {
            lines[row].cells[columns.upperBound] = .blank
        }
    }

    // MARK: - Cursor and scrolling

    /// LF: down one row; at the bottom margin the scroll region scrolls up.
    private mutating func index() {
        cursor.pendingWrap = false
        if cursor.row == scrollRegion.bottom {
            scrollUp()
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    private mutating func reverseIndex() {
        cursor.pendingWrap = false
        if cursor.row == scrollRegion.top {
            scrollDown()
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    private mutating func scrollUp() {
        lines.remove(at: scrollRegion.top)
        lines.insert(erasedRow(), at: scrollRegion.bottom)
    }

    private mutating func scrollDown() {
        lines.remove(at: scrollRegion.bottom)
        lines.insert(erasedRow(), at: scrollRegion.top)
    }

    private mutating func moveCursor(row: Int, col: Int) {
        cursor.row = min(max(row, 0), rows - 1)
        cursor.col = min(max(col, 0), cols - 1)
        cursor.pendingWrap = false
    }

    // MARK: - Erasing

    /// The blank an erase leaves: the current background (BCE), every
    /// other attribute default.
    private var erasedCell: Cell {
        Cell.blank(Style(background: style.background))
    }

    private func erasedRow() -> Row {
        Row(cols: cols, fill: erasedCell)
    }

    /// Leaves cells that already hold the erased blank untouched, so an
    /// erase that changes nothing copies no shared row.
    private mutating func erase(row: Int, columns: Range<Int>) {
        let columns = columns.clamped(to: 0..<cols)
        guard !columns.isEmpty else { return }
        clearWideFragments(row: row, columns: columns)
        let blank = erasedCell
        for col in columns where lines[row].cells[col] != blank {
            lines[row].cells[col] = blank
        }
        if columns.upperBound == cols, lines[row].softWrapped {
            lines[row].softWrapped = false
        }
    }

    private mutating func eraseInLine(_ mode: Int) {
        cursor.pendingWrap = false
        switch mode {
        case 0: erase(row: cursor.row, columns: cursor.col..<cols)
        case 1: erase(row: cursor.row, columns: 0..<(cursor.col + 1))
        case 2: erase(row: cursor.row, columns: 0..<cols)
        default: break
        }
    }

    private mutating func eraseInDisplay(_ mode: Int) {
        cursor.pendingWrap = false
        switch mode {
        case 0:
            erase(row: cursor.row, columns: cursor.col..<cols)
            for row in (cursor.row + 1)..<rows { erase(row: row, columns: 0..<cols) }
        case 1:
            for row in 0..<cursor.row { erase(row: row, columns: 0..<cols) }
            erase(row: cursor.row, columns: 0..<(cursor.col + 1))
        case 2:
            for row in 0..<rows { erase(row: row, columns: 0..<cols) }
        default:
            break
        }
    }

    // MARK: - Controls and sequences

    private mutating func execute(_ byte: UInt8) {
        switch byte {
        case 0x07:
            bellCount &+= 1
        case 0x08:
            // BS moves left and cancels a pending wrap, as in xterm and
            // Ghostty: after printing in the last column it lands one
            // column left of it.
            cursor.col = max(0, cursor.col - 1)
            cursor.pendingWrap = false
        case 0x09:
            cursor.col = min(cols - 1, (cursor.col / 8 + 1) * 8)
            cursor.pendingWrap = false
        case 0x0A, 0x0B, 0x0C:
            index()
        case 0x0D:
            cursor.col = 0
            cursor.pendingWrap = false
        default:
            break
        }
    }

    private mutating func dispatchEscape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "D"):
            index()
        case UInt8(ascii: "E"):
            cursor.col = 0
            index()
        case UInt8(ascii: "M"):
            reverseIndex()
        case UInt8(ascii: "c"):
            var reset = MoshScreen(cols: cols, rows: rows)
            reset.iconName = iconName
            reset.windowTitle = windowTitle
            reset.clipboard = clipboard
            reset.bellCount = bellCount
            self = reset
        default:
            break
        }
    }

    private mutating func dispatchCSI(final: UInt8, params: [Int], privateMarker: UInt8) {
        if privateMarker == UInt8(ascii: "?") {
            switch final {
            case UInt8(ascii: "h"): setPrivateModes(params, enabled: true)
            case UInt8(ascii: "l"): setPrivateModes(params, enabled: false)
            default: break
            }
            return
        }
        guard privateMarker == 0 else { return }
        let first = params.first ?? 0
        let count = max(1, first)
        switch final {
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            let row = max(1, first)
            let col = max(1, params.count > 1 ? params[1] : 0)
            moveCursor(row: row - 1, col: col - 1)
        case UInt8(ascii: "A"): moveCursor(row: cursor.row - count, col: cursor.col)
        case UInt8(ascii: "B"): moveCursor(row: cursor.row + count, col: cursor.col)
        case UInt8(ascii: "C"): moveCursor(row: cursor.row, col: cursor.col + count)
        case UInt8(ascii: "D"): moveCursor(row: cursor.row, col: cursor.col - count)
        case UInt8(ascii: "G"): moveCursor(row: cursor.row, col: count - 1)
        case UInt8(ascii: "d"): moveCursor(row: count - 1, col: cursor.col)
        case UInt8(ascii: "K"): eraseInLine(first)
        case UInt8(ascii: "J"): eraseInDisplay(first)
        case UInt8(ascii: "X"):
            cursor.pendingWrap = false
            erase(row: cursor.row, columns: cursor.col..<(cursor.col + min(count, cols)))
        case UInt8(ascii: "m"): selectGraphicRendition(params)
        case UInt8(ascii: "r"): setScrollRegion(params)
        default: break
        }
    }

    private mutating func setScrollRegion(_ params: [Int]) {
        let top = max(1, params.first ?? 0)
        let requestedBottom = params.count > 1 ? params[1] : 0
        let bottom = requestedBottom == 0 ? rows : min(requestedBottom, rows)
        guard top < bottom else { return }
        scrollRegion = ScrollRegion(top: top - 1, bottom: bottom - 1)
        moveCursor(row: 0, col: 0)
    }

    private mutating func setPrivateModes(_ params: [Int], enabled: Bool) {
        for mode in params {
            switch mode {
            case 1: modes.applicationCursorKeys = enabled
            case 5: modes.reverseVideo = enabled
            case 25: modes.cursorVisible = enabled
            case 1000...1003: modes.mouseReporting = enabled ? mode : nil
            case 1004: modes.focusEvents = enabled
            case 1005, 1006, 1015: modes.mouseEncoding = enabled ? mode : nil
            case 2004: modes.bracketedPaste = enabled
            default: break
            }
        }
    }

    private mutating func selectGraphicRendition(_ params: [Int]) {
        var index = 0
        while index < params.count {
            let param = params[index]
            switch param {
            case 0: style = .plain
            case 1: style.attributes.insert(.bold)
            case 2: style.attributes.insert(.faint)
            case 3: style.attributes.insert(.italic)
            case 4, 21: style.attributes.insert(.underline)
            case 5, 6: style.attributes.insert(.blink)
            case 7: style.attributes.insert(.inverse)
            case 8: style.attributes.insert(.invisible)
            case 9: style.attributes.insert(.strikethrough)
            case 22: style.attributes.subtract([.bold, .faint])
            case 23: style.attributes.remove(.italic)
            case 24: style.attributes.remove(.underline)
            case 25: style.attributes.remove(.blink)
            case 27: style.attributes.remove(.inverse)
            case 28: style.attributes.remove(.invisible)
            case 29: style.attributes.remove(.strikethrough)
            case 30...37: style.foreground = .indexed(UInt8(param - 30))
            case 39: style.foreground = .default
            case 40...47: style.background = .indexed(UInt8(param - 40))
            case 49: style.background = .default
            case 90...97: style.foreground = .indexed(UInt8(param - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(param - 100 + 8))
            case 38, 48:
                guard let (color, used) = Self.extendedColor(params, at: index + 1) else {
                    return
                }
                if param == 38 { style.foreground = color } else { style.background = color }
                index += used
            default:
                break
            }
            index += 1
        }
    }

    /// `5;n` or `2;r;g;b` at `start`, with the number of params it used.
    private static func extendedColor(_ params: [Int], at start: Int) -> (Color, Int)? {
        guard start < params.count else { return nil }
        switch params[start] {
        case 5:
            guard start + 1 < params.count else { return nil }
            return (.indexed(UInt8(clamping: params[start + 1])), 2)
        case 2:
            guard start + 3 < params.count else { return nil }
            return (
                .rgb(
                    UInt8(clamping: params[start + 1]),
                    UInt8(clamping: params[start + 2]),
                    UInt8(clamping: params[start + 3])),
                4)
        default:
            return nil
        }
    }

    private mutating func dispatchOSC(_ bytes: [UInt8]) {
        guard let separator = bytes.firstIndex(of: UInt8(ascii: ";")) else { return }
        let command = String(decoding: bytes[..<separator], as: UTF8.self)
        let argument = String(decoding: bytes[(separator + 1)...], as: UTF8.self)
        switch command {
        case "0":
            iconName = argument
            windowTitle = argument
        case "1":
            iconName = argument
        case "2":
            windowTitle = argument
        case "52":
            // `selection;base64`; a `?` payload is a query, not a copy.
            guard argument.contains(";"), !argument.hasSuffix(";?") else { return }
            clipboard = argument
        default:
            break
        }
    }

    // MARK: - Parser

    /// A byte-level ECMA-48 parser: ground (UTF-8), ESC, CSI, OSC, and the
    /// strings (DCS, SOS, PM, APC) it skips.
    private struct Parser {
        private enum State {
            case ground
            case escape
            case escapeIntermediate
            case csi
            case osc
            case oscEscape
            case string
            case stringEscape
        }

        private static let maxParams = 32

        private var state = State.ground
        private var params: [Int] = []
        private var param = 0
        private var privateMarker: UInt8 = 0
        private var csiInvalid = false
        private var osc: [UInt8] = []
        private var oscOverflow = false
        private var utf8Remaining = 0
        private var utf8Value: UInt32 = 0
        private var utf8Minimum: UInt32 = 0

        mutating func feed(_ byte: UInt8, into screen: inout MoshScreen) {
            // CAN and SUB abort any sequence.
            if byte == 0x18 || byte == 0x1A {
                state = .ground
                utf8Remaining = 0
                return
            }
            switch state {
            case .ground:
                ground(byte, into: &screen)
            case .escape:
                escape(byte, into: &screen)
            case .escapeIntermediate:
                if byte == 0x1B {
                    state = .escape
                } else if byte < 0x20 {
                    screen.execute(byte)
                } else if byte >= 0x30 {
                    state = .ground
                }
            case .csi:
                csi(byte, into: &screen)
            case .osc:
                switch byte {
                case 0x07:
                    finishOSC(into: &screen)
                case 0x1B:
                    state = .oscEscape
                default:
                    if osc.count < MoshScreen.maxOSCBytes {
                        osc.append(byte)
                    } else {
                        oscOverflow = true
                    }
                }
            case .oscEscape:
                finishOSC(into: &screen)
                if byte != UInt8(ascii: "\\") {
                    state = .escape
                    escape(byte, into: &screen)
                }
            case .string:
                if byte == 0x1B { state = .stringEscape }
            case .stringEscape:
                if byte == UInt8(ascii: "\\") {
                    state = .ground
                } else {
                    state = .escape
                    escape(byte, into: &screen)
                }
            }
        }

        private mutating func ground(_ byte: UInt8, into screen: inout MoshScreen) {
            if utf8Remaining > 0 {
                if byte & 0xC0 == 0x80 {
                    utf8Value = (utf8Value << 6) | UInt32(byte & 0x3F)
                    utf8Remaining -= 1
                    if utf8Remaining == 0 {
                        let valid = utf8Value >= utf8Minimum
                        if valid, let scalar = Unicode.Scalar(utf8Value) {
                            screen.print(scalar)
                        } else {
                            screen.print("\u{FFFD}")
                        }
                    }
                    return
                }
                utf8Remaining = 0
                screen.print("\u{FFFD}")
            }
            switch byte {
            case 0x1B:
                state = .escape
            case 0x00..<0x20:
                screen.execute(byte)
            case 0x20..<0x7F:
                screen.print(Unicode.Scalar(byte))
            case 0x7F:
                break
            case 0xC2...0xDF:
                startUTF8(value: byte & 0x1F, remaining: 1, minimum: 0x80)
            case 0xE0...0xEF:
                startUTF8(value: byte & 0x0F, remaining: 2, minimum: 0x800)
            case 0xF0...0xF4:
                startUTF8(value: byte & 0x07, remaining: 3, minimum: 0x10000)
            default:
                screen.print("\u{FFFD}")
            }
        }

        private mutating func startUTF8(value: UInt8, remaining: Int, minimum: UInt32) {
            utf8Value = UInt32(value)
            utf8Remaining = remaining
            utf8Minimum = minimum
        }

        private mutating func escape(_ byte: UInt8, into screen: inout MoshScreen) {
            switch byte {
            case 0x1B:
                state = .escape
            case 0x00..<0x20:
                screen.execute(byte)
            case 0x20..<0x30:
                state = .escapeIntermediate
            case UInt8(ascii: "["):
                state = .csi
                params.removeAll(keepingCapacity: true)
                param = 0
                privateMarker = 0
                csiInvalid = false
            case UInt8(ascii: "]"):
                state = .osc
                osc.removeAll(keepingCapacity: true)
                oscOverflow = false
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                state = .string
            default:
                state = .ground
                screen.dispatchEscape(byte)
            }
        }

        private mutating func csi(_ byte: UInt8, into screen: inout MoshScreen) {
            switch byte {
            case 0x1B:
                state = .escape
            case 0x00..<0x20:
                screen.execute(byte)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                param = min(param * 10 + Int(byte - UInt8(ascii: "0")), 99_999)
            case UInt8(ascii: ";"), UInt8(ascii: ":"):
                if params.count < Self.maxParams { params.append(param) }
                param = 0
            case 0x3C...0x3F:
                if params.isEmpty, param == 0, privateMarker == 0 {
                    privateMarker = byte
                } else {
                    csiInvalid = true
                }
            case 0x20..<0x30:
                // Intermediates: none of the sequences this model knows.
                csiInvalid = true
            case 0x40...0x7E:
                state = .ground
                if params.count < Self.maxParams { params.append(param) }
                guard !csiInvalid else { return }
                screen.dispatchCSI(final: byte, params: params, privateMarker: privateMarker)
            default:
                break
            }
        }

        private mutating func finishOSC(into screen: inout MoshScreen) {
            state = .ground
            guard !oscOverflow else { return }
            screen.dispatchOSC(osc)
        }
    }
}
