// Types.swift — the enums and result shapes of the public API, mirroring
// the frozen FFI.md §1.4 enums and the §4.6/§4.7/§4.12 outputs, plus
// the five single-pass cursor Sequences the ABI hands out (FFI.md §2).
//
// Cursors (Rows, GroupIter, Strs, GeoHits, SchemaIterator) are
// single-pass: `makeIterator()` returns the cursor itself, so a second
// iteration sees exhaustion (the materialized list is consumed, not
// reset). They are NOT Sendable (FFI.md §6: single-threaded use); deinit
// calls the one right `_free`, and every borrowed row/key/document is
// copied inside `next()`, before the cursor advances again — nothing
// borrowed outlives the call that observed it.
import CorvidEngine
import Foundation

/// The distance metric (corvid_metric).
public enum Metric: UInt32, Sendable {
    /// Cosine distance `1 - cos_sim` in `[0,2]`; zero-norm = maximally
    /// distant.
    case cosine = 0
    /// Negated dot product (larger dot sorts first).
    case dot = 1
    /// Squared Euclidean (monotonic with L2).
    case l2 = 2
}

/// The stored-vector quantization mode (corvid_quant).
public enum Quant: UInt32, Sendable {
    /// Full f32 precision (`dim * 4` bytes/vector).
    case none = 0
    /// One bit per dimension (sign), Hamming; ~32x smaller.
    case binary = 1
    /// 8-bit per-vector min+scale; ~4x smaller.
    case scalar = 2
}

/// The comparison operator (corvid_cmp) — `FieldExpr`'s eq/ne/lt/le/gt/ge
/// builders over engine-side `Predicate::Compare`.
public enum Cmp: UInt32, Sendable {
    /// Equal (numeric Int/Float interop, else structural).
    case eq = 0
    /// Not equal.
    case ne = 1
    /// Less than (numbers/text only).
    case lt = 2
    /// Less or equal.
    case le = 3
    /// Greater than.
    case gt = 4
    /// Greater or equal.
    case ge = 5
}

/// The declared type of a schema field (corvid_field_type).
public enum FieldType: UInt32, Sendable {
    /// Any value accepted.
    case any = 0
    case bool = 1
    case int = 2
    case float = 3
    case text = 4
    case bytes = 5
    case vector = 6
    case array = 7
    case map = 8
}

/// The value discriminant (corvid_value_type_t) — the decode dispatch
/// tag.
public enum ValueType: UInt32, Sendable {
    case null = 0
    case bool = 1
    case int = 2
    case float = 3
    case text = 4
    case bytes = 5
    case array = 6
    case map = 7
    case vector = 8
}

/// One declared schema field.
public struct FieldDef {
    public let name: String
    public let type: FieldType
    /// The field must be present and non-null on every write.
    public let required: Bool
    /// No two documents may share this field's value.
    public let unique: Bool

    public init(name: String, type: FieldType, required: Bool = false, unique: Bool = false) {
        self.name = name
        self.type = type
        self.required = required
        self.unique = unique
    }
}

/// A query result row: the document key, the (projected) document, and
/// the ranking score — the fused RRF score for builder queries and page
/// rows (0.0 for pure filter/order queries), the BM25 phrase sum for
/// `phraseSearch` rows (its own scale).
public struct Row {
    public let key: Data
    public let doc: Any?
    public let score: Float

    public init(key: Data, doc: Any?, score: Float) {
        self.key = key
        self.doc = doc
        self.score = score
    }
}

/// A `(group key, aggregate)` pair, in ascending group-key order. Group
/// keys use the engine's canonical tagged form (text bare; `i:`/`f:`/`b:`
/// tags; `t:` escaping for ambiguous texts).
public struct Group {
    public let key: String
    public let value: Double

    public init(key: String, value: Double) {
        self.key = key
        self.value = value
    }
}

/// A geo hit: the document key, kilometres from the query point (the 0.0
/// sentinel for bbox queries), and the full document (nil on
/// `neighborsWeighted` cursors — those carry no document).
public struct GeoHit {
    public let key: Data
    public let distanceKm: Double
    public let doc: Any?

    public init(key: Data, distanceKm: Double, doc: Any?) {
        self.key = key
        self.distanceKm = distanceKm
        self.doc = doc
    }
}

/// A weighted graph edge target: `weight` is 1.0 for unweighted links.
public struct WeightedEdge {
    public let key: Data
    public let weight: Double

    public init(key: Data, weight: Double) {
        self.key = key
        self.weight = weight
    }
}

/// One keyset page: the rows and the resume cursor (nil at the end).
/// Feed `nextAfter` back to advance the walk — any length, including
/// zero, is an exclusive continuation, never a restart (FFI.md §4.9).
public struct Page {
    public let rows: Rows
    public let nextAfter: Data?

    public init(rows: Rows, nextAfter: Data?) {
        self.rows = rows
        self.nextAfter = nextAfter
    }
}

