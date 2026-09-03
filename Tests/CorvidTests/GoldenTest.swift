// GoldenTest.swift — the golden-suite port, corvid-swift's port of the
// engine's reference harness (corvid-db/corvid, crates/corvid-ffi/c/
// smoke.c, MIT) as ported by corvid-c, corvid-go, corvid-jvm, and the
// rest of the siblings.
//
// Same job as upstream, different moment of truth: the engine's harness
// links the cdylib cargo JUST BUILT; this one drives the xcframework
// SwiftPM DOWNLOADED from the pinned engine release (the Package.swift
// binary target) through THIS BINDING — the Swift API wherever it can
// express the op, the raw C surface (import CorvidEngine, the value
// handles Values.encode builds) where the op is inherently raw
// (VTYPE/VLEN/VAS_*/V*_REF/VNEST/VCLONE/VPUSH/VPUT/VMAP_KEYS/GET_KEYS
// are value-handle exercises). If the published slices, header, or
// fixtures disagree with the engine's own suite, THIS fails where that
// one stayed green — divergence is a finding for the engine repo, never
// patched around here.
//
// The mechanics are deliberately IDENTICAL to the C harness (and the
// Kotlin twin this port was written against) so the suites are
// diffable: same fixture grammar (OP<TAB>args<TAB>expected; value
// literals with bits:/bits32: NaN specials; ~x computed-double
// tolerance), same dispatch table, one line at a time, every line
// dispatched, every expectation checked. `lines` comes from an
// INDEPENDENT pre-scan; the first failure names file:line + OP +
// expected-vs-got.
//
// Verdict protocol: stdout carries one "SMOKE <file> lines=<n>
// executed=<n>" line per fixture.
import CorvidEngine
import Foundation
import Testing
@testable import Corvid

// Foundation's Predicate<...> macro type collides with the binding's
// Predicate class — the fixture interpreter always means Corvid's.
private typealias Predicate = CorvidPredicate

private struct Marker: Error {}

/// The harness's assertion error — the first failure carries
/// file:line + OP context.
private struct GoldenFailure: Error {
    let message: String
}

final class Scenario {
    let file: String
    var line = 0
    var op = "?"
    var db: Db? = nil
    var coll: Collection? = nil
    let workdir: URL
    let dbPath: URL
    let db2Path: URL
    let dumpPath: URL
    let backupPath: URL
    var lastAutoId: Int64 = 0

    init(file: String, workdir: URL) {
        self.file = file
        self.workdir = workdir
        dbPath = workdir.appendingPathComponent("db.redb")
        db2Path = workdir.appendingPathComponent("db-2.redb")
        dumpPath = workdir.appendingPathComponent("db.dump")
        backupPath = workdir.appendingPathComponent("db.backup.redb")
    }

    func fail(_ message: String) throws -> Never {
        throw GoldenFailure(message: "FAIL \(file):\(line) OP=\(op): \(message)")
    }

    func check(_ cond: Bool, _ message: String) throws {
        if !cond { try fail(message) }
    }

    /// A failure with exactly this code AND a recorded message.
    func expectErr(_ result: Result<Any?, Error>, _ code: CorvidErrorCode) throws {
        guard case .failure(let e) = result else { try fail("expected CORVID_ERR \(code.rawValue), got success") }
        guard let ce = e as? CorvidError else {
            try fail("expected a CorvidError, got \(type(of: e)): \(e)")
        }
        try check(ce.code == code,
                  "expected error code \(code.rawValue), got \(ce.code.rawValue) (\(ce.message))")
        try check(!ce.message.isEmpty, "error code \(code.rawValue) recorded but the message is missing")
    }

    func expectOk(_ result: Result<Any?, Error>) throws {
        if case .failure(let e) = result { try fail("expected ok, got \(e)") }
    }

    func closeColl() {
        coll?.close()
        coll = nil
    }

    func closeDb() {
        closeColl()
        db?.close()
        db = nil
    }

    func docs() throws -> Collection {
        if coll == nil {
            guard let d = db else { try fail("no database open in this scenario") }
            coll = try Result { try d.collection("docs") }.get()
        }
        return coll!
    }

    func openMemory() throws {
        closeDb()
        db = try Result { try Corvid.openMemory() }.get()
        _ = try docs()
    }

    func openFile(_ path: URL) throws {
        closeDb()
        db = try Result { try Corvid.open(path.path) }.get()
        _ = try docs()
    }

    func setColl(_ name: String) throws {
        closeColl()
        guard let d = db else { try fail("no database open") }
        let c = try Result { try d.collection(name) }.get()
        try check(c.name == name, "collection_name round trip failed")
        coll = c
    }
}

// ---------------------------------------------------------------------------
// Tokenizing (the C harness's split_top, verbatim)
// ---------------------------------------------------------------------------

private func splitTop(_ s: String) -> [String] {
    let c = Array(s)
    var out: [String] = []
    var depth = 0
    var start = 0
    for i in 0...c.count {
        let ch = i < c.count ? c[i] : ","
        switch ch {
        case "[", "{", "(": depth += 1
        case "]", "}", ")": depth -= 1
        default: break
        }
        if ch == "," && depth == 0 {
            var end = i
            while end > start && (c[end - 1] == " " || c[end - 1] == "\r") { end -= 1 }
            if end > start { out.append(String(c[start..<end])) }
            start = i + 1
        }
    }
    return out
}

private func parseI64(_ s: String) throws -> Int64 {
    guard let v = Int64(s) else { throw GoldenFailure(message: "bad int token \(s)") }
    return v
}

private func parseInt(_ s: String) throws -> Int { Int(try parseI64(s)) }

private func parseHex(_ s: String) throws -> Int64 {
    let body = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
    guard let v = UInt64(body, radix: 16) else { throw GoldenFailure(message: "bad hex token \(s)") }
    return Int64(bitPattern: v)
}

private func parseDouble(_ s: String) throws -> Double {
    if s.hasPrefix("bits:") { return Double(bitPattern: UInt64(try parseHex(String(s.dropFirst(5))))) }
    switch s {
    case "inf": return .infinity
    case "-inf": return -.infinity
    case "nan": return .nan
    default:
        guard let v = Double(s) else { throw GoldenFailure(message: "bad float token \(s)") }
        return v
    }
}

private func doubleExact(_ got: Double, _ want: Double) -> Bool {
    got.bitPattern == want.bitPattern
}

private func doubleNear(_ got: Double, _ want: Double) -> Bool {
    abs(got - want) <= 1e-6 * (1.0 + abs(want))
}

private func doubleMatches(_ got: Double, _ tok: String) throws -> Bool {
    if tok.hasPrefix("~") { return doubleNear(got, try parseDouble(String(tok.dropFirst()))) }
    if tok.hasPrefix("=") { return doubleExact(got, try parseDouble(String(tok.dropFirst()))) }
    return doubleExact(got, try parseDouble(tok))
}

private func errToken(_ expected: String) throws -> CorvidErrorCode {
    guard expected.hasPrefix("err:"),
        let n = UInt32(expected.dropFirst(4)),
        let code = CorvidErrorCode(rawValue: n)
    else { throw GoldenFailure(message: "bad err token \(expected)") }
    return code
}

// ---------------------------------------------------------------------------
// Value literals: parse into Swift values (Values.encode builds the C
// side — exercising the binding's value mapping)
// ---------------------------------------------------------------------------

