// Values.swift — the Swift-side value mapping over the raw handle layer.
//
// Public API: documents are Swift values mapped per docs/PLAN.md:
//
//   C null  ↔ nil          C bool ↔ Bool      C int ↔ Int
//   C float ↔ Double       C text ↔ String    C bytes ↔ Data
//   C vector ↔ [Float]     C array ↔ [Any?]   C map ↔ [String: Any?]
//
// Encode also accepts the wider literal kinds (UInt by bit pattern,
// Float widened) and throws CorvidError(.argument) for anything else;
// decode always yields the canonical types above. Decoded maps enumerate
// keys through `corvid_value_map_keys`, so a decoded document is always
// COMPLETE, whatever wrote the data. NaN/±inf/-0.0 cross bit-exact.
import CorvidEngine
import Foundation

/// An OWNED `corvid_value*` — the encode/decode workhorse. `array_push`
/// and `map_put` CONSUME their child unconditionally (FFI.md §8): the
/// child wrapper marks itself consumed BEFORE the native call, so a
/// double free cannot happen; deinit frees a never-consumed handle.
final class Value {
    let handle: OpaquePointer
    private var consumed = false

    /// For the constructors the ABI marks infallible (null/bool/int/
    /// float/array_new/map_new).
    init(infallible raw: OpaquePointer?) {
        guard let raw = raw else {
            preconditionFailure("corvid: an infallible value constructor returned NULL")
        }
        handle = raw
    }

    /// For the constructors that can answer NULL + CORVID_E_ARGUMENT
    /// (text/bytes/vector: the NULL/UTF-8 discipline of FFI.md §7).
    init(consuming raw: OpaquePointer?) throws {
        guard let raw = raw else { throw lastError() }
        handle = raw
    }

    func ensureUsable() throws {
        guard !consumed else {
            throw CorvidError(code: .argument, message: "corvid: Value already consumed")
        }
    }

    /// Marks consumed and hands the raw handle to a consuming ABI call —
    /// the consumption is unconditional whatever the call's outcome.
    func take() -> OpaquePointer {
        consumed = true
        return handle
    }

    /// Appends `item` to the array, CONSUMING it (FFI.md §8).
    func push(_ item: Value) throws {
        try ensureUsable()
        try item.ensureUsable()
        try check(corvid_value_array_push(handle, item.take()))
    }

    /// Inserts `val` under `key`, CONSUMING it (FFI.md §8).
    func put(_ key: UnsafePointer<CChar>, _ keyLen: Int, _ val: Value) throws {
        try ensureUsable()
        try val.ensureUsable()
        try check(corvid_value_map_put(handle, key, keyLen, val.take()))
    }

    /// Frees a never-consumed handle (idempotent).
    func destroy() {
        if !consumed {
            consumed = true
            corvid_value_free(handle)
        }
    }

    deinit { destroy() }
}

enum Values {

    /// The engine's decode bound — corvid::value::MAX_NESTING (128).
    /// Converter-accepted == decodable: a value deeper than this could
    /// be BUILT through the constructor ABI but the engine could never
    /// decode it back (dump/load), so encode rejects it up front.
    static let maxNesting = 128

    // ---- wire discipline: REAL UTF-8/bytes, never NUL assumptions ----

