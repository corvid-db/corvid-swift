// Predicate.swift — the filter DSL (FFI.md §4.5): field(path) builders
// and and/or/not combinators over engine-side predicate trees.
//
// Consumption (FFI.md §8): and/or/not, Query.filter, and deleteWhere
// CONSUME their children unconditionally — success or failure alike.
// The wrapper marks itself consumed BEFORE the native call and never
// frees twice; using a consumed Predicate throws. Aliasing one predicate
// into both arms of and/or is rejected by the ABI (it consumes the
// shared handle once) and surfaces here as an ordinary error.
import CorvidEngine
import Foundation

public final class Predicate {
    let handle: OpaquePointer
    private var consumed = false

    init(consuming raw: OpaquePointer?) throws {
        guard let raw = raw else { throw lastError() }
        handle = raw
    }

    func ensureUsable() throws {
        guard !consumed else {
            throw CorvidError(code: .argument, message: "corvid: Predicate already consumed or closed")
        }
    }

    /// Marks consumed and hands the raw handle to a consuming ABI call —
    /// the consumption is unconditional whatever the call's outcome.
    func take() -> OpaquePointer {
        consumed = true
        return handle
    }

    /// Logical conjunction — consumes both operands.
    public func and(_ other: Predicate) throws -> Predicate {
        try ensureUsable()
        try other.ensureUsable()
        return try Predicate(consuming: corvid_pred_and(take(), other.take()))
    }

    /// Logical disjunction — consumes both operands.
    public func or(_ other: Predicate) throws -> Predicate {
        try ensureUsable()
        try other.ensureUsable()
        return try Predicate(consuming: corvid_pred_or(take(), other.take()))
    }

    /// Logical negation — consumes this predicate.
    public func not() throws -> Predicate {
        try ensureUsable()
        return try Predicate(consuming: corvid_pred_not(take()))
    }

    /// Free a root that was never consumed — the explicit form the
    /// sibling bindings expose (deinit is equivalent; idempotent).
    public func close() {
        if !consumed {
            consumed = true
            corvid_pred_free(handle)
        }
    }

    deinit {
        if !consumed { corvid_pred_free(handle) }
    }
}

/// The field DSL entry: `field("user.age").gt(30)`. Paths are
/// dot-separated and traverse nested maps ("meta.author"); the empty
/// path resolves nothing (a predicate that matches no document).
public final class FieldExpr {
    let path: String

    init(path: String) { self.path = path }

    private func compare(_ op: Cmp, _ v: Any?) throws -> Predicate {
        let val = try Values.encode(v)
        defer { val.destroy() } // the tree CLONES it (FFI.md §5 rule 3)
        return try Values.withUTF8(path) { p, n in
            try Predicate(consuming: corvid_pred_compare(p, n, ccmp(op), val.handle))
        }
    }

    /// Compares against `v`: a missing path is false; unordered kinds
    /// under ordered ops are false; Int/Float compare numerically across
    /// kinds (exact to 2^53); NaN compares false against everything
    /// except `ne`.
    public func eq(_ v: Any?) throws -> Predicate { try compare(.eq, v) }
    public func ne(_ v: Any?) throws -> Predicate { try compare(.ne, v) }
    public func lt(_ v: Any?) throws -> Predicate { try compare(.lt, v) }
    public func le(_ v: Any?) throws -> Predicate { try compare(.le, v) }
    public func gt(_ v: Any?) throws -> Predicate { try compare(.gt, v) }
    public func ge(_ v: Any?) throws -> Predicate { try compare(.ge, v) }

    /// True when the path resolves to a present value.
    public func exists() throws -> Predicate {
        try Values.withUTF8(path) { p, n in
            try Predicate(consuming: corvid_pred_exists(p, n))
        }
    }

    /// Inclusive `[low, high]` range.
    public func between(_ low: Any?, _ high: Any?) throws -> Predicate {
        let lo = try Values.encode(low)
        defer { lo.destroy() }
        let hi = try Values.encode(high)
        defer { hi.destroy() }
        return try Values.withUTF8(path) { p, n in
            try Predicate(consuming: corvid_pred_between(p, n, lo.handle, hi.handle))
        }
    }

    /// True when the value equals any element of `values` (empty
    /// matches nothing, not an error).
    public func isIn(_ values: [Any?]) throws -> Predicate {
        let encoded = try values.map { try Values.encode($0) }
        defer { encoded.forEach { $0.destroy() } } // each CLONED (§5 rule 3)
        if encoded.isEmpty {
            return try Values.withUTF8(path) { p, n in
                try Predicate(consuming: corvid_pred_in(p, n, nil, 0))
            }
        }
        let handles: [OpaquePointer?] = encoded.map { $0.handle }
        return try Values.withUTF8(path) { p, n in
            try handles.withUnsafeBufferPointer { buf in
                try Predicate(consuming: corvid_pred_in(p, n, buf.baseAddress, values.count))
            }
        }
    }

    /// The text at the path starts with `prefix` (false on non-text
    /// values and missing paths).
    public func startsWith(_ prefix: String) throws -> Predicate {
        try Values.withUTF8(path) { p, n in
            try Values.withUTF8(prefix) { pp, pn in
                try Predicate(consuming: corvid_pred_starts_with(p, n, pp, pn))
            }
        }
    }

    /// The text at the path contains `substr` (false on non-text values
    /// and missing paths).
    public func contains(_ s: String) throws -> Predicate {
        try Values.withUTF8(path) { p, n in
            try Values.withUTF8(s) { sp, sn in
                try Predicate(consuming: corvid_pred_contains(p, n, sp, sn))
            }
        }
    }

    /// The path holds a point (`[lat, lon]` array or `lat`/`lon` map)
    /// within `radiusKm` (INCLUSIVE, haversine) of (lat, lon); false on
    /// non-point values and missing paths. A negative radius matches
    /// nothing (the engine's rule — not an error).
    public func geoWithin(lat: Double, lon: Double, radiusKm: Double) throws -> Predicate {
        try Values.withUTF8(path) { p, n in
            try Predicate(consuming: corvid_pred_geo_within(p, n, lat, lon, radiusKm))
        }
    }
}

/// Start a predicate over a (dot-separated) field path.
public func field(_ path: String) -> FieldExpr { FieldExpr(path: path) }

/// An unambiguous name for [Predicate] — modern SDKs export a generic
/// `Predicate<...>` from Foundation, which collides at any explicit-type
/// use site. Predicates normally flow inferred from [field(_:)], so the
/// collision is rare; when it bites, this alias is the fix.
public typealias CorvidPredicate = Predicate