private func startsWord(_ s: [Character], _ i: Int, _ word: String) -> Bool {
    let w = Array(word)
    guard i + w.count <= s.count else { return false }
    for k in 0..<w.count where s[i + k] != w[k] { return false }
    let after = i + w.count
    if after >= s.count { return true }
    let c = s[after]
    return c == "," || c == "]" || c == "}" || c == " " || c == "\r"
}

private func matchParen(_ s: [Character], _ open: Int) throws -> Int {
    var depth = 0
    for q in open..<s.count {
        if s[q] == "(" { depth += 1 }
        if s[q] == ")" {
            depth -= 1
            if depth == 0 { return q }
        }
    }
    throw GoldenFailure(message: "unbalanced () in literal")
}

private func closeOf(_ open: Character) -> Character {
    switch open {
    case "[": return "]"
    case "{": return "}"
    default: return ")"
    }
}

private func matchBracket(_ s: [Character], _ open: Int) throws -> Int {
    var depth = 0
    for q in open..<s.count {
        if s[q] == s[open] { depth += 1 }
        if s[q] == closeOf(s[open]) {
            depth -= 1
            if depth == 0 { return q }
        }
    }
    throw GoldenFailure(message: "unbalanced \(s[open]) in literal")
}

private func skipWs(_ s: [Character], _ i: Int) -> Int {
    var j = i
    while j < s.count && (s[j] == " " || s[j] == "\r") { j += 1 }
    return j
}

// Scans one numeric literal (int vs float classified by the characters
// seen, exactly like the C harness).
private func buildNumber(_ s: [Character], _ i: Int) throws -> (Any?, Int) {
    let str = String(s)
    if startsWord(s, i, "inf") { return (Double.infinity, i + 3) }
    if startsWord(s, i, "-inf") { return (-Double.infinity, i + 4) }
    if startsWord(s, i, "nan") { return (Double.nan, i + 3) }
    var j = i
    var isFloat = false
    var isBits = false
    if str.hasPrefix("bits:") && str.index(str.startIndex, offsetBy: i) == str.index(str.startIndex, offsetBy: i) {
        // (prefix checked positionally below via startsWord-style compare)
    }
    if i + 5 <= s.count && String(s[i..<min(i + 5, s.count)]) == "bits:" {
        isFloat = true
        isBits = true
        j += 5
    }
    scan: while j < s.count {
        let c = s[j]
        if c.isNumber || c == "-" || c == "+" { j += 1; continue }
        if c == "." || c == "e" || c == "E" { isFloat = true; j += 1; continue }
        if isBits && c.isHexDigit || (isBits && (c == "x" || c == "X")) { j += 1; continue }
        break scan
    }
    let tok = String(s[i..<j])
    if tok.isEmpty { throw GoldenFailure(message: "empty numeric literal") }
    if isBits { return (try parseDouble(tok), j) } // re-includes the prefix
    if isFloat {
        guard let v = Double(tok) else { throw GoldenFailure(message: "bad float literal \(tok)") }
        return (v, j)
    }
    guard let v = Int64(tok) else { throw GoldenFailure(message: "bad int literal \(tok)") }
    // Int is 64-bit on every supported platform; the wrapper's value
    // domain is Int (Int64 would never match encode's `as? Int`).
    return (Int(v), j)
}

private func buildLit(_ s: [Character], _ i: Int) throws -> (Any?, Int) {
    let i0 = skipWs(s, i)
    if i0 >= s.count { throw GoldenFailure(message: "empty literal") }
    let c = s[i0]

    if c == "-" || c.isNumber { return try buildNumber(s, i0) }
    // bits:/inf/-inf/nan start with letters but are NUMBERS; they win
    // over the b(...)/t(...) literal heads.
    if i0 + 5 <= s.count && String(s[i0..<i0 + 5]) == "bits:"
        || startsWord(s, i0, "inf") || startsWord(s, i0, "-inf") || startsWord(s, i0, "nan") {
        return try buildNumber(s, i0)
    }
    if startsWord(s, i0, "null") { return (nil, i0 + 4) }
    if startsWord(s, i0, "true") { return (true, i0 + 4) }
    if startsWord(s, i0, "false") { return (false, i0 + 5) }

    if (c == "t" || c == "b") && i0 + 1 < s.count && s[i0 + 1] == "(" {
        let close = try matchParen(s, i0 + 1)
        let body = String(s[(i0 + 2)..<close])
        if c == "t" { return (body, close + 1) }
        guard let bytes = body.data(using: .isoLatin1) else {
            throw GoldenFailure(message: "bad bytes literal \(body)")
        }
        return (bytes, close + 1)
    }
    if i0 + 4 <= s.count && String(s[i0..<i0 + 4]) == "vec(" {
        let close = try matchParen(s, i0 + 3)
        let vec = try buildVec(String(s[(i0 + 4)..<close]))
        return (vec, close + 1)
    }

    if c == "[" {
        let close = try matchBracket(s, i0)
        var arr: [Any?] = []
        var j = i0 + 1
        while j < close {
            let (item, nj) = try buildLit(s, j)
            arr.append(item)
            j = skipWs(s, nj)
            if j < close && s[j] == "," { j += 1 }
        }
        return (arr, close + 1)
    }

    if c == "{" {
        let close = try matchBracket(s, i0)
        var m: [String: Any?] = [:]
        var order: [String] = [] // LinkedHashMap: insertion order kept for encode determinism
        var j = i0 + 1
        while j < close {
            j = skipWs(s, j)
            let ks = j
            while j < close && s[j] != "=" && s[j] != "," && s[j] != "}" { j += 1 }
            if j >= close || s[j] != "=" { throw GoldenFailure(message: "map literal needs k=v pairs") }
            var keyStart = ks
            while s[keyStart] == " " { keyStart += 1 }
            let key = String(s[keyStart..<j])
            j += 1 // past '='
            let (v, nj) = try buildLit(s, j)
            if m[key] == nil && m.index(forKey: key) != nil {}
            if m[key] == nil { order.append(key) }
            m[key] = v
            j = skipWs(s, nj)
            if j < close && s[j] == "," { j += 1 }
        }
        return (MapLiteralOrder(shape: m, order: order), close + 1)
    }

    let snippet = String(s[i0..<min(i0 + 24, s.count)])
    throw GoldenFailure(message: "unparseable literal at \(snippet)")
}

/// The fixture grammar's map literals are insertion-ordered; Swift
/// dictionaries are not. The harness keeps the parse-order and builds
/// the map through ordered puts (the engine sorts keys itself on
/// decode — VMAP_KEYS — so order matters only for construction).
private struct MapLiteralOrder {
    let shape: [String: Any?]
    let order: [String]
}

private func buildVec(_ body: String) throws -> [Float] {
    try splitTop(body).map { tk -> Float in
        if tk.hasPrefix("bits32:") {
            return Float(bitPattern: UInt32(truncatingIfNeeded: try parseHex(String(tk.dropFirst(7)))))
        }
        return Float(try parseDouble(tk))
    }
}

/// Recursively normalizes parsed literals to the shapes the wrapper
/// produces: MapLiteralOrder (insertion-ordered parse) → plain
/// [String: Any?] at EVERY depth.
private func normalizeLit(_ v: Any?) -> Any? {
    if let m = v as? MapLiteralOrder {
        var out: [String: Any?] = [:]
        for k in m.order { out[k] = normalizeLit(m.shape[k]) }
        return out
    }
    if let arr = v as? [Any?] { return arr.map(normalizeLit) }
    return v
}

