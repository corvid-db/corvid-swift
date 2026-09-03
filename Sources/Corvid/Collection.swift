// Collection.swift — the collection handle: mutations, reads, TTL,
// graph, geo, indexes, schema, phrase search, and the query entry
// (FFI.md §4.2/§4.8–§4.13). Threading: concurrent-safe like Db (FFI.md
// §6, @unchecked Sendable after the ABI's own contract); close()
// idempotent.
import CorvidEngine
import Foundation

public final class Collection: @unchecked Sendable {
    let handle: OpaquePointer
    private var closed = false

    init(consuming raw: OpaquePointer?) throws {
        Corvid.checkLoaded()
        guard let raw = raw else { throw lastError() }
        handle = raw
    }

    /// The collection's name (round-trips the handle's stored name).
    /// Cannot fail on a live handle (FFI.md §4.2's NULL rule).
    public var name: String {
        var len: Int = 0
        guard let p = corvid_collection_name(handle, &len) else {
            preconditionFailure("corvid: collection name unavailable")
        }
        return String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: len), as: UTF8.self)
    }

    // ---- mutations (FFI.md §4.8) ----

    /// Insert or overwrite the document at `key` — atomic with all index
    /// maintenance and unique checks.
    public func insert(_ key: Data, _ doc: Any?) throws {
        try ensureOpen()
        let v = try Values.encode(doc)
        defer { v.destroy() } // cloned into the engine (FFI.md §5 rule 3)
        try Values.withBytes(key) { p, n in
            try check(corvid_insert(handle, p, n, v.handle))
        }
    }

    /// Single-transaction bulk load: one commit instead of N; the whole
    /// batch rolls back on a schema/unique violation; duplicate keys
    /// inside one batch are last-write-wins.
    public func putMany(keys: [Data], docs: [Any?]) throws {
        try ensureOpen()
        guard keys.count == docs.count else {
            throw CorvidError(
                code: .argument,
                message: "corvid: putMany keys (\(keys.count)) and docs (\(docs.count)) differ in count")
        }
        let encoded = try docs.map { try Values.encode($0) }
        defer { encoded.forEach { $0.destroy() } } // each CLONED (§5 rule 3)
        if keys.isEmpty { // an empty batch is a successful no-op
            try check(corvid_put_many(handle, nil, 0))
            return
        }
        var flat: [UInt8] = []
        var spans: [(Int, Int)] = []
        for k in keys {
            spans.append((flat.count, k.count))
            flat.append(contentsOf: k)
        }
        if flat.isEmpty { flat = [0] } // non-NULL pointers for all-empty keys
        let handles = encoded.map { $0.handle }
        try flat.withUnsafeBufferPointer { fbuf in
            try spans.withUnsafeBufferPointer { sbuf in
                let kvs: [corvid_kv] = (0..<keys.count).map { i in
                    corvid_kv(key: fbuf.baseAddress! + sbuf[i].0, key_len: sbuf[i].1, val: handles[i])
                }
                try kvs.withUnsafeBufferPointer { kvbuf in
                    try check(corvid_put_many(handle, kvbuf.baseAddress, keys.count))
                }
            }
        }
    }

    /// Insert under a fresh, monotonically increasing zero-padded
    /// 20-digit key; returns the key.
    public func insertAuto(_ doc: Any?) throws -> Data {
        try ensureOpen()
        let v = try Values.encode(doc)
        defer { v.destroy() }
        var len: Int = 0
        guard let p = corvid_insert_auto(handle, v.handle, &len) else { throw lastError() }
        defer { corvid_free(UnsafeMutableRawPointer(p)) }
        return Data(bytes: UnsafeRawPointer(p), count: len)
    }

    /// Read-modify-write `key`. The closure receives the current
    /// document (nil when absent — not an error; a stored Null document
    /// also reads as nil, the engine's absence/Null conflation) and
    /// returns the replacement; returning nil DELETES the key; THROWING
    /// aborts (the store stays untouched, the engine records ARGUMENT,
    /// and the closure's own error surfaces here at the call site —
    /// never swallowed, never unwound through C frames).
    ///
    /// Not linearizable against concurrent writers — use
    /// `compareAndSet` when that matters. The closure must not call back
    /// into this db (FFI.md §1.6 reentrancy).
    public func update(_ key: Data, _ body: @escaping (Any?) throws -> Any?) throws {
        try ensureOpen()
        let box = UpdateBox(body)
        let st = Values.withBytes(key) { p, n in
            corvid_update(handle, p, n, { ctx, current, out in
                let box = Unmanaged<UpdateBox>.fromOpaque(ctx!).takeUnretainedValue()
                let cur: Any? = current != nil ? Values.decode(current) : nil
                do {
                    let replacement = try box.body(cur)
                    let encoded = try Values.encode(replacement)
                    out!.pointee = encoded.take() // owned by the engine on the OK return
                    return CORVID_OK
                } catch {
                    box.caught = error
                    return CORVID_ERR // the abort signal: *out stays NULL, nothing consumed
                }
            }, Unmanaged.passUnretained(box).toOpaque())
        }
        if let e = box.caught { throw e }
        try check(st)
    }

    /// Merge `patch`'s top-level fields into the map at `key` (creating
    /// it if absent); a non-map on either side replaces the document.
    public func patch(_ key: Data, _ patch: Any?) throws {
        try ensureOpen()
        let v = try Values.encode(patch)
        defer { v.destroy() }
        try Values.withBytes(key) { p, n in
            try check(corvid_patch(handle, p, n, v.handle))
        }
    }

    /// Atomic conditional write. Nullability is semantic: `expected ==
    /// nil` means "must be absent"; `replacement == nil` means "delete if
    /// it matches" (a stored Null document is not expressible as
    /// `expected` through this binding — every sibling shares the
    /// conflation). Returns whether the compare applied (a failed
    /// compare is NOT an error). Equality is the engine's semantic value
    /// equality (NaN == NaN, -0.0 == 0.0, containers element-wise).
    public func compareAndSet(_ key: Data, expected: Any?, replacement: Any?) throws -> Bool {
        try ensureOpen()
        let exp: Value? = expected == nil ? nil : try Values.encode(expected)
        defer { exp?.destroy() } // borrowed-read (§5 rule 3)
        let rep: Value? = replacement == nil ? nil : try Values.encode(replacement)
        defer { rep?.destroy() }
        var applied: Int32 = 0
        try Values.withBytes(key) { p, n in
            try check(corvid_compare_and_set(handle, p, n, exp?.handle, rep?.handle, &applied))
        }
        return applied != 0
    }

    /// Remove the document at `key`; returns whether one was removed.
    /// Cascades the key's graph edges in the same transaction (including
    /// edges dangling on a key that never existed as a document).
    public func delete(_ key: Data) throws -> Bool {
        try ensureOpen()
        var existed: Int32 = 0
        try Values.withBytes(key) { p, n in
            try check(corvid_delete(handle, p, n, &existed))
        }
        return existed != 0
    }

    /// Delete every matching document — consumes `pred`. Returns the
    /// number removed (index-accelerated).
    public func deleteWhere(_ pred: Predicate) throws -> Int {
        try ensureOpen()
        try pred.ensureUsable()
        var removed: Int = 0
        try check(corvid_delete_where(handle, pred.take(), &removed))
        return removed
    }

    /// Delete each of `keys`; returns how many existed. Each delete
    /// cascades that key's graph edges, as `delete`'s.
    public func deleteBatch(_ keys: [Data]) throws -> Int {
        try ensureOpen()
        var removed: Int = 0
        if keys.isEmpty { // count == 0 with NULL arrays is a successful no-op
            try check(corvid_delete_batch(handle, nil, nil, 0, &removed))
            return removed
        }
        var flat: [UInt8] = []
        var spans: [(Int, Int)] = []
        for k in keys {
            spans.append((flat.count, k.count))
            flat.append(contentsOf: k)
        }
        if flat.isEmpty { flat = [0] } // non-NULL pointers for all-empty keys
        try flat.withUnsafeBufferPointer { fbuf in
            try spans.withUnsafeBufferPointer { sbuf in
                let ptrs: [UnsafePointer<UInt8>?] = sbuf.map { fbuf.baseAddress! + $0.0 }
                let lens: [Int] = sbuf.map { $0.1 }
                try ptrs.withUnsafeBufferPointer { pbuf in
                    try lens.withUnsafeBufferPointer { lbuf in
                        try check(corvid_delete_batch(handle, pbuf.baseAddress, lbuf.baseAddress, keys.count, &removed))
                    }
                }
            }
        }
        return removed
    }

    // ---- TTL (FFI.md §4.8) ----

    /// Insert with expiry `expiresAt` (the caller's epoch; the engine
    /// keeps no clock) — the row and its expiry commit atomically.
    public func insertWithTTL(_ key: Data, _ doc: Any?, expiresAt: Int64) throws {
        try ensureOpen()
        let v = try Values.encode(doc)
        defer { v.destroy() }
        try Values.withBytes(key) { p, n in
            try check(corvid_insert_with_ttl(handle, p, n, v.handle, expiresAt))
        }
    }

    /// Set (or replace) `key`'s expiry without rewriting the document.
    /// A plain (non-TTL) write clears a previously set expiry.
    public func setTTL(_ key: Data, expiresAt: Int64) throws {
        try ensureOpen()
        try Values.withBytes(key) { p, n in
            try check(corvid_set_ttl(handle, p, n, expiresAt))
        }
    }

    /// `key`'s expiry, or nil when none is set (unset is not an error).
    public func getTTL(_ key: Data) throws -> Int64? {
        try ensureOpen()
        var at: Int64 = 0
        var has: Int32 = 0
        try Values.withBytes(key) { p, n in
            try check(corvid_get_ttl(handle, p, n, &at, &has))
        }
        return has != 0 ? at : nil
    }

    /// Delete every record whose expiry is <= `now` (INCLUSIVE); returns
    /// the count. Each candidate is re-verified in the delete txn.
    public func purgeExpired(_ now: Int64) throws -> Int {
        try ensureOpen()
        var purged: Int = 0
        try check(corvid_purge_expired(handle, now, &purged))
        return purged
    }

    // ---- reads (FFI.md §4.9) ----

    /// Fetch and decode the document at `key`, or nil when absent. (A
    /// stored Null value also decodes to nil — the engine's
    /// absence/Null conflation, same as every sibling binding.)
    public func get(_ key: Data) throws -> Any? {
        try ensureOpen()
        var out: OpaquePointer? = nil
        try Values.withBytes(key) { p, n in
            try check(corvid_get(handle, p, n, &out))
        }
        guard let v = out else { return nil }
        defer { corvid_value_free(v) }
        return Values.decode(v)
    }

    /// Fetch just these top-level fields of `key`'s document (absent
    /// fields are absent from the result — a present Null reads as nil);
    /// nil when the key is absent.
    public func getFields(_ key: Data, _ fields: String...) throws -> [String: Any?]? {
        try ensureOpen()
        var out: OpaquePointer? = nil
        try Values.withBytes(key) { p, n in
            try check(corvid_get(handle, p, n, &out))
        }
        guard let v = out else { return nil }
        defer { corvid_value_free(v) }
        var result: [String: Any?] = [:]
        for f in fields {
            let child = Values.withUTF8(f) { p, n in corvid_value_map_get(v, p, n) }
            result[f] = Values.decodeIfPresent(child)
        }
        return result
    }

    /// Stream every (key, document) to `body` in key order, constant
    /// memory. Return false to stop (stopping is not an error). THROWING
    /// stops the scan and surfaces at the call site (the engine records
    /// ARGUMENT; the closure's own error is rethrown — never swallowed,
    /// never unwound through C frames). The closure must not call back
    /// into this db (FFI.md §1.6 reentrancy); the borrowed row is copied
    /// before the closure runs.
    public func scan(_ body: @escaping (Data, Any?) throws -> Bool) throws {
        try ensureOpen()
        let box = ScanSink(body)
        let st = corvid_scan(handle, { ctx, key, keyLen, doc in
            let box = Unmanaged<ScanSink>.fromOpaque(ctx!).takeUnretainedValue()
            let keyData = Data(bytes: UnsafeRawPointer(key!), count: keyLen)
            let decoded: Any? = doc != nil ? Values.decode(doc) : nil
            do {
                return try box.body(keyData, decoded) ? 1 : 0
            } catch {
                box.caught = error
                return 0 // the stop/abort signal (FFI.md §1.6)
            }
        }, Unmanaged.passUnretained(box).toOpaque())
        if let e = box.caught { throw e }
        try check(st)
    }

    /// Keyset pagination: up to `limit` documents in key order strictly
    /// after `after` (nil starts at the beginning — including the legal
    /// empty key; an empty-but-present Data is the zero-length cursor,
    /// an exclusive continuation), from one snapshot. `limit == 0`
    /// returns empty rows and no cursor.
    public func page(after: Data?, limit: Int) throws -> Page {
        try ensureOpen()
        var rowsOut: OpaquePointer? = nil
        var next: UnsafeMutablePointer<UInt8>? = nil
        var nextLen: Int = 0
        try Values.withOptionalBytes(after) { p, n in
            try check(corvid_page(handle, p, n, limit, &rowsOut, &next, &nextLen))
        }
        let cursor = next.map { Data(bytes: UnsafeRawPointer($0), count: nextLen) }
        if let next = next { corvid_free(UnsafeMutableRawPointer(next)) }
        guard let rows = rowsOut else {
            preconditionFailure("corvid: corvid_page succeeded without a rows cursor")
        }
        return Page(rows: Rows(rows), nextAfter: cursor)
    }

    /// The document count — O(1) maintained counter.
    public func len() throws -> Int {
        try ensureOpen()
        var out: Int = 0
        try check(corvid_len(handle, &out))
        return out
    }

    // ---- queries (FFI.md §4.6) ----

    /// Begin a fluent query over this collection. The builder is
    /// single-threaded and consumed by its terminal (`run` or any
    /// aggregate).
    public func query() throws -> Query {
        try ensureOpen()
        guard let q = corvid_query_new(handle) else { throw lastError() }
        return Query(q)
    }

    /// DIRECT positional text search (the engine's phrase_search): the
    /// `k` most relevant documents whose `field` TEXT contains `phrase`
    /// as a consecutive, in-order run of analyzed tokens (stop words
    /// collapse out of adjacency on both sides). Rows carry documents;
    /// `Row.score` is the BM25 phrase sum — NOT the builder's fused RRF
    /// scale. `k == 0` yields an empty result (inert, not an error).
    public func phraseSearch(field: String, phrase: String, k: Int) throws -> Rows {
        try ensureOpen()
        return try Values.withUTF8(field) { fp, fn in
            try Values.withUTF8(phrase) { pp, pn in
                guard let rows = corvid_phrase_search(handle, fp, fn, pp, pn, k) else { throw lastError() }
                return Rows(rows)
            }
        }
    }

    // ---- graph (FFI.md §4.11) ----

    /// Add a directed edge `from --relation--> to` (idempotent; a plain
    /// link overwrites a prior weighted edge's weight with 1.0).
    /// Endpoints need not exist as documents.
    public func link(_ from: Data, _ relation: String, _ to: Data) throws {
        try ensureOpen()
        try Values.withBytes(from) { fp, fn in
            try Values.withUTF8(relation) { rp, rn in
                try Values.withBytes(to) { tp, tn in
                    try check(corvid_link(handle, fp, fn, rp, rn, tp, tn))
                }
            }
        }
    }

    /// Add a directed edge carrying a `weight` — readable back through
    /// `neighborsWeighted`. A later plain `link` of the same edge
    /// overwrites the weight with 1.0.
    public func linkWeighted(_ from: Data, _ relation: String, _ to: Data, weight: Double) throws {
        try ensureOpen()
        try Values.withBytes(from) { fp, fn in
            try Values.withUTF8(relation) { rp, rn in
                try Values.withBytes(to) { tp, tn in
                    try check(corvid_link_weighted(handle, fp, fn, rp, rn, tp, tn, weight))
                }
            }
        }
    }

    /// Remove the edge (and its reverse) atomically; returns whether the
    /// FORWARD edge existed (false is not an error).
    public func unlink(_ from: Data, _ relation: String, _ to: Data) throws -> Bool {
        try ensureOpen()
        var removed: Int32 = 0
        try Values.withBytes(from) { fp, fn in
            try Values.withUTF8(relation) { rp, rn in
                try Values.withBytes(to) { tp, tn in
                    try check(corvid_unlink(handle, fp, fn, rp, rn, tp, tn, &removed))
                }
            }
        }
        return removed != 0
    }

    /// Targets of every `from --relation--> ?` edge, in key order.
    public func neighbors(_ from: Data, _ relation: String) throws -> Strs {
        try ensureOpen()
        return try Values.withBytes(from) { fp, fn in
            try Values.withUTF8(relation) { rp, rn in
                guard let s = corvid_neighbors(handle, fp, fn, rp, rn) else { throw lastError() }
                return Strs(s)
            }
        }
    }

    /// Sources of every `? --relation--> to` edge, in key order.
    public func inNeighbors(_ to: Data, _ relation: String) throws -> Strs {
        try ensureOpen()
        return try Values.withBytes(to) { tp, tn in
            try Values.withUTF8(relation) { rp, rn in
                guard let s = corvid_in_neighbors(handle, tp, tn, rp, rn) else { throw lastError() }
                return Strs(s)
            }
        }
    }

    /// (target, weight) for every `from --relation--> ?` edge, in key
    /// order (1.0 for unweighted edges).
    public func neighborsWeighted(_ from: Data, _ relation: String) throws -> [WeightedEdge] {
        try ensureOpen()
        let hits = Values.withBytes(from) { fp, fn in
            Values.withUTF8(relation) { rp, rn in
                corvid_neighbors_weighted(handle, fp, fn, rp, rn)
            }
        }
        guard let hits = hits else { throw lastError() }
        return GeoHits(hits).map { WeightedEdge(key: $0.key, weight: $0.distanceKm) }
    }

    /// Breadth-first traversal following `relation` up to `hops` from
    /// `start`: the reachable nodes EXCLUDING start, each once, in BFS
    /// order. `hops == 0` yields nothing; cycles terminate. One read
    /// snapshot covers the walk.
    public func traverse(_ start: Data, _ relation: String, hops: Int) throws -> Strs {
        try ensureOpen()
        return try Values.withBytes(start) { sp, sn in
            try Values.withUTF8(relation) { rp, rn in
                guard let s = corvid_traverse(handle, sp, sn, rp, rn, hops) else { throw lastError() }
                return Strs(s)
            }
        }
    }

    // ---- geo (FFI.md §4.12) ----

    /// Documents whose `field` point lies within `radiusKm` (INCLUSIVE)
    /// of (lat, lon), nearest first, ties by key. Documents lacking a
    /// valid point are skipped.
    public func geoWithinRadius(_ field: String, lat: Double, lon: Double, radiusKm: Double) throws -> GeoHits {
        try ensureOpen()
        return try Values.withUTF8(field) { fp, fn in
            guard let h = corvid_geo_within_radius(handle, fp, fn, lat, lon, radiusKm) else { throw lastError() }
            return GeoHits(h)
        }
    }

    /// Documents whose `field` point lies inside the box, in KEY order.
    /// Bounds are validated at entry (CorvidError(.argument) on NaN /
    /// latitude out of [-90,90] / inverted latitude); `minLon > maxLon`
    /// wraps the antimeridian. distanceKm is the 0.0 sentinel.
    public func geoWithinBBox(_ field: String, minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) throws -> GeoHits {
        try ensureOpen()
        return try Values.withUTF8(field) { fp, fn in
            guard let h = corvid_geo_within_bbox(handle, fp, fn, minLat, minLon, maxLat, maxLon) else { throw lastError() }
            return GeoHits(h)
        }
    }

    /// The true `k` nearest documents by `field` point, nearest first
    /// (expanding radius, exact); `k == 0` yields nothing.
    public func geoNearest(_ field: String, lat: Double, lon: Double, k: Int) throws -> GeoHits {
        try ensureOpen()
        return try Values.withUTF8(field) { fp, fn in
            guard let h = corvid_geo_nearest(handle, fp, fn, lat, lon, k) else { throw lastError() }
            return GeoHits(h)
        }
    }

    // ---- indexes (FFI.md §4.10) — every create is (or replace):
    //      re-creating an index rebuilds it. ----

    /// Scalar secondary index on `field` (equality + range
    /// acceleration; on disk, persists).
    public func createScalarIndex(_ field: String) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_scalar_index(handle, fp, fn))
        }
    }

    /// Compound index over an ordered field list (equality on a leading
    /// prefix plus an optional range on the next field).
    public func createCompoundIndex(_ fields: [String]) throws {
        try ensureOpen()
        try Values.withCStringArray(fields) { ptrs, lens, count in
            try check(corvid_create_compound_index(handle, ptrs, lens, count))
        }
    }

    /// In-memory inverted text index on `field`.
    public func createTextIndex(_ field: String) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_text_index(handle, fp, fn))
        }
    }

    /// On-disk inverted text index on `field` — postings stored as redb
    /// entries; existing documents backfill synchronously.
    public func createTextIndexOnDisk(_ field: String) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_text_index_ondisk(handle, fp, fn))
        }
    }

    /// Spatial index on `field` — serves the radius/bbox windows.
    public func createGeoIndex(_ field: String) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_geo_index(handle, fp, fn))
        }
    }

    /// Full-precision in-memory HNSW index on `field`.
    public func createVectorIndex(_ field: String, metric: Metric) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_vector_index(handle, fp, fn, cmetric(metric)))
        }
    }

    /// In-memory HNSW storing vectors quantized — binary ~32x / scalar
    /// ~4x smaller at some recall cost.
    public func createVectorIndexQuantized(_ field: String, metric: Metric, quant: Quant) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_vector_index_quantized(handle, fp, fn, cmetric(metric), cquant(quant)))
        }
    }

    /// On-disk HNSW index on `field` — the graph lives in the database
    /// file; existing documents backfill synchronously.
    public func createVectorIndexOnDisk(_ field: String, metric: Metric) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_vector_index_ondisk(handle, fp, fn, cmetric(metric)))
        }
    }

    /// On-disk HNSW storing vectors quantized.
    public func createVectorIndexOnDiskQuantized(_ field: String, metric: Metric, quant: Quant) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_vector_index_ondisk_quantized(handle, fp, fn, cmetric(metric), cquant(quant)))
        }
    }

    /// In-memory HNSW storing product-quantized vectors: a codebook of
    /// `m` subspaces × `k` centroids trains deterministically from
    /// existing vectors; `dim % m == 0` required. Every training-domain
    /// failure (m == 0, k outside 2..=256, dim % m != 0, mixed
    /// dimensions, no usable vectors) surfaces as
    /// CorvidError(.emptyIndexTraining).
    public func createVectorIndexPQ(_ field: String, metric: Metric, m: Int, k: Int) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_vector_index_pq(handle, fp, fn, cmetric(metric), m, k))
        }
    }

    /// On-disk HNSW storing product-quantized vectors — the same arity
    /// and training-domain contract as `createVectorIndexPQ`.
    public func createVectorIndexOnDiskPQ(_ field: String, metric: Metric, m: Int, k: Int) throws {
        try ensureOpen()
        try Values.withUTF8(field) { fp, fn in
            try check(corvid_create_vector_index_ondisk_pq(handle, fp, fn, cmetric(metric), m, k))
        }
    }

    // ---- schema (FFI.md §4.10) ----

    /// Declare (or replace) the collection's schema: enforced on
    /// subsequent writes only — existing documents are not retroactively
    /// validated. An empty array declares an empty schema, which accepts
    /// any map document and REPLACES any previously declared one.
    public func setSchema(_ defs: [FieldDef]) throws {
        try ensureOpen()
        if defs.isEmpty {
            try check(corvid_set_schema(handle, nil, 0))
            return
        }
        var flat: [UInt8] = []
        var spans: [(Int, Int)] = []
        for d in defs {
            let b = Array(d.name.utf8)
            spans.append((flat.count, b.count))
            flat.append(contentsOf: b)
        }
        if flat.isEmpty { flat = [0] } // non-NULL pointers for all-empty names
        try flat.withUnsafeBufferPointer { fbuf in
            try spans.withUnsafeBufferPointer { sbuf in
                let fdefs: [corvid_field_def] = (0..<defs.count).map { i in
                    corvid_field_def(
                        name: UnsafeRawPointer(fbuf.baseAddress! + sbuf[i].0).assumingMemoryBound(to: CChar.self),
                        name_len: sbuf[i].1,
                        type: cfieldtype(defs[i].type),
                        required: defs[i].required ? 1 : 0,
                        unique: defs[i].unique ? 1 : 0)
                }
                try fdefs.withUnsafeBufferPointer { dbuf in
                    try check(corvid_set_schema(handle, dbuf.baseAddress, defs.count))
                }
            }
        }
    }

    /// The declared schema in declaration order, or nil when none is.
    public func schema() throws -> [FieldDef]? {
        try ensureOpen()
        var iter: OpaquePointer? = nil
        try check(corvid_schema(handle, &iter))
        guard let it = iter else { return nil }
        return Array(SchemaIterator(it))
    }

    /// Release this handle's engine reference and derived count
    /// (quiescence for `Db.compact`). Idempotent.
    public func close() {
        if closed { return }
        closed = true
        corvid_collection_free(handle)
    }

    deinit { close() }

    private func ensureOpen() throws {
        guard !closed else {
            throw CorvidError(code: .argument, message: "corvid: Collection is closed")
        }
    }
}

// The callback trampolines' context boxes: they carry the Swift closure
// in and the closure's error out (the C callback cannot throw — the
// trampoline catches, records, returns the abort signal, and the call
// site rethrows; FFI.md §1.6 shaped Swift-side).
private final class ScanSink {
    let body: (Data, Any?) throws -> Bool
    var caught: Error?

    init(_ body: @escaping (Data, Any?) throws -> Bool) { self.body = body }
}

private final class UpdateBox {
    let body: (Any?) throws -> Any?
    var caught: Error?

    init(_ body: @escaping (Any?) throws -> Any?) { self.body = body }
}
