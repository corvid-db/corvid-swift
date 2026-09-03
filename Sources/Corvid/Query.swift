// Query.swift — the fluent query builder (FFI.md §4.6/§4.7): sources,
// fusion, paging, projection, the run terminal, and the aggregation
// terminals. Every terminal CONSUMES the builder (FFI.md §8) whatever
// its outcome; a consumed (or closed) builder throws on reuse, and
// deinit frees an abandoned one. Single-threaded object (FFI.md §6).
import CorvidEngine
import Foundation

public final class Query {
    let handle: OpaquePointer
    private var consumed = false

    init(_ h: OpaquePointer) { handle = h }

    private func ensureLive() throws {
        guard !consumed else {
            throw CorvidError(code: .argument, message: "corvid: Query already run, aggregated, or closed")
        }
    }

    /// Marks consumed and hands the raw handle to the consuming terminal
    /// — the consumption is unconditional whatever the call's outcome.
    private func take() -> OpaquePointer {
        consumed = true
        return handle
    }

    // ---- sources & knobs (FFI.md §4.6) — these MUTATE the builder; only
    //      the terminals below consume it ----

    /// Add a filter — consumes the predicate. Multiple calls AND
    /// together.
    @discardableResult
    public func filter(_ pred: Predicate) throws -> Query {
        try ensureLive()
        try pred.ensureUsable()
        try check(corvid_query_filter(handle, pred.take()))
        return self
    }

    /// Add a vector-search source: the `k` nearest documents by `field`
    /// embedding under `metric`.
    @discardableResult
    public func vector(_ field: String, _ query: [Float], k: Int, metric: Metric = .cosine) throws -> Query {
        try ensureLive()
        try Values.withUTF8(field) { fp, fn in
            try Values.withFloats(query) { vp, dim in
                try check(corvid_query_vector(handle, fp, fn, vp, dim, k, cmetric(metric)))
            }
        }
        return self
    }

    /// Add a BM25 text-search source over `field`.
    @discardableResult
    public func text(_ field: String, _ query: String, k: Int) throws -> Query {
        try ensureLive()
        try Values.withUTF8(field) { fp, fn in
            try Values.withUTF8(query) { sp, sn in
                try check(corvid_query_text(handle, fp, fn, sp, sn, k))
            }
        }
        return self
    }

    /// Set the Reciprocal Rank Fusion constant (engine default 60).
    /// Validated at execution: a non-finite or non-positive `k` fails
    /// `run`/aggregates with CorvidError(.argument).
    @discardableResult
    public func fuseRRF(k: Float) throws -> Query {
        try ensureLive()
        try check(corvid_query_fuse_rrf(handle, k))
        return self
    }

    /// Diversify results with Maximal Marginal Relevance. `lambda`
    /// outside [0,1] (NaN included) fails `run`/aggregates with
    /// CorvidError(.argument) at execution. Anchors on the first vector
    /// source; a no-op without one.
    @discardableResult
    public func rerankMMR(lambda: Float) throws -> Query {
        try ensureLive()
        try check(corvid_query_rerank_mmr(handle, lambda))
        return self
    }

    /// Allow approximate execution: a filtered single-vector-source
    /// query may use its ANN index with over-fetch-then-filter.
    @discardableResult
    public func approx() throws -> Query {
        try ensureLive()
        try check(corvid_query_approx(handle))
        return self
    }

    /// Cap the result at `n` rows — `limit 0` yields an empty result,
    /// applied after `offset`.
    @discardableResult
    public func limit(n: Int) throws -> Query {
        try ensureLive()
        try check(corvid_query_limit(handle, n))
        return self
    }

    /// Skip the first `n` rows — applied after ordering, before `limit`.
    @discardableResult
    public func offset(n: Int) throws -> Query {
        try ensureLive()
        try check(corvid_query_offset(handle, n))
        return self
    }