private func lit(_ s: String) throws -> Any? {
    normalizeLit(try buildLit(Array(s), 0).0)
}

// ---------------------------------------------------------------------------
// Structural comparison of Swift values (bit-exact floats)
// ---------------------------------------------------------------------------

private func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
    switch a {
    case nil: return b == nil
    case let a as Bool:
        guard let b = b as? Bool else { return false }
        return a == b
    case let a as Int:
        guard let b = b as? Int else { return false }
        return a == b
    case let a as Double:
        guard let b = b as? Double else { return false }
        return a.bitPattern == b.bitPattern
    case let a as String:
        guard let b = b as? String else { return false }
        return a == b
    case let a as Data:
        guard let b = b as? Data else { return false }
        return a == b
    case let a as [Float]:
        guard let b = b as? [Float] else { return false }
        return a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
    case let a as [Any?]:
        guard let b = b as? [Any?] else { return false }
        return a.count == b.count && zip(a, b).allSatisfy { valuesEqual($0, $1) }
    case let a as [String: Any?]:
        guard let b = b as? [String: Any?] else { return false }
        return a.count == b.count && a.allSatisfy { k, v in b[k] != nil && valuesEqual(v, b[k]!) }
    default: return false
    }
}

private func render(_ v: Any?) -> String {
    switch v {
    case nil: return "null"
    case let v as Double: return String(format: "double(0x%016llx=%g)", v.bitPattern, v)
    case let v as [Float]: return "vec(dim=\(v.count))"
    case let v as Data: return "bytes(\(v.count) bytes)"
    case let v as [String: Any?]: return "map(len=\(v.count))"
    default: return String(describing: v)
    }
}

private func checkValue(_ s: Scenario, _ got: Any?, _ wantTok: String) throws {
    let want = try lit(wantTok)
    try s.check(valuesEqual(got, want), "value mismatch: got \(render(got)), want \(render(want))")
}

// ---------------------------------------------------------------------------
// Cursor helpers over the public API's returned rows
// ---------------------------------------------------------------------------

private func rowKeys(_ rows: [Row]) -> [String] { rows.map { String(decoding: $0.key, as: UTF8.self) } }
private func rowScores(_ rows: [Row]) -> [Float] { rows.map(\.score) }
private func bytesKeys(_ keys: [Data]) -> [String] { keys.map { String(decoding: $0, as: UTF8.self) } }

/// Materializes one of the single-pass iterators (Rows/GeoHits/Strs —
/// Sequence AND IteratorProtocol conformers, for which Array.init's
/// sequence overload is ambiguous) into an array.
private func materialize<S: Sequence>(_ seq: S) -> [S.Element] {
    var out: [S.Element] = []
    for e in seq { out.append(e) }
    return out
}

private func checkKeys(_ s: Scenario, _ keys: [String], _ expected: String) throws {
    try s.check(expected.count >= 3 && expected.first == "k" && expected.dropFirst().first == "("
        && expected.last == ")",
        "key expectation must be k(...), got \(expected)")
    let body = String(expected.dropFirst(2).dropLast())
    let want = body.isEmpty ? [] : splitTop(body)
    try s.check(keys.count == want.count, "row count \(keys.count), expected \(want.count) (\(keys))")
    for i in want.indices {
        try s.check(keys[i] == want[i], "row \(i) key \(keys[i]), expected \(want[i])")
    }
}

private func checkScores(_ s: Scenario, _ scores: [Float], _ suffix: String) throws {
    if suffix.isEmpty { return }
    try s.check(suffix.first == "|", "score suffix must start with |, got \(suffix)")
    let body = String(suffix.dropFirst())
    if body.isEmpty { return }
    let toks = splitTop(body)
    try s.check(scores.count == toks.count, "score count \(scores.count), expected \(toks.count)")
    for i in toks.indices {
        let got = Double(scores[i])
        try s.check(try doubleMatches(got, toks[i]), "row \(i) score \(got) does not match \(toks[i])")
    }
}

private func keyPart(_ expected: String) -> String {
    let parts = expected.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    return String(parts[0])
}

private func suffixPart(_ expected: String) -> String {
    guard let idx = expected.firstIndex(of: "|") else { return "" }
    return String(expected[idx...])
}

private func textBody(_ s: Scenario, _ tok: String) throws -> String {
    try s.check(tok.count >= 3 && tok.first == "t" && tok.dropFirst().first == "(" && tok.last == ")",
                "expected a t(...) literal, got \(tok)")
    return String(tok.dropFirst(2).dropLast())
}

private func listBody(_ s: Scenario, _ tok: String) throws -> String {
    try s.check(tok.count >= 3 && tok.first == "k" && tok.dropFirst().first == "(" && tok.last == ")",
                "expected a k(...) list, got \(tok)")
    return String(tok.dropFirst(2).dropLast())
}

// ---------------------------------------------------------------------------
// Predicate / enum helpers
// ---------------------------------------------------------------------------

private func fieldCmp(_ s: Scenario, _ path: String, _ op: String, _ v: Any?) throws -> Predicate {
    let f = field(path)
    switch op {
    case "eq": return try f.eq(v)
    case "ne": return try f.ne(v)
    case "lt": return try f.lt(v)
    case "le": return try f.le(v)
    case "gt": return try f.gt(v)
    case "ge": return try f.ge(v)
    default: try s.fail("bad cmp op \(op)")
    }
}

private func parseMetric(_ s: Scenario, _ str: String) throws -> Metric {
    switch str {
    case "cosine": return .cosine
    case "dot": return .dot
    case "l2": return .l2
    default: try s.fail("bad metric \(str)")
    }
}

private func parseQuant(_ s: Scenario, _ str: String) throws -> Quant {
    switch str {
    case "none": return .none
    case "binary": return .binary
    case "scalar": return .scalar
    default: try s.fail("bad quant \(str)")
    }
}

private func parseFieldType(_ s: Scenario, _ str: String) throws -> FieldType {
    switch str {
    case "any": return .any
    case "bool": return .bool
    case "int": return .int
    case "float": return .float
    case "text": return .text
    case "bytes": return .bytes
    case "vector": return .vector
    case "array": return .array
    case "map": return .map
    default: try s.fail("bad field type \(str)")
    }
}

private func filteredCount(_ s: Scenario, _ p: Predicate) throws -> Int {
    try Result { try s.docs().query().filter(p).count() }.get()
}

private func expectNum(_ s: Scenario, _ expected: String, _ got: Int) throws {
    try s.check(Int(try parseI64(expected)) == got, "expected \(got), want \(expected)")
}

// Builds an OWNED handle from a literal token (Values.encode → the raw
// value family; the harness frees it).
private func encodeParsed(_ v: Any?) throws -> Value {
    // [Float] casts covariantly to [Any?] at runtime — keep vectors
    // ahead of the array branch (FloatArray-before-List, Kotlin-shaped).
    if v is [Float] { return try Values.encode(v) }
    if let m = v as? MapLiteralOrder {
        // ordered construction through the builder API itself
        let root = Value(infallible: corvid_value_map_new())
        for k in m.order {
            let child = try encodeParsed(m.shape[k])
            try Values.withUTF8(k) { p, n in
                try check2(corvid_value_map_put(root.handle, p, n, child.take()))
            }
        }
        return root
    }
    if let arr = v as? [Any?] {
        let root = Value(infallible: corvid_value_array_new())
        for item in arr {
            let child = try encodeParsed(item)
            try check2(corvid_value_array_push(root.handle, child.take()))
        }
        return root
    }
    return try Values.encode(v)
}