// ---- the five single-pass cursor Sequences (FFI.md §2/§6) ----

/// The `(key, document, score)` cursor of `query().run()`,
/// `phraseSearch`, and `page` (FFI.md §4.6/§4.9). Single-pass Sequence.
public final class Rows: Sequence, IteratorProtocol {
    let handle: OpaquePointer

    init(_ h: OpaquePointer) { handle = h }

    public typealias Element = Row

    /// Advances and returns the next row (key and document copied inside
    /// this call), or nil at exhaustion.
    public func next() -> Row? {
        var keyPtr: UnsafePointer<UInt8>? = nil
        var keyLen: Int = 0
        var doc: OpaquePointer? = nil
        var score: Float = 0
        guard corvid_rows_next(handle, &keyPtr, &keyLen, &doc, &score) == 1,
            let keyPtr
        else { return nil }
        return Row(
            key: Data(bytes: UnsafeRawPointer(keyPtr), count: keyLen),
            doc: Values.decodeIfPresent(doc),
            score: score)
    }

    public func makeIterator() -> Rows { self }

    deinit { corvid_rows_free(handle) }
}

/// The string cursor of `collections`, `neighbors`, `inNeighbors`, and
/// `traverse` (FFI.md §4.12). Elements are the raw bytes (`Data`) —
/// graph endpoints are document keys and may be arbitrary bytes (FFI.md
/// §2's erratum); `Db.collections()` decodes them as UTF-8 names.
/// Single-pass Sequence.
public final class Strs: Sequence, IteratorProtocol {
    let handle: OpaquePointer

    init(_ h: OpaquePointer) { handle = h }

    public typealias Element = Data

    public func next() -> Data? {
        var ptr: UnsafePointer<CChar>? = nil
        var len: Int = 0
        guard corvid_strs_next(handle, &ptr, &len) == 1, let ptr else { return nil }
        return Data(bytes: UnsafeRawPointer(ptr), count: len)
    }

    public func makeIterator() -> Strs { self }

    deinit { corvid_strs_free(handle) }
}

/// The geo-hit cursor of the three geo queries (FFI.md §4.12): nearest
/// first for radius/nearest, key order for bbox. Single-pass Sequence;
/// key and document are copied inside `next()`.
public final class GeoHits: Sequence, IteratorProtocol {
    let handle: OpaquePointer

    init(_ h: OpaquePointer) { handle = h }

    public typealias Element = GeoHit

    public func next() -> GeoHit? {
        var hit = corvid_geohit(key: nil, key_len: 0, distance_km: 0)
        var doc: OpaquePointer? = nil
        guard corvid_geohits_next(handle, &hit, &doc) == 1, let keyPtr = hit.key else { return nil }
        return GeoHit(
            key: Data(bytes: UnsafeRawPointer(keyPtr), count: hit.key_len),
            distanceKm: hit.distance_km,
            doc: Values.decodeIfPresent(doc))
    }

    public func makeIterator() -> GeoHits { self }

    deinit { corvid_geohits_free(handle) }
}

/// The `(group key, aggregate)` cursor of the grouped aggregates
/// (FFI.md §4.7), ascending group-key order. Single-pass Sequence; the
/// key bytes are copied inside `next()`.
public final class GroupIter: Sequence, IteratorProtocol {
    let handle: OpaquePointer

    init(_ h: OpaquePointer) { handle = h }

    public typealias Element = Group

    public func next() -> Group? {
        var ptr: UnsafePointer<CChar>? = nil
        var len: Int = 0
        var value: Double = 0
        guard corvid_groupiter_next(handle, &ptr, &len, &value) == 1, let ptr else { return nil }
        return Group(
            key: String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(ptr), count: len), as: UTF8.self),
            value: value)
    }

    public func makeIterator() -> GroupIter { self }

    deinit { corvid_groupiter_free(handle) }
}

/// The declared-schema field cursor of `Collection.schema()`
/// (FFI.md §4.10), declaration order. Single-pass Sequence; the name is
/// copied inside `next()`.
public final class SchemaIterator: Sequence, IteratorProtocol {
    let handle: OpaquePointer

    init(_ h: OpaquePointer) { handle = h }

    public typealias Element = FieldDef

    public func next() -> FieldDef? {
        var def = corvid_field_def(name: nil, name_len: 0, type: CORVID_FIELD_ANY, required: 0, unique: 0)
        guard corvid_schemaiter_next(handle, &def) == 1, let name = def.name else { return nil }
        return FieldDef(
            name: String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(name), count: def.name_len), as: UTF8.self),
            type: FieldType(rawValue: def.type.rawValue) ?? .any,
            required: def.required != 0,
            unique: def.unique != 0)
    }

    public func makeIterator() -> SchemaIterator { self }

    deinit { corvid_schemaiter_free(handle) }
}
