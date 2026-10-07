import Foundation

/// Terminal bytes that turn one `MoshScreen` into another on the terminal
/// that shows the first. (Waycar patch: client screen model.)
///
/// `MoshClientSession` uses it when mosh-server builds a state on an older
/// base than the screen Ghostty shows: the server's own diff is only right
/// on that base, so the session repaints from what Ghostty shows to the new
/// state instead. Written fresh from standard terminal semantics.
enum MoshScreenEncoder {
    /// Bytes that turn `displayed` into `target`. A different size repaints
    /// everything; otherwise an upward scroll is replayed with LF (so
    /// Ghostty keeps the scrolled-off rows in its scrollback) and only the
    /// rows that still differ are rewritten. Bells are not replayed.
    static func encode(from displayed: MoshScreen, to target: MoshScreen) -> Data {
        var writer = Writer(style: displayed.style)
        var forceRows = false
        var shown = displayed
        if displayed.cols != target.cols || displayed.rows != target.rows {
            writer.append("\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2J")
            writer.style = .plain
            forceRows = true
        } else {
            var prefix = Writer(style: displayed.style)
            if !displayed.hasFullScrollRegion {
                prefix.append("\u{1B}[r")
            }
            appendScroll(from: displayed, to: target, into: &prefix)
            if !prefix.bytes.isEmpty {
                shown.apply(Data(prefix.bytes))
                writer = prefix
            }
        }
        writeRows(of: target, over: forceRows ? nil : shown, into: &writer)
        writeState(of: target, after: displayed, into: &writer)
        return Data(writer.bytes)
    }

    /// Bytes that paint `target` over whatever a same-sized terminal shows:
    /// every row, every mode, the titles, the cursor. Never the clipboard,
    /// and no clear, so the terminal's scrollback is left alone.
    static func fullRepaint(of target: MoshScreen) -> Data {
        var writer = Writer(style: nil)
        writer.append("\u{1B}[r")
        writeRows(of: target, over: nil, into: &writer)
        writeState(of: target, after: nil, into: &writer)
        return Data(writer.bytes)
    }

    // MARK: - Scroll

    /// Target rows whose positions in `displayed` propose a scroll distance.
    private static let scrollProbeRows = 4
    /// The most scroll distances tried.
    private static let maxScrollCandidates = 16

    /// Appends the upward scroll that best maps `displayed` onto `target`,
    /// if it saves more rows than rewriting in place. An optimization only:
    /// `writeRows` compares rows exactly afterwards, so a poor or missed
    /// scroll costs bytes, never correctness. Rows are compared by hash, and
    /// only the distances at which one of the target's first few non-blank
    /// rows appears lower in `displayed` are tried, so the cost stays
    /// linear in the screen; the winner is confirmed with exact compares.
    private static func appendScroll(
        from displayed: MoshScreen, to target: MoshScreen, into writer: inout Writer
    ) {
        let rows = target.rows
        guard rows > 1 else { return }
        let shownLines = displayed.lines
        let targetLines = target.lines
        let shownHashes = shownLines.map { $0.cells.hashValue }
        let targetHashes = targetLines.map { $0.cells.hashValue }
        let blankRow = MoshScreen.Row(cols: target.cols).cells
        let targetIsBlank = targetLines.map { $0.cells == blankRow }

        /// Rows that match after scrolling rows `0...bottom` up by `shift`
        /// (0: in place), counting only non-blank target rows.
        func saved(shift: Int, bottom: Int, exact: Bool) -> Int {
            func matches(_ targetRow: Int, _ shownRow: Int) -> Bool {
                guard !targetIsBlank[targetRow], targetHashes[targetRow] == shownHashes[shownRow] else {
                    return false
                }
                return !exact || targetLines[targetRow].cells == shownLines[shownRow].cells
            }
            var count = 0
            for row in 0...(bottom - shift) where matches(row, row + shift) { count += 1 }
            for row in (bottom + 1)..<rows where matches(row, row) { count += 1 }
            return count
        }

        guard let lastDifferent = (0..<rows).last(where: { targetHashes[$0] != shownHashes[$0] }) else {
            return
        }

        var shownRowsByHash: [Int: [Int]] = [:]
        for (row, hash) in shownHashes.enumerated() {
            shownRowsByHash[hash, default: []].append(row)
        }
        var shifts: [Int] = []
        var probedHashes: Set<Int> = []
        probing: for row in 0..<rows where !targetIsBlank[row] {
            guard probedHashes.insert(targetHashes[row]).inserted else { continue }
            for shownRow in shownRowsByHash[targetHashes[row], default: []] where shownRow > row {
                if !shifts.contains(shownRow - row) { shifts.append(shownRow - row) }
                if shifts.count == Self.maxScrollCandidates { break probing }
            }
            if probedHashes.count == Self.scrollProbeRows { break }
        }

        let inPlace = saved(shift: 0, bottom: rows - 1, exact: false)
        var best: (saved: Int, shift: Int, bottom: Int)?
        let bottoms = lastDifferent == rows - 1 ? [rows - 1] : [rows - 1, lastDifferent]
        for bottom in bottoms {
            for shift in shifts where shift <= bottom {
                let count = saved(shift: shift, bottom: bottom, exact: false)
                if count > (best?.saved ?? inPlace) {
                    best = (count, shift, bottom)
                }
            }
        }
        guard let best,
              saved(shift: best.shift, bottom: best.bottom, exact: true)
                > saved(shift: 0, bottom: rows - 1, exact: true)
        else { return }

        // Scrolled-in lines take the current background: make it default.
        writer.setStyle(.plain)
        let lineFeeds = String(repeating: "\n", count: best.shift)
        if best.bottom == rows - 1 {
            writer.append("\u{1B}[r")
            writer.moveCursor(row: rows - 1, col: 0)
            writer.append(lineFeeds)
        } else {
            writer.append("\u{1B}[1;\(best.bottom + 1)r")
            writer.moveCursor(row: best.bottom, col: 0)
            writer.append(lineFeeds)
            writer.append("\u{1B}[r")
        }
    }

