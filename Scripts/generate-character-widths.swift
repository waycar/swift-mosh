#!/usr/bin/env swift
// Generates Sources/MoshCore/MoshCharacterWidthTable.swift from the Host
// libc's `wcwidth_l()` (Darwin, en_US.UTF-8): every scalar it reports as
// 2 columns wide, as sorted, merged ranges, plus a record of that source.
//
//   swift Scripts/generate-character-widths.swift          # rewrite the table
//   swift Scripts/generate-character-widths.swift --check  # exit 1 on drift
//
// Run from Packages/SwiftMosh (or pass the package path as the last argument).
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let check = arguments.contains("--check")
let packagePath = arguments.last { !$0.hasPrefix("--") } ?? FileManager.default.currentDirectoryPath
let tablePath = packagePath + "/Sources/MoshCore/MoshCharacterWidthTable.swift"

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// `wcwidth_l` is not imported into Swift; resolve it from libc. A per-call
// locale keeps the process-global one untouched.
typealias WcwidthL = @convention(c) (wchar_t, locale_t?) -> Int32
guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "wcwidth_l") else {
    fail("wcwidth_l not found in libc", code: 2)
}
let wcwidthL = unsafeBitCast(symbol, to: WcwidthL.self)
guard let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else {
    fail("en_US.UTF-8 locale unavailable", code: 2)
}

var wide: [ClosedRange<UInt32>] = []
var start: UInt32?
// The newest Unicode version among the scalars libc knows (width >= 0).
var unicodeVersion = (major: 0, minor: 0)
for value in UInt32(0)...0x10FFFF {
    guard let scalar = Unicode.Scalar(value) else {
        if let s = start { wide.append(s...(value - 1)); start = nil }
        continue
    }
    let width = wcwidthL(wchar_t(value), locale)
    if width >= 0, let age = scalar.properties.age, (age.major, age.minor) > unicodeVersion {
        unicodeVersion = (age.major, age.minor)
    }
    let isWide = width == 2
    if isWide, start == nil { start = value }
    if !isWide, let s = start { wide.append(s...(value - 1)); start = nil }
}
if let s = start { wide.append(s...0x10FFFF) }

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

let version = ProcessInfo.processInfo.operatingSystemVersion
let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
let osBuild = sysctlString("kern.osversion")
let unicode = "\(unicodeVersion.major).\(unicodeVersion.minor)"

func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16, uppercase: true) }

func wideBody() -> String {
    var lines: [String] = []
    var line = "       "
    for range in wide {
        let item = " \(hex(range.lowerBound))...\(hex(range.upperBound)),"
        if line.count + item.count > 100 { lines.append(line); line = "       " }
        line += item
    }
    lines.append(line)
    return """
        /// Scalars the source `wcwidth` reports as 2 columns wide.
        static let wide: [ClosedRange<UInt32>] = [
    \(lines.joined(separator: "\n"))
        ]
    }

    """
}

let source = """
enum MoshCharacterWidthTable {
    /// The libc `wide` was generated from: Darwin `wcwidth_l`, en_US.UTF-8.
    static let sourceDescription = "Darwin wcwidth_l, en_US.UTF-8, Unicode \(unicode), macOS \(osVersion) (\(osBuild))"
    /// The macOS build (`kern.osversion`) whose libc produced `wide`.
    static let sourceOSBuild = "\(osBuild)"


"""

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withFullDate]
let header = """
// GENERATED FILE, do not edit. (Waycar patch: client screen model.)
// Generator: Packages/SwiftMosh/Scripts/generate-character-widths.swift
// Generated: \(formatter.string(from: Date())) on macOS \(osVersion) (\(osBuild))
// Source: Darwin wcwidth_l() in en_US.UTF-8 (Unicode \(unicode)), scalars 0x0...0x10FFFF.


"""

let wideMarker = "    /// Scalars the source `wcwidth` reports as 2 columns wide."
if check {
    let existing = (try? String(contentsOfFile: tablePath, encoding: .utf8)) ?? ""
    guard let r = existing.range(of: wideMarker), String(existing[r.lowerBound...]) == wideBody() else {
        fail("\(tablePath) drifted from this Host's wcwidth (macOS \(osVersion) \(osBuild)); regenerate", code: 1)
    }
    if !existing.contains("static let sourceOSBuild = \"\(osBuild)\"") {
        print("note: the table was generated on another macOS build; its ranges still match this one")
    }
    print("OK: \(wide.count) wide ranges match the Host wcwidth (macOS \(osVersion) \(osBuild), Unicode \(unicode))")
} else {
    try (header + source + wideBody()).write(toFile: tablePath, atomically: true, encoding: .utf8)
    print("Wrote \(wide.count) wide ranges to \(tablePath) (macOS \(osVersion) \(osBuild), Unicode \(unicode))")
}
