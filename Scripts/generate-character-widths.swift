#!/usr/bin/env swift
// Generates Sources/MoshCore/MoshCharacterWidthTable.swift from the Host
// libc's `wcwidth()` (Darwin, en_US.UTF-8): every scalar it reports as
// 2 columns wide, as sorted, merged ranges.
//
//   swift Scripts/generate-character-widths.swift          # rewrite the table
//   swift Scripts/generate-character-widths.swift --check  # exit 1 on drift
//
// Run from Packages/SwiftMosh (or pass the package path as the last argument).
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let check = arguments.contains("--check")
let packagePath = arguments.last { !$0.hasPrefix("--") } ?? FileManager.default.currentDirectoryPath
let tablePath = packagePath + "/Sources/MoshCore/MoshCharacterWidthTable.swift"

guard setlocale(LC_ALL, "en_US.UTF-8") != nil else {
    FileHandle.standardError.write(Data("en_US.UTF-8 locale unavailable\n".utf8))
    exit(2)
}

var wide: [ClosedRange<UInt32>] = []
var start: UInt32?
for value in UInt32(0)...0x10FFFF {
    let isWide = Unicode.Scalar(value) != nil && wcwidth(wchar_t(value)) == 2
    if isWide, start == nil { start = value }
    if !isWide, let s = start { wide.append(s...(value - 1)); start = nil }
}
if let s = start { wide.append(s...0x10FFFF) }

func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16, uppercase: true) }

func body() -> String {
    var lines: [String] = []
    var line = "       "
    for range in wide {
        let item = " \(hex(range.lowerBound))...\(hex(range.upperBound)),"
        if line.count + item.count > 100 { lines.append(line); line = "       " }
        line += item
    }
    lines.append(line)
    return """
    enum MoshCharacterWidthTable {
        /// Scalars the Host's `wcwidth` reports as 2 columns wide.
        static let wide: [ClosedRange<UInt32>] = [
    \(lines.joined(separator: "\n"))
        ]
    }

    """
}

let marker = "enum MoshCharacterWidthTable {"
let os = ProcessInfo.processInfo.operatingSystemVersionString
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withFullDate]
let header = """
// GENERATED FILE, do not edit. (Waycar patch: client screen model.)
// Generator: Packages/SwiftMosh/Scripts/generate-character-widths.swift
// Generated: \(formatter.string(from: Date())) on macOS \(os)
// Source: Darwin wcwidth() in en_US.UTF-8, scalars 0x0...0x10FFFF.


"""

if check {
    let existing = (try? String(contentsOfFile: tablePath, encoding: .utf8)) ?? ""
    guard let r = existing.range(of: marker), String(existing[r.lowerBound...]) == body() else {
        FileHandle.standardError.write(Data("\(tablePath) drifted from the Host wcwidth; regenerate\n".utf8))
        exit(1)
    }
    print("OK: \(wide.count) wide ranges match the Host wcwidth")
} else {
    try (header + body()).write(toFile: tablePath, atomically: true, encoding: .utf8)
    print("Wrote \(wide.count) wide ranges to \(tablePath)")
}