    // MARK: - Rows

    /// Rewrites every row of `target` that differs from `shown` (every row
    /// with no `shown`). Expects a full-screen scroll region.
    private static func writeRows(of target: MoshScreen, over shown: MoshScreen?, into writer: inout Writer) {
        var continuesWrap = false
        for row in 0..<target.rows {
            let line = target.lines[row]
            let differs = shown.map { $0.lines[row].cells != line.cells } ?? true
            guard differs || continuesWrap else { continue }
            continuesWrap = writeRow(line, at: row, cols: target.cols, continuingWrap: continuesWrap, into: &writer)
        }
    }

    /// Writes one row. Returns whether it ends soft-wrapped with a wrap
    /// pending, so the next row's first cell continues it without CUP and
    /// the terminal soft-wraps too.
    private static func writeRow(
        _ line: MoshScreen.Row, at row: Int, cols: Int, continuingWrap: Bool, into writer: inout Writer
    ) -> Bool {
        if !continuingWrap {
            writer.moveCursor(row: row, col: 0)
        }
        var end = cols
        if !line.softWrapped {
            while end > 0, line.cells[end - 1] == .blank { end -= 1 }
            // The wrap only happens once a cell is printed.
            if continuingWrap { end = max(end, 1) }
        }
        var col = 0
        var wrapPending = false
        while col < end {
            let cell = line.cells[col]
            writer.setStyle(cell.style)
            writer.append(cell.text.isEmpty ? " " : cell.text)
            // A continuation cell is reached only when orphaned: it was
            // written as a plain blank.
            let advance = cell.width == 2 ? 2 : 1
            let next = col + advance
            // The terminal may measure this cell differently: place the
            // next one explicitly so the rest of the row cannot shift.
            let irregular = cell.width != 1 || cell.text.unicodeScalars.count > 1
            if irregular {
                if next < end { writer.moveCursor(row: row, col: next) }
                wrapPending = false
            } else {
                wrapPending = next >= cols
            }
            col = next
        }
        if end < cols {
            writer.setStyle(.plain)
            writer.append("\u{1B}[K")
            wrapPending = false
        }
        return wrapPending && line.softWrapped
    }

    // MARK: - Modes, titles, cursor