    /// Borrows `s` as (pointer, length) UTF-8 for the duration of `body`.
    /// The pointer is never NULL (the empty string passes a one-byte
    /// dummy with length 0 — FFI.md §1.5/§7's empty-is-not-NULL rule).
    static func withUTF8<T>(_ s: String, _ body: (UnsafePointer<CChar>, Int) throws -> T) rethrows -> T {
        var bytes = Array(s.utf8)
        let count = bytes.count
        if bytes.isEmpty { bytes = [0] }
        return try bytes.withUnsafeBufferPointer { buf in
            try body(UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: CChar.self), count)
        }
    }

    /// Borrows `d` as (pointer, length) bytes for the duration of `body`;
    /// never NULL (see `withUTF8`).
    static func withBytes<T>(_ d: Data, _ body: (UnsafePointer<UInt8>, Int) throws -> T) rethrows -> T {
        if d.isEmpty {
            return try withUnsafeBytes(of: UInt8(0)) { raw in
                try body(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), 0)
            }
        }
        return try d.withUnsafeBytes { raw in
            try body(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count)
        }
    }

    /// The optional form: nil passes (NULL, 0) — `corvid_page`'s `after`
    /// start form; everything else is the non-nil shape.
    static func withOptionalBytes<T>(_ d: Data?, _ body: (UnsafePointer<UInt8>?, Int) throws -> T) rethrows -> T {
        guard let d = d else { return try body(nil, 0) }
        return try withBytes(d) { p, n in try body(p, n) }
    }

    /// Borrows `v` as (pointer, dim) floats for the duration of `body`;
    /// never NULL at dim 0 (FFI.md §1.5's empty-vector shape).
    static func withFloats<T>(_ v: [Float], _ body: (UnsafePointer<Float>, Int) throws -> T) rethrows -> T {
        var floats = v
        let dim = floats.count
        if floats.isEmpty { floats = [0] }
        return try floats.withUnsafeBufferPointer { buf in
            try body(buf.baseAddress!, dim)
        }
    }

    /// Parallel borrowed (pointers, lens) UTF-8 arrays for the ABI's
    /// string-array parameters; a NULL pair at count 0 (the `pred_in`
    /// array rule). Every pointer is non-NULL, whatever the string.
    static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<Int>?, Int) throws -> T
    ) throws -> T {
        if strings.isEmpty { return try body(nil, nil, 0) }
        var flat: [UInt8] = []
        var spans: [(Int, Int)] = []
        for s in strings {
            let b = Array(s.utf8)
            spans.append((flat.count, b.count))
            flat.append(contentsOf: b)
        }
        if flat.isEmpty { flat = [0] }
        return try flat.withUnsafeBufferPointer { fbuf in
            try spans.withUnsafeBufferPointer { sbuf in
                let ptrs: [UnsafePointer<CChar>?] = sbuf.map { span in
                    UnsafeRawPointer(fbuf.baseAddress! + span.0).assumingMemoryBound(to: CChar.self)
                }
                let lens: [Int] = sbuf.map { $0.1 }
                return try ptrs.withUnsafeBufferPointer { pbuf in
                    try lens.withUnsafeBufferPointer { lbuf in
                        try body(pbuf.baseAddress, lbuf.baseAddress, strings.count)
                    }
                }
            }
        }
    }

    // ---- encode: Swift value → OWNED handle (the §4.3 builder world) ----

    static func encode(_ v: Any?) throws -> Value {
        try encode(v, depth: 0)
    }

    private static func encode(_ v: Any?, depth: Int) throws -> Value {
        if depth > maxNesting {
            throw CorvidError(
                code: .argument,
                message: "corvid: value nesting exceeds the maximum depth of \(maxNesting)")
        }
        if v == nil { return Value(infallible: corvid_value_null()) }
        if let b = v as? Bool { return Value(infallible: corvid_value_bool(b ? 1 : 0)) }
        if let i = v as? Int { return Value(infallible: corvid_value_int(Int64(i))) }
        // UInt maps by bit pattern — the engine's only integer kind is
        // i64, so u64 values above Int64.max round-trip exactly.
        if let u = v as? UInt { return Value(infallible: corvid_value_int(Int64(bitPattern: UInt64(u)))) }
        if let d = v as? Double { return Value(infallible: corvid_value_float(d)) }
        if let f = v as? Float { return Value(infallible: corvid_value_float(Double(f))) }
        if let s = v as? String {
            return try withUTF8(s) { p, n in try Value(consuming: corvid_value_text(p, n)) }
        }
        if let b = v as? Data {
            return try withBytes(b) { p, n in try Value(consuming: corvid_value_bytes(p, n)) }
        }
        if let vec = v as? [Float] {
            return try withFloats(vec) { p, n in try Value(consuming: corvid_value_vector(p, n)) }
        }
        if let arr = v as? [Any?] {
            let out = Value(infallible: corvid_value_array_new())
            for item in arr {
                let child = try encode(item, depth: depth + 1)
                try out.push(child) // consumes child (§8)
            }
            return out
        }
        if let map = v as? [String: Any?] {
            let out = Value(infallible: corvid_value_map_new())
            for (k, item) in map {
                let child = try encode(item, depth: depth + 1)
                try withUTF8(k) { p, n in try out.put(p, n, child) } // consumes child (§8)
            }
            return out
        }
        throw CorvidError(
            code: .argument,
            message: "corvid: unsupported Swift type \(String(describing: Swift.type(of: v))) for a document value")
    }

    // ---- decode: (borrowed or owned) handle → Swift value, a COMPLETE
    //      copy made inside the same call that observed the handle. The
    //      engine guarantees the shapes; the traps below are the
    //      corrupt-store defensive wall (a wrong tag from a correct
    //      engine is impossible by FFI.md §1.4's frozen tags). ----

    /// Decodes an optional handle: nil stays nil (absent / no document);
    /// a present handle decodes (a stored Null also decodes to nil — the
    /// engine's absence/Null conflation, same as every sibling binding).
    /// The explicit shape avoids Optional.map's Any?-to-Any coercion,
    /// which would box a decoded nil into a non-nil slot.
    static func decodeIfPresent(_ h: OpaquePointer?) -> Any? {
        guard h != nil else { return nil }
        return decode(h)
    }

    static func decode(_ h: OpaquePointer?) -> Any? {
        precondition(h != nil, "corvid: decode of a NULL value handle")
        let tag = corvid_value_type(h).rawValue
        switch tag {
        case ValueType.null.rawValue:
            return nil
        case ValueType.bool.rawValue:
            var ok: Int32 = 0
            let v = corvid_value_as_bool(h, &ok)
            precondition(ok == 1, "corvid: bool decode failed")
            return v != 0
        case ValueType.int.rawValue:
            var ok: Int32 = 0
            let v = corvid_value_as_int(h, &ok)
            precondition(ok == 1, "corvid: int decode failed")
            return Int(v)
        case ValueType.float.rawValue:
            var ok: Int32 = 0
            let v = corvid_value_as_float(h, &ok)
            precondition(ok == 1, "corvid: float decode failed")
            return v
        case ValueType.text.rawValue:
            var len: Int = 0
            guard let p = corvid_value_text_ref(h, &len) else { preconditionFailure("corvid: text decode failed") }
            return String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: len), as: UTF8.self)
        case ValueType.bytes.rawValue:
            var len: Int = 0
            guard let p = corvid_value_bytes_ref(h, &len) else { preconditionFailure("corvid: bytes decode failed") }
            return Data(bytes: UnsafeRawPointer(p), count: len)
        case ValueType.vector.rawValue:
            var dim: Int = 0
            guard let p = corvid_value_vector_ref(h, &dim) else { preconditionFailure("corvid: vector decode failed") }
            return [Float](UnsafeBufferPointer(start: p, count: dim))
        case ValueType.array.rawValue:
            let n = corvid_value_len(h)
            var out: [Any?] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                guard let child = corvid_value_array_get(h, i) else {
                    preconditionFailure("corvid: array child decode failed")
                }
                out.append(decode(child))
            }
            return out
        case ValueType.map.rawValue:
            let n = corvid_value_len(h)
            var out: [String: Any?] = [:]
            out.reserveCapacity(n)
            if n > 0 {
                guard let cursor = corvid_value_map_keys(h) else {
                    preconditionFailure("corvid: map keys decode failed")
                }
                let keys = Strs(cursor)
                while let kb = keys.next() {
                    let key = String(decoding: kb, as: UTF8.self)
                    let child = withBytes(kb) { p, n in corvid_value_map_get(h, p, n) }
                    out[key] = decodeIfPresent(child)
                }
            }
            return out
        default:
            preconditionFailure("corvid: unknown value type tag \(tag)")
        }
    }
}

// The frozen §1.4 enums cross as their exact raw values (append-only
// tables — the raw values are always in range).
func ccmp(_ op: Cmp) -> corvid_cmp { corvid_cmp(rawValue: op.rawValue) }
func cmetric(_ m: Metric) -> corvid_metric { corvid_metric(rawValue: m.rawValue) }
func cquant(_ q: Quant) -> corvid_quant { corvid_quant(rawValue: q.rawValue) }
func cfieldtype(_ f: FieldType) -> corvid_field_type { corvid_field_type(rawValue: f.rawValue) }