    /// Order by a scalar field instead of by rank (the engine's ordering
    /// contract: comparables first, incomparables after, rows missing
    /// the field last, ties by key; `descending` reverses within-class
    /// order only).
    @discardableResult
    public func orderBy(_ field: String, descending: Bool = false) throws -> Query {
        try ensureLive()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_query_order_by(handle, fp, fn, descending ? 1 : 0))
        }
        return self
    }

    /// Project result documents to these top-level fields (missing
    /// fields are absent; non-map documents pass through unchanged;
    /// ranking still sees the full document). An empty array is the
    /// engine-faithful empty projection.
    @discardableResult
    public func select(_ fields: [String]) throws -> Query {
        try ensureLive()
        try Values.withCStringArray(fields) { ptrs, lens, count in
            try check(corvid_query_select(handle, ptrs, lens, count))
        }
        return self
    }

    // ---- terminals (each CONSUMES the builder, FFI.md §8) ----

    /// Execute — consumes the builder. Returns the rows cursor (empty
    /// for an empty result; failure throws, never an empty cursor). One
    /// MVCC snapshot covers the whole query; the ranking parameters are
    /// validated HERE.
    public func run() throws -> Rows {
        try ensureLive()
        guard let rows = corvid_query_run(take()) else { throw lastError() }
        return Rows(rows)
    }

    /// Count matching documents (O(1) when unfiltered) — consumes.
    public func count() throws -> Int {
        try ensureLive()
        var out: Int = 0
        try check(corvid_query_count(take(), &out))
        return out
    }

    /// Distinct values at `field`, by the canonical group key (missing
    /// and container values ignored) — consumes.
    public func countDistinct(_ field: String) throws -> Int {
        try ensureLive()
        var out: Int = 0
        let st = Values.withUTF8(field) { p, n in corvid_query_count_distinct(take(), p, n, &out) }
        try check(st)
        return out
    }

    /// Sum of the numeric (int/float) values at `field` (all-skipped
    /// sums to 0.0) — consumes.
    public func sum(_ field: String) throws -> Double {
        try ensureLive()
        var out: Double = 0
        let st = Values.withUTF8(field) { p, n in corvid_query_sum(take(), p, n, &out) }
        try check(st)
        return out
    }

    /// Mean of the numeric values at `field`, or nil when none exists —
    /// consumes.
    public func avg(_ field: String) throws -> Double? {
        try ensureLive()
        var out: Double = 0
        var has: Int32 = 0
        let st = Values.withUTF8(field) { p, n in corvid_query_avg(take(), p, n, &out, &has) }
        try check(st)
        return has != 0 ? out : nil
    }

    /// The minimum comparable (numeric or text) value at `field`, or nil
    /// when the filtered set holds none — consumes.
    public func min(_ field: String) throws -> Any? {
        try ensureLive()
        var out: OpaquePointer? = nil
        let st = Values.withUTF8(field) { p, n in corvid_query_min(take(), p, n, &out) }
        try check(st)
        guard let v = out else { return nil }
        defer { corvid_value_free(v) }
        return Values.decode(v)
    }

    /// The maximum comparable value at `field`, or nil when none —
    /// consumes.
    public func max(_ field: String) throws -> Any? {
        try ensureLive()
        var out: OpaquePointer? = nil
        let st = Values.withUTF8(field) { p, n in corvid_query_max(take(), p, n, &out) }
        try check(st)
        guard let v = out else { return nil }
        defer { corvid_value_free(v) }
        return Values.decode(v)
    }

    /// Count grouped by the value at `field`, ascending group-key order —
    /// consumes.
    public func groupCount(_ field: String) throws -> GroupIter {
        try ensureLive()
        let it = Values.withUTF8(field) { p, n in corvid_query_group_count(take(), p, n) }
        guard let it = it else { throw lastError() }
        return GroupIter(it)
    }

    /// Sum of `valueField` grouped by `groupField` (non-numeric or
    /// missing values skipped per row) — consumes.
    public func groupSum(_ groupField: String, _ valueField: String) throws -> GroupIter {
        try ensureLive()
        return try Values.withUTF8(groupField) { gp, gn in
            try Values.withUTF8(valueField) { vp, vn in
                guard let it = corvid_query_group_sum(take(), gp, gn, vp, vn) else { throw lastError() }
                return GroupIter(it)
            }
        }
    }

    /// Mean of `valueField` grouped by `groupField` — consumes.
    public func groupAvg(_ groupField: String, _ valueField: String) throws -> GroupIter {
        try ensureLive()
        return try Values.withUTF8(groupField) { gp, gn in
            try Values.withUTF8(valueField) { vp, vn in
                guard let it = corvid_query_group_avg(take(), gp, gn, vp, vn) else { throw lastError() }
                return GroupIter(it)
            }
        }
    }

    /// Free a builder abandoned without executing. Idempotent; NOT for
    /// use after a terminal (they consumed the handle — FFI.md §8).
    public func close() {
        if !consumed {
            consumed = true
            corvid_query_free(handle)
        }
    }

    deinit { close() }
}