    /// Everything after the cells: the scroll region, modes (all of them
    /// with no `displayed`), titles, a changed clipboard, then the cursor,
    /// the current rendition and cursor visibility.
    private static func writeState(of target: MoshScreen, after displayed: MoshScreen?, into writer: inout Writer) {
        if !target.hasFullScrollRegion {
            writer.append("\u{1B}[\(target.scrollRegion.top + 1);\(target.scrollRegion.bottom + 1)r")
        }

        let old = displayed?.modes
        let new = target.modes
        writer.privateMode(5, from: old?.reverseVideo, to: new.reverseVideo)
        writer.privateMode(2004, from: old?.bracketedPaste, to: new.bracketedPaste)
        if old == nil || old?.mouseReporting != new.mouseReporting {
            if let mode = new.mouseReporting {
                writer.append("\u{1B}[?\(mode)h")
            } else {
                writer.append("\u{1B}[?\(old?.mouseReporting ?? 1000)l")
            }
        }
        writer.privateMode(1004, from: old?.focusEvents, to: new.focusEvents)
        if old == nil || old?.mouseEncoding != new.mouseEncoding {
            if let mode = new.mouseEncoding {
                writer.append("\u{1B}[?\(mode)h")
            } else {
                writer.append("\u{1B}[?\(old?.mouseEncoding ?? 1006)l")
            }
        }
        writer.privateMode(1, from: old?.applicationCursorKeys, to: new.applicationCursorKeys)

        let iconChanged = displayed?.iconName != target.iconName
        let titleChanged = displayed?.windowTitle != target.windowTitle
        if iconChanged, titleChanged, target.iconName == target.windowTitle {
            writer.append("\u{1B}]0;\(target.windowTitle)\u{07}")
        } else {
            if iconChanged { writer.append("\u{1B}]1;\(target.iconName)\u{07}") }
            if titleChanged { writer.append("\u{1B}]2;\(target.windowTitle)\u{07}") }
        }
        if let displayed, let clipboard = target.clipboard, displayed.clipboard != clipboard {
            writer.append("\u{1B}]52;\(clipboard)\u{07}")
        }

        let cursor = target.cursor
        if cursor.pendingWrap {
            // Reprint the cell under the cursor so the wrap is pending again:
            // the server's next diff may rely on it.
            let line = target.lines[cursor.row]
            var col = cursor.col
            if line.cells[col].width == 0, col > 0 { col -= 1 }
            let cell = line.cells[col]
            writer.moveCursor(row: cursor.row, col: col)
            writer.setStyle(cell.style)
            writer.append(cell.text.isEmpty ? " " : cell.text)
        } else {
            writer.moveCursor(row: cursor.row, col: cursor.col)
        }
        writer.setStyle(target.style)
        writer.append(target.modes.cursorVisible ? "\u{1B}[?25h" : "\u{1B}[?25l")
    }

    // MARK: - Writer

    private struct Writer {
        var bytes: [UInt8] = []
        /// The terminal's current rendition; nil when unknown.
        var style: MoshScreen.Style?

        init(style: MoshScreen.Style?) {
            self.style = style
        }

        mutating func append(_ text: String) {
            bytes.append(contentsOf: text.utf8)
        }

        mutating func moveCursor(row: Int, col: Int) {
            append("\u{1B}[\(row + 1);\(col + 1)H")
        }

        /// An absolute SGR (`ESC[0;...m`), only when the rendition changes.
        mutating func setStyle(_ new: MoshScreen.Style) {
            guard style != new else { return }
            style = new
            var sgr = "\u{1B}[0"
            let flags: [(MoshScreen.Attributes, String)] = [
                (.bold, "1"), (.faint, "2"), (.italic, "3"), (.underline, "4"),
                (.blink, "5"), (.inverse, "7"), (.invisible, "8"), (.strikethrough, "9"),
            ]
            for (flag, code) in flags where new.attributes.contains(flag) {
                sgr += ";" + code
            }
            sgr += Self.colorParams(new.foreground, base: 30, bright: 90, extended: 38)
            sgr += Self.colorParams(new.background, base: 40, bright: 100, extended: 48)
            append(sgr + "m")
        }

        mutating func privateMode(_ mode: Int, from old: Bool?, to new: Bool) {
            guard old != new else { return }
            append("\u{1B}[?\(mode)\(new ? "h" : "l")")
        }

        private static func colorParams(_ color: MoshScreen.Color, base: Int, bright: Int, extended: Int) -> String {
            switch color {
            case .default:
                return ""
            case .indexed(let index) where index < 8:
                return ";\(base + Int(index))"
            case .indexed(let index) where index < 16:
                return ";\(bright + Int(index) - 8)"
            case .indexed(let index):
                return ";\(extended);5;\(index)"
            case .rgb(let red, let green, let blue):
                return ";\(extended);2;\(red);\(green);\(blue)"
            }
        }
    }
}
