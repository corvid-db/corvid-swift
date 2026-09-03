// Db.swift — the database handle: open/close, collections, dump/load,
// backup, compact (FFI.md §4.1/§4.13).
//
// Threading (FFI.md §6): Db is safe for concurrent use from multiple
// threads (engine-backed; reads concurrent, writes serialized by the
// engine) — the one wrapper family marked @unchecked Sendable, after the
// ABI's own contract. close() is idempotent; use after close throws.
// Derived Collection handles keep the engine alive independently
// (FFI.md §2) — this wrapper does not lifetime-manage children.
import CorvidEngine
import Foundation

public final class Db: @unchecked Sendable {
    let handle: OpaquePointer
    private var closed = false

    init(consuming raw: OpaquePointer?) throws {
        Corvid.checkLoaded()
        guard let raw = raw else { throw lastError() }
        handle = raw
    }

    /// Handle to a named collection; the collection is created lazily on
    /// first write. Reserved/invalid names are NOT checked here — they
    /// fail at write time with CorvidError(.reservedCollection) /
    /// (.invalidName), exactly as in the engine.
    public func collection(_ name: String) throws -> Collection {
        try ensureOpen()
        return try Values.withUTF8(name) { p, n in
            try Collection(consuming: corvid_collection(handle, p, n))
        }
    }

    /// User collection names (engine `__` namespaces excluded), in name
    /// order. Listing creates nothing — an empty-but-never-written
    /// collection may not appear.
    public func collections() throws -> [String] {
        try ensureOpen()
        guard let cursor = corvid_collections(handle) else { throw lastError() }
        return Strs(cursor).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Write a logical, version-stamped dump of the whole database
    /// (documents, index/schema/TTL definitions, graph edges, auto-id
    /// counters) to `path`, from one read snapshot.
    public func dumpToPath(_ path: String) throws {
        try ensureOpen()
        try Values.withUTF8(path) { p, n in
            try check(corvid_dump_to_path(handle, p, n))
        }
    }

    /// Replay a dump into this database (merges with pre-existing
    /// collections per the engine contract).
    public func loadFromPath(_ path: String) throws {
        try ensureOpen()
        try Values.withUTF8(path) { p, n in
            try check(corvid_load_from_path(handle, p, n))
        }
    }

    /// Replay a dump, renaming every collection occurrence: the
    /// migration path for legacy `__`-containing names. Validated
    /// BEFORE the stream is read — an invalid target fails with
    /// CorvidError(.invalidName), a colliding mapping with
    /// CorvidError(.argument).
    public func loadFromPathWithRenames(_ path: String, _ renames: [String: String]) throws {
        try ensureOpen()
        let olds = Array(renames.keys)
        let news = olds.map { renames[$0]! }
        try Values.withUTF8(path) { pp, pn in
            try Values.withCStringArray(olds) { op, ol, count in
                try Values.withCStringArray(news) { np, nl, _ in
                    try check(corvid_load_from_path_with_renames(handle, pp, pn, op, np, ol, nl, count))
                }
            }
        }
    }

    /// Consistent point-in-time PHYSICAL backup to a FRESH file at
    /// `path` — an existing target fails with
    /// CorvidError(.backupTargetExists). Physical means
    /// feature-configuration-dependent; use dump/load to move between
    /// feature builds. Safe while writers are active.
    public func backup(toPath path: String) throws {
        try ensureOpen()
        try Values.withUTF8(path) { p, n in
            try check(corvid_backup(handle, p, n))
        }
    }

    /// Reclaim file space after heavy deletes — offline maintenance
    /// requiring quiescence: every derived handle must already be closed
    /// (a violation fails with the FFI-only CorvidError(.busy)). Returns
    /// whether any data moved; in-memory dbs report false.
    public func compact() throws -> Bool {
        try ensureOpen()
        var moved: Int32 = 0
        try check(corvid_compact(handle, &moved))
        return moved != 0
    }

    /// Release this handle's reference. Dropping the last reference
    /// releases the engine and its file locks; derived handles keep the
    /// engine alive independently. Idempotent.
    public func close() {
        if closed { return }
        closed = true
        // The status cannot fail on a live handle (FFI.md §7); a throwing
        // close would poison deinit, so a hypothetically failing release
        // is swallowed here.
        _ = corvid_close(handle)
    }

    deinit { close() }

    private func ensureOpen() throws {
        guard !closed else {
            throw CorvidError(code: .argument, message: "corvid: Db is closed")
        }
    }
}