private func encode(_ literal: String) throws -> Value {
    try encodeParsed(try buildLit(Array(literal), 0).0)
}

private func check2(_ st: corvid_status) throws {
    if st != CORVID_OK { throw lastError() }
}

// Walks a child path like "a.b.0.c" over a raw handle; nil-pointer when
// absent. The visited children are borrowed views (FFI.md §5).
private func walkHandlePath(_ root: OpaquePointer, _ path: String) -> OpaquePointer? {
    var cur: OpaquePointer? = root
    let segs = path.split(separator: ".").map(String.init)
    for seg in segs where cur != nil {
        if seg.allSatisfy(\.isNumber) {
            cur = corvid_value_array_get(cur, Int(seg)!)
        } else {
            cur = Values.withUTF8(seg) { p, n in corvid_value_map_get(cur, p, n) }
        }
    }
    return cur
}

// ---------------------------------------------------------------------------
// OP implementations (the C harness's run_line, op for op)
// ---------------------------------------------------------------------------

private func runLine(_ s: Scenario, _ op: String, _ args: String, _ expected: String) throws {
    let a = args.isEmpty ? [] : splitTop(args)

    // ---- pure value ops (no db; raw handle layer) ----
    switch op {
    case "VERSION":
        try s.check(corvid_ffi_version() == 1, "FFI_VERSION must be 1, got \(corvid_ffi_version())")
        return
    case "VTYPE":
        let names = ["null", "bool", "int", "float", "text", "bytes", "array", "map", "vector"]
        let v = try encode(a[0])
        let t = corvid_value_type(v.handle).rawValue
        try s.check(t >= 0 && t <= 8, "type tag \(t) out of range")
        try s.check(expected == names[Int(t)], "type \(names[Int(t)]), want \(expected)")
        return // v's deinit frees the handle (the wrapper owns it)
    case "VLEN":
        let v = try encode(a[0])
        try expectNum(s, expected, Int(corvid_value_len(v.handle)))
        return
    case "VAS_INT", "VAS_FLOAT", "VAS_BOOL":
        let v = try encode(a[0])
        var ok: Int32 = 0 // v's deinit frees the handle
        if op == "VAS_INT" {
            let got = corvid_value_as_int(v.handle, &ok)
            if expected == "fail" { try s.check(ok == 0, "as_int unexpectedly ok (\(got))") }
            else {
                try s.check(ok == 1, "as_int failed")
                try s.check(expected == "ok:\(got)", "as_int ok:\(got), want \(expected)")
            }
        } else if op == "VAS_FLOAT" {
            let got = corvid_value_as_float(v.handle, &ok)
            if expected == "fail" { try s.check(ok == 0, "as_float unexpectedly ok") }
            else {
                try s.check(ok == 1, "as_float failed")
                try s.check(expected.hasPrefix("ok:"), "as_float expectation must be ok:<double>, got \(expected)")
                try s.check(try doubleMatches(got, String(expected.dropFirst(3))),
                            "as_float \(got.bitPattern) (\(got)) does not match \(expected.dropFirst(3))")
            }
        } else {
            let got = corvid_value_as_bool(v.handle, &ok)
            if expected == "fail" { try s.check(ok == 0, "as_bool unexpectedly ok") }
            else {
                try s.check(ok == 1, "as_bool failed")
                let want = got != 0 ? "ok:1" : "ok:0"
                try s.check(expected == want, "as_bool \(want), want \(expected)")
            }
        }
        return
    case "VTEXT_REF", "VBYTES_REF", "VVECTOR_REF":
        let v = try encode(a[0]) // deinit frees
        if op == "VTEXT_REF" {
            var len = 0
            guard let p = corvid_value_text_ref(v.handle, &len) else {
                try s.fail("text_ref returned NULL for a text value")
            }
            let got = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: len)
                .bindMemory(to: UInt8.self), as: UTF8.self)
            try s.check(got == textBody(s, expected), "text bytes differ")
        } else if op == "VBYTES_REF" {
            var len = 0
            guard let p = corvid_value_bytes_ref(v.handle, &len) else {
                try s.fail("bytes_ref returned NULL for a bytes value")
            }
            try s.check(expected.count >= 3 && expected.hasPrefix("b("),
                        "bytes expectation must be b(...), got \(expected)")
            let want = String(expected.dropFirst(2).dropLast()).data(using: .isoLatin1)!
            try s.check(Data(bytes: p, count: len) == want, "bytes differ")
        } else {
            var dim = 0
            guard let p = corvid_value_vector_ref(v.handle, &dim) else {
                try s.fail("vector_ref returned NULL for a vector value")
            }
            let want = try lit(a[0]) as! [Float]
            try s.check(dim == want.count, "ref dim \(dim), rebuilt dim \(want.count)")
            for i in want.indices {
                try s.check(p[i].bitPattern == want[i].bitPattern, "vector elem \(i) differs bit-exactly")
            }
        }
        return
    case "VNEST", "VCLONE":
        let root = try encode(a[0]) // deinit frees
        var holder = root.handle
        if op == "VCLONE" {
            guard let c = corvid_value_clone(root.handle) else { try s.fail("clone failed") }
            holder = c
        }
        defer { if op == "VCLONE" { corvid_value_free(holder) } }
        let child = walkHandlePath(holder, a[1])
        if expected == "absent" {
            try s.check(child == nil, "path unexpectedly present")
        } else {
            try s.check(child != nil, "path unexpectedly absent, want \(expected)")
            try checkValue(s, Values.decodeIfPresent(child), expected)
        }
        return
    case "VPUSH":
        let arr = try encode(a[0])
        let item = try encode(a[1])
        try check2(corvid_value_array_push(arr.handle, item.take())) // consumes item
        try expectNum(s, expected, Int(corvid_value_len(arr.handle)))
        return
    case "VPUT":
        let m = try encode(a[0])
        let value = try encode(a[2])
        try Values.withUTF8(a[1]) { p, n in
            try check2(corvid_value_map_put(m.handle, p, n, value.take())) // consumes
        }
        try expectNum(s, expected, Int(corvid_value_len(m.handle)))
        return
    case "VMAP_KEYS":
        let v = try encode(a[0]) // deinit frees
        guard let cursor = corvid_value_map_keys(v.handle) else { try s.fail("value_map_keys failed") }
        var keys: [String] = []
        let strs = Strs(cursor)
        while let kb = strs.next() { keys.append(String(decoding: kb, as: UTF8.self)) }
        try checkKeys(s, keys, expected)
        return
    case "NULLFREES":
        corvid_value_free(nil) // every _free(NULL) shape is a no-op (§7)
        corvid_pred_free(nil)
        corvid_query_free(nil)
        corvid_rows_free(nil)
        corvid_groupiter_free(nil)
        corvid_schemaiter_free(nil)
        corvid_strs_free(nil)
        corvid_geohits_free(nil)
        corvid_collection_free(nil)
        return
    default: break
    }

    // ---- db-required ops ----
    switch op {
    case "COLL":
        try s.setColl(a[0]); return
    case "INSERT", "INSERT_ERR":
        let r = Result<Any?, Error> { try s.docs().insert(Data(a[0].utf8), try lit(a[1])) }
        if op == "INSERT_ERR" { try s.expectErr(r, errToken(expected)) } else { try s.expectOk(r) }
        return
    case "LEN":
        try expectNum(s, expected, try Result { try s.docs().len() }.get())
        return
    case "GET", "GETFIELD":
        if op == "GETFIELD" {
            // Raw walk (the C harness's walk_path): a NULL child pointer
            // is "absent", a Null VALUE is a present child.
            var out: OpaquePointer? = nil
            try Values.withBytes(Data(a[0].utf8)) { p, n in
                try check2(corvid_get(s.docs().handle, p, n, &out))
            }
            try s.check(out != nil, "GETFIELD on an absent document")
            let child = walkHandlePath(out!, a[1])
            if expected == "absent" {
                try s.check(child == nil, "field unexpectedly present")
            } else {
                try s.check(child != nil, "field unexpectedly absent, want \(expected)")
                try checkValue(s, Values.decodeIfPresent(child), expected)
            }
            corvid_value_free(out)
            return
        }
        let doc = try Result { try s.docs().get(Data(a[0].utf8)) }.get()
        if expected == "absent" {
            try s.check(doc == nil, "expected absence, got a document: \(render(doc))")
        } else {
            try checkValue(s, doc, expected)
        }
        return
    case "GET_KEYS":
        var out: OpaquePointer? = nil
        try Values.withBytes(Data(a[0].utf8)) { p, n in
            try check2(corvid_get(s.docs().handle, p, n, &out))
        }
        try s.check(out != nil, "GET_KEYS on an absent document")
        guard let cursor = corvid_value_map_keys(out!) else { try s.fail("value_map_keys failed") }
        var keys: [String] = []
        let strs = Strs(cursor)
        while let kb = strs.next() { keys.append(String(decoding: kb, as: UTF8.self)) }
        corvid_value_free(out)
        try checkKeys(s, keys, expected)
        return
    case "PUTMANY", "PUTMANY_ROLLBACK":
        try s.check(a.count % 2 == 0, "PUTMANY wants key/literal pairs")
        let count = a.count / 2
        let keys = (0..<count).map { Data(a[2 * $0].utf8) }
        let docsLit = try (0..<count).map { try lit(a[2 * $0 + 1]) }
        let r = Result<Any?, Error> { try s.docs().putMany(keys: keys, docs: docsLit) }
        if op == "PUTMANY_ROLLBACK" { try s.expectErr(r, errToken(expected)) } else { try s.expectOk(r) }
        return
    case "INSERT_AUTO":
        let key = try Result { try s.docs().insertAuto(try lit(a[0])) }.get()
        try s.check(key.count == 20, "auto key length \(key.count), want 20")
        var id: Int64 = 0
        for b in key {
            try s.check(b >= 48 && b <= 57, "auto key not zero-padded digits")
            id = id * 10 + Int64(b - 48)
        }
        try s.check(s.lastAutoId == 0 || id > s.lastAutoId,
                    "auto id \(id) not monotonic (previous \(s.lastAutoId))")
        s.lastAutoId = id
        return
    case "UPDATE":
        try Result<Any?, Error> {
            try s.docs().update(Data(a[0].utf8)) { current in
                var n = 0
                if let cur = current {
                    guard let m = cur as? [String: Any?] else { throw Marker() }
                    guard let f = m["n"] else { throw Marker() }
                    guard let i = f as? Int else { throw Marker() }
                    n = i
                }
                return ["n": n + 1] as [String: Any?]
            }
        }.get()
        return
    case "UPDATE_ABORT":
        // Both halves of the callback ruling: the thrown marker surfaces
        // at the call site, AND the engine recorded the §1.6 abort (code
        // 12 + message) in the same-thread slot, read immediately after.
        let r = Result<Any?, Error> { try s.docs().update(Data(a[0].utf8)) { _ in throw Marker() } }
        guard case .failure(let thrown) = r else { try s.fail("the marker must surface at the call site") }
        try s.check(thrown is Marker,
                    "the marker error must surface at the call site, got \(thrown)")
        try s.check(corvid_last_error_code().rawValue == CorvidErrorCode.argument.rawValue,
                    "engine must record CORVID_E_ARGUMENT (12) for the aborted update, got \(corvid_last_error_code().rawValue)")
        var len = 0
        guard let msg = corvid_last_error_message(&len), len > 0 else {
            try s.fail("abort code recorded but the message is missing")
        }
        _ = msg
        return
    case "PATCH":
        _ = try Result { try s.docs().patch(Data(a[0].utf8), try lit(a[1])) }.get()
        return
    case "CAS":
        let ex = a[1] == "absent" ? nil : try lit(a[1])
        let re = a[2] == "absent" ? nil : try lit(a[2])
        let applied = try Result { try s.docs().compareAndSet(Data(a[0].utf8), expected: ex, replacement: re) }.get()
        let want = applied ? "applied:1" : "applied:0"
        try s.check(expected == want, "CAS applied=\(applied), want \(expected)")
        return
    case "DELETE":
        let existed = try Result { try s.docs().delete(Data(a[0].utf8)) }.get()
        let want = existed ? "existed:1" : "existed:0"
        try s.check(expected == want, "delete existed=\(existed), want \(expected)")
        return
    case "DELETE_WHERE":
        let removed = try Result { try s.docs().deleteWhere(fieldCmp(s, a[0], a[1], try lit(a[2]))) }.get()
        try s.check(expected == "removed:\(removed)", "removed \(removed), want \(expected)")
        return
    case "DELETE_IN":
        let vals = try a.dropFirst().map { try lit($0) }
        let removed = try Result { try s.docs().deleteWhere(field(a[0]).isIn(vals)) }.get()
        try s.check(expected == "removed:\(removed)", "removed \(removed), want \(expected)")
        return
    case "DELETE_BATCH":
        let removed = try Result { try s.docs().deleteBatch(a.map { Data($0.utf8) }) }.get()
        try s.check(expected == "removed:\(removed)", "removed \(removed), want \(expected)")
        return
    case "INSERT_TTL":
        _ = try Result { try s.docs().insertWithTTL(Data(a[0].utf8), try lit(a[1]), expiresAt: try parseI64(a[2])) }.get()
        return
    case "GET_TTL":
        let at = try Result { try s.docs().getTTL(Data(a[0].utf8)) }.get()
        let got = at.map { "ttl:\($0)" } ?? "nottl"
        try s.check(expected == got, "ttl \(got), want \(expected)")
        return
    case "SET_TTL":
        _ = try Result { try s.docs().setTTL(Data(a[0].utf8), expiresAt: try parseI64(a[1])) }.get()
        return
    case "PURGE":
        let purged = try Result { try s.docs().purgeExpired(try parseI64(a[0])) }.get()
        try s.check(expected == "purged:\(purged)", "purged \(purged), want \(expected)")
        return
    case "SCAN", "SCAN_STOP":
        let stop = op == "SCAN_STOP" ? try parseInt(a[0]) : 0
        var count = 0
        _ = try Result<Any?, Error> {
            try s.docs().scan { _, _ in
                count += 1
                return stop <= 0 || count < stop
            }
        }.get()
        try expectNum(s, expected, count)
        return
    case "PAGE":
        let after = a[0] == "-" ? nil : Data(a[0].utf8)
        let page = try Result { try s.docs().page(after: after, limit: try parseInt(a[1])) }.get()
        try checkKeys(s, rowKeys(materialize(page.rows)), keyPart(expected))
        let sp = suffixPart(expected)
        let want = page.nextAfter == nil ? "|end" : "|more"
        try s.check(sp == want,
                    "page cursor \(page.nextAfter == nil ? "end" : "more"), want \(sp)")
        return
    default: break
    }

    // ---- predicates + queries ----
    switch op {
    case "QF_COUNT":
        try expectNum(s, expected, try filteredCount(s, fieldCmp(s, a[0], a[1], try lit(a[2])))); return
    case "QF_EXISTS":
        try expectNum(s, expected, try filteredCount(s, field(a[0]).exists())); return
    case "QF_BETWEEN":
        try expectNum(s, expected, try filteredCount(s, field(a[0]).between(try lit(a[1]), try lit(a[2]))))
        return
    case "QF_STARTS", "QF_CONTAINS":
        let body = try textBody(s, a[1])
        let p = op == "QF_STARTS" ? try field(a[0]).startsWith(body) : try field(a[0]).contains(body)
        try expectNum(s, expected, try filteredCount(s, p))
        return
    case "QF_GEO":
        try expectNum(s, expected, try filteredCount(s, field(a[0]).geoWithin(
            lat: try parseDouble(a[1]), lon: try parseDouble(a[2]), radiusKm: try parseDouble(a[3]))))
        return
    case "QF_AND", "QF_OR":
        let l = try fieldCmp(s, a[0], a[1], try lit(a[2]))
        let r = try fieldCmp(s, a[3], a[4], try lit(a[5]))
        try expectNum(s, expected, try filteredCount(s, op == "QF_AND" ? try l.and(r) : try l.or(r)))
        return
    case "QF_NOT":
        try expectNum(s, expected, try filteredCount(s, try fieldCmp(s, a[0], a[1], try lit(a[2])).not()))
        return
    case "PRED_FREE":
        try fieldCmp(s, a[0], a[1], try lit(a[2])).close() // never-consumed-root free
        return
    case "Q_ABANDON":
        try s.docs().query().close() // abandoned-builder free path
        return
    case "QVEC", "APPROX":
        let q = try s.docs().query()
        if op == "APPROX" { _ = try q.approx() }
        let rows = materialize(try Result {
            try q.vector(a[0], try lit(a[1]) as! [Float], k: try parseInt(a[2]), metric: .cosine).run()
        }.get())
        try checkKeys(s, rowKeys(rows), keyPart(expected))
        try checkScores(s, rowScores(rows), suffixPart(expected))
        return
    case "QTEXT":
        let rows = materialize(try Result {
            try s.docs().query().text(a[0], try textBody(s, a[1]), k: try parseInt(a[2])).run()
        }.get())
        try checkKeys(s, rowKeys(rows), expected)
        return
    case "PHRASE", "PHRASE_K0":
        let rows = materialize(try Result {
            try s.docs().phraseSearch(field: a[0], phrase: try textBody(s, a[1]), k: try parseInt(a[2]))
        }.get())
        try checkKeys(s, rowKeys(rows), keyPart(expected))
        try checkScores(s, rowScores(rows), suffixPart(expected))
        if op == "PHRASE_K0" { try s.check(rows.isEmpty, "k == 0 must answer an empty cursor") }
        return
    case "HYBRID", "HYBRID_F":
        let tagged = op == "HYBRID_F"
        let vk = try parseInt(a[2])
        let tk = try parseInt(a[5])
        let limitIdx = tagged ? 7 : 6
        let filter = tagged ? try field("tag").eq(try lit(a[6])) : try field("kind").eq("doc")
        let rows = materialize(try Result { () throws -> Rows in
            let iter = try s.docs().query()
                .filter(filter)
                .vector(a[0], try lit(a[1]) as! [Float], k: vk, metric: .cosine)
                .text(a[3], try textBody(s, a[4]), k: tk)
                .fuseRRF(k: 60)
                .rerankMMR(lambda: 1)
                .limit(n: try parseInt(a[limitIdx]))
                .run()
            return iter
        }.get())
        try checkKeys(s, rowKeys(rows), keyPart(expected))
        try checkScores(s, rowScores(rows), suffixPart(expected))
        return
    case "ORDER_BY":
        let rows = materialize(try Result {
            try s.docs().query()
                .orderBy(a[0], descending: try parseInt(a[1]) != 0)
                .offset(n: try parseInt(a[2]))
                .limit(n: try parseInt(a[3]))
                .run()
        }.get())
        try checkKeys(s, rowKeys(rows), expected)
        return
    case "SELECT":
        try s.check(a[0].count >= 2 && a[0].first == "(" && a[0].last == ")",
                    "SELECT's first arg must be a (field,...) group, got \(a[0])")
        let fields = splitTop(String(a[0].dropFirst().dropLast()))
        let rows = Array(try Result { try s.docs().query().select(fields).run() }.get())
        let wantKey = try listBody(s, a[1])
        var doc: Any? = nil
        var found = false
        for r in rows where String(decoding: r.key, as: UTF8.self) == wantKey {
            doc = r.doc
            found = true
        }
        try s.check(found, "row \(wantKey) not in the result")
        try checkValue(s, doc, expected)
        return
    case "AGG_COUNT":
        try expectNum(s, expected, try Result { try s.docs().query().count() }.get()); return
    case "AGG_DISTINCT":
        try expectNum(s, expected, try Result { try s.docs().query().countDistinct(a[0]) }.get()); return
    case "AGG_SUM":
        let sum = try Result { try s.docs().query().sum(a[0]) }.get()
        try s.check(try doubleMatches(sum, expected), "sum \(sum) vs \(expected)")
        return
    case "AGG_AVG":
        let avg = try Result { try s.docs().query().avg(a[0]) }.get()
        if expected == "none" { try s.check(avg == nil, "avg \(String(describing: avg)), want none") }
        else {
            try s.check(avg != nil, "avg null, want \(expected)")
            try s.check(try doubleMatches(avg!, expected), "avg \(avg!) vs \(expected)")
        }
        return
    case "AGG_MIN", "AGG_MAX":
        let out = try Result<Any?, Error> {
            op == "AGG_MIN" ? try s.docs().query().min(a[0]) : try s.docs().query().max(a[0])
        }.get()
        if expected == "absent" { try s.check(out == nil, "expected absence") }
        else {
            try s.check(out != nil, "expected a value, got absence")
            try checkValue(s, out, expected)
        }
        return
    case "AGG_GCOUNT", "AGG_GSUM", "AGG_GAVG":
        let groups = try Result<Any?, Error> {
            switch op {
            case "AGG_GCOUNT": return Array(try s.docs().query().groupCount(a[0]))
            case "AGG_GSUM": return Array(try s.docs().query().groupSum(a[0], a[1]))
            default: return Array(try s.docs().query().groupAvg(a[0], a[1]))
            }
        }.get() as! [Group]
        // §7 inert rule exercised once with a NULL handle.
        var p: UnsafePointer<CChar>? = nil
        var l = 0
        var d = 0.0
        try s.check(corvid_groupiter_next(nil, &p, &l, &d) == 0, "NULL-handle groupiter_next must answer 0")
        try s.check(expected.count >= 3 && expected.first == "g" && expected.dropFirst().first == "("
            && expected.last == ")",
            "group expectation must be g(...), got \(expected)")
        let body = String(expected.dropFirst(2).dropLast())
        let pairs = body.isEmpty ? [] : splitTop(body)
        try s.check(groups.count == pairs.count, "group count \(groups.count), expected \(pairs.count)")
        for i in pairs.indices {
            guard let eq = pairs[i].lastIndex(of: "="), eq > pairs[i].startIndex else {
                try s.fail("group pair needs key=val, got \(pairs[i])")
            }
            let key = String(pairs[i][..<eq])
            let vtok = String(pairs[i][pairs[i].index(after: eq)...])
            try s.check(groups[i].key == key, "group key \(groups[i].key), want \(key)")
            try s.check(try doubleMatches(groups[i].value, vtok), "group \(key) value \(groups[i].value) vs \(vtok)")
        }
        return
    default: break
    }

    // ---- graph ----
    switch op {
    case "LINK":
        _ = try Result { try s.docs().link(Data(a[0].utf8), a[1], Data(a[2].utf8)) }.get(); return
    case "LINK_W":
        _ = try Result {
            try s.docs().linkWeighted(Data(a[0].utf8), a[1], Data(a[2].utf8), weight: try parseDouble(a[3]))
        }.get()
        return
    case "UNLINK":
        let removed = try Result { try s.docs().unlink(Data(a[0].utf8), a[1], Data(a[2].utf8)) }.get()
        let want = removed ? "removed:1" : "removed:0"
        try s.check(expected == want, "unlink removed=\(removed), want \(expected)")
        return
    case "NEIGHBORS", "IN_NEIGHBORS":
        let keys = try Result<Any?, Error> {
            op == "NEIGHBORS"
                ? Array(try s.docs().neighbors(Data(a[0].utf8), a[1]))
                : Array(try s.docs().inNeighbors(Data(a[0].utf8), a[1]))
        }.get() as! [Data]
        try checkKeys(s, bytesKeys(keys), expected)
        return
    case "NEIGHBORS_W":
        let weighted = try Result { try s.docs().neighborsWeighted(Data(a[0].utf8), a[1]) }.get()
        try s.check(expected.count >= 3 && expected.first == "g" && expected.dropFirst().first == "("
            && expected.last == ")",
            "weighted expectation must be g(...), got \(expected)")
        let body = String(expected.dropFirst(2).dropLast())
        let pairs = body.isEmpty ? [] : splitTop(body)
        try s.check(weighted.count == pairs.count, "weighted hits \(weighted.count), expected \(pairs.count)")
        for i in pairs.indices {
            guard let eq = pairs[i].lastIndex(of: "="), eq > pairs[i].startIndex else {
                try s.fail("weighted pair needs key=val, got \(pairs[i])")
            }
            let key = String(pairs[i][..<eq])
            let vtok = String(pairs[i][pairs[i].index(after: eq)...])
            try s.check(String(decoding: weighted[i].key, as: UTF8.self) == key,
                        "weighted key \(String(decoding: weighted[i].key, as: UTF8.self)), want \(key)")
            try s.check(try doubleMatches(weighted[i].weight, vtok), "weight of \(key) \(weighted[i].weight) vs \(vtok)")
        }
        return
    case "TRAVERSE":
        let keys = try Result {
            Array(try s.docs().traverse(Data(a[0].utf8), a[1], hops: try parseInt(a[2])))
        }.get()
        try checkKeys(s, bytesKeys(keys), expected)
        return
    default: break
    }

    // ---- geo ----
    switch op {
    case "GINSERT", "GINSERT_M":
        let loc: Any? = op == "GINSERT_M"
            ? ["lat": try parseDouble(a[1]), "lon": try parseDouble(a[2])] as [String: Any?]
            : [try parseDouble(a[1]), try parseDouble(a[2])] as [Any?]
        _ = try Result { try s.docs().insert(Data(a[0].utf8), ["loc": loc]) }.get()
        return
    case "RADIUS", "NEAREST", "BBOX":
        let hits = Array(try Result<Any?, Error> {
            switch op {
            case "RADIUS": return try s.docs().geoWithinRadius(a[0], lat: try parseDouble(a[1]),
                                                               lon: try parseDouble(a[2]), radiusKm: try parseDouble(a[3]))
            case "NEAREST": return try s.docs().geoNearest(a[0], lat: try parseDouble(a[1]),
                                                           lon: try parseDouble(a[2]), k: try parseInt(a[3]))
            default: return try s.docs().geoWithinBBox(a[0], minLat: try parseDouble(a[1]), minLon: try parseDouble(a[2]),
                                                       maxLat: try parseDouble(a[3]), maxLon: try parseDouble(a[4]))
            }
        }.get() as! GeoHits)
        try checkKeys(s, hits.map { String(decoding: $0.key, as: UTF8.self) }, keyPart(expected))
        let sp = suffixPart(expected)
        if !sp.isEmpty {
            try s.check(sp.first == "|", "geo suffix must start with |, got \(sp)")
            let body = String(sp.dropFirst())
            let toks = body.isEmpty ? [] : splitTop(body)
            try s.check(hits.count == toks.count, "distance count \(hits.count), expected \(toks.count)")
            for i in toks.indices {
                try s.check(try doubleMatches(hits[i].distanceKm, toks[i]),
                            "hit \(i) distance \(hits[i].distanceKm) vs \(toks[i])")
            }
        }
        return
    case "BBOX_ERR":
        let r = Result<Any?, Error> {
            try s.docs().geoWithinBBox(a[0], minLat: try parseDouble(a[1]), minLon: try parseDouble(a[2]),
                                       maxLat: try parseDouble(a[3]), maxLon: try parseDouble(a[4]))
        }
        try s.expectErr(r, errToken(expected))
        return
    default: break
    }

    // ---- schema & indexes ----
    switch op {
    case "SET_SCHEMA":
        let defs = try splitTop(args).map { spec -> FieldDef in
            let part = spec.split(separator: "#").map(String.init)
            try s.check(part.count == 4, "field spec needs name#type#required#unique, got \(spec)")
            return FieldDef(name: part[0], type: try parseFieldType(s, part[1]),
                            required: part[2] == "1", unique: part[3] == "1")
        }
        _ = try Result { try s.docs().setSchema(defs) }.get()
        return
    case "SCHEMA":
        let tn: [FieldType: String] = [.any: "any", .bool: "bool", .int: "int", .float: "float",
                                       .text: "text", .bytes: "bytes", .vector: "vector",
                                       .array: "array", .map: "map"]
        let defs = try Result { try s.docs().schema() }.get()
        try s.check(defs != nil, "a schema must be declared first")
        let got = defs!.map { f in
            "\(f.name)/\(tn[f.type]!)/\(f.required ? 1 : 0)/\(f.unique ? 1 : 0)"
        }.joined(separator: ",")
        try s.check(expected == got, "schema \(got), want \(expected)")
        return
    case "SCHEMA9":
        let names = ["f_any", "f_bool", "f_int", "f_float", "f_text",
                     "f_bytes", "f_vector", "f_array", "f_map"]
        let types: [FieldType] = [.any, .bool, .int, .float, .text, .bytes, .vector, .array, .map]
        let defs = names.indices.map { i in FieldDef(name: names[i], type: types[i], required: i == 1, unique: i == 8) }
        _ = try Result { try s.docs().setSchema(defs) }.get()
        let got = try Result { try s.docs().schema() }.get()
        try s.check(got != nil, "the 9-field schema must be declared")
        var tags: [String] = []
        for (i, f) in got!.enumerated() {
            try s.check(i < 9 && f.type == types[i] && f.name == names[i], "field \(i) did not round-trip")
            tags.append(String(f.type.rawValue))
        }
        try s.check(got!.count == 9, "expected exactly 9 fields, saw \(got!.count)")
        let joined = tags.joined(separator: ",")
        try s.check(expected == joined, "schema9 \(joined), want \(expected)")
        return
    case "SCHEMA_ERR":
        let r = Result<Any?, Error> { try s.docs().insert(Data(a[0].utf8), try lit(a[1])) }
        try s.expectErr(r, errToken(expected))
        return
    case "IDX_SCALAR": _ = try Result { try s.docs().createScalarIndex(a[0]) }.get(); return
    case "IDX_COMPOUND": _ = try Result { try s.docs().createCompoundIndex(splitTop(args)) }.get(); return
    case "IDX_TEXT": _ = try Result { try s.docs().createTextIndex(a[0]) }.get(); return
    case "IDX_TEXT_DISK": _ = try Result { try s.docs().createTextIndexOnDisk(a[0]) }.get(); return
    case "IDX_GEO": _ = try Result { try s.docs().createGeoIndex(a[0]) }.get(); return
    case "IDX_VEC": _ = try Result { try s.docs().createVectorIndex(a[0], metric: try parseMetric(s, a[1])) }.get(); return
    case "IDX_VEC_Q":
        _ = try Result { try s.docs().createVectorIndexQuantized(a[0], metric: try parseMetric(s, a[1]),
                                                                 quant: try parseQuant(s, a[2])) }.get()
        return
    case "IDX_VEC_DISK":
        _ = try Result { try s.docs().createVectorIndexOnDisk(a[0], metric: try parseMetric(s, a[1])) }.get()
        return
    case "IDX_VEC_DISK_Q":
        _ = try Result { try s.docs().createVectorIndexOnDiskQuantized(a[0], metric: try parseMetric(s, a[1]),
                                                                       quant: try parseQuant(s, a[2])) }.get()
        return
    case "IDX_PQ", "IDX_PQ_DISK", "IDX_PQ_ERR":
        let r = Result<Any?, Error> {
            if op == "IDX_PQ_DISK" {
                try s.docs().createVectorIndexOnDiskPQ(a[0], metric: try parseMetric(s, a[1]),
                                                       m: try parseInt(a[2]), k: try parseInt(a[3]))
            } else {
                try s.docs().createVectorIndexPQ(a[0], metric: try parseMetric(s, a[1]),
                                                 m: try parseInt(a[2]), k: try parseInt(a[3]))
            }
        }
        if op == "IDX_PQ_ERR" { try s.expectErr(r, errToken(expected)) } else { try s.expectOk(r) }
        return
    default: break
    }

    // ---- admin & persistence ----
    switch op {
    case "FILEDB": try s.openFile(s.dbPath); return
    case "FILEDB2": try s.openFile(s.db2Path); return
    case "DUMP": _ = try Result { try s.db!.dumpToPath(s.dumpPath.path) }.get(); return
    case "LOAD": _ = try Result { try s.db!.loadFromPath(s.dumpPath.path) }.get(); return
    case "LOAD_RENAMES":
        let r = Result<Any?, Error> { try s.db!.loadFromPathWithRenames(s.dumpPath.path, [a[0]: a[1]]) }
        if expected.hasPrefix("err:") { try s.expectErr(r, errToken(expected)) } else { try s.expectOk(r) }
        return
    case "COLLECTIONS":
        let names = try Result { try s.db!.collections() }.get()
        try checkKeys(s, names, expected)
        return
    case "BACKUP": _ = try Result { try s.db!.backup(toPath: s.backupPath.path) }.get(); return
    case "BACKUP_DUP":
        let r = Result<Any?, Error> { try s.db!.backup(toPath: s.backupPath.path) }
        try s.expectErr(r, .backupTargetExists)
        return
    case "COMPACT_BUSY":
        // Derived handles still open (docs()): the quiescence gate.
        let r = Result<Any?, Error> { try s.db!.compact() }
        try s.expectErr(r, .busy)
        return
    case "COMPACT":
        s.closeColl() // quiesce: the derived-handle gate
        _ = try Result { try s.db!.compact() }.get()
        _ = try s.docs() // re-acquire for subsequent lines
        return
    case "REOPEN":
        try s.closeDb()
        s.db = try Result { try Corvid.open(s.dbPath.path) }.get()
        _ = try s.docs()
        return
    default: break
    }

    try s.fail("unknown OP \(op)")
}

// ---------------------------------------------------------------------------
// Fixture-file driver
// ---------------------------------------------------------------------------

// values.txt runs against no db; every other file starts in-memory
// (admin/persist switch to file dbs via their OPs).
private func startsWithDb(_ path: String) -> Bool {
    !path.hasSuffix("/values.txt") && !path.hasSuffix("values.txt") || !path.contains("values.txt")
}

private func runFixture(_ name: String) throws {
    let path = "golden/\(name).txt"
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvid-swift-golden-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Scenario(file: path, workdir: dir)
    if startsWithDb(path) { try s.openMemory() }

    defer { s.closeDb() }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    // `lines` is counted in an INDEPENDENT pre-scan, so a dispatch loop
    // that skips a counted line diverges from `executed` below.
    var counted = 0
    for raw in lines {
        let trimmed = raw.drop { $0 == " " || $0 == "\r" }
        if !trimmed.isEmpty && trimmed.first != "#" { counted += 1 }
    }

    var executed = 0
    for raw in lines {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty || line.first == "#" { continue }
        s.line = executed + 1
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let op = parts[0]
        let args = parts.count >= 2 ? parts[1] : ""
        let expected = parts.count >= 3 ? parts[2] : ""
        s.op = op
        do {
            try runLine(s, op, args, expected)
        } catch let e as GoldenFailure {
            throw GoldenFailure(message: "\(e.message) (at \(name) line \(s.line))")
        }
        executed += 1
    }

    if executed != counted {
        try s.fail("dispatched \(executed) of \(counted) counted executable lines")
    }
    print("SMOKE \(path) lines=\(counted) executed=\(executed)")
}

// The suite: every fixture, one test each — the same 267 executable
// lines at the pinned engine tag, vendored byte-identical under golden/.
@Suite struct GoldenTest {
    @Test func values() throws { try runFixture("values") }
    @Test func mutations() throws { try runFixture("mutations") }
    @Test func queries() throws { try runFixture("queries") }
    @Test func schema() throws { try runFixture("schema") }
    @Test func geo() throws { try runFixture("geo") }
    @Test func graph() throws { try runFixture("graph") }
    @Test func admin() throws { try runFixture("admin") }
    @Test func persist() throws { try runFixture("persist") }
}
