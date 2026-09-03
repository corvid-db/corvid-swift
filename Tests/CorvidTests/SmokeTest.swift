// SmokeTest.swift — the T1/T2 smoke gate: a real end-to-end pass through
// the DOWNLOADED xcframework (openMemory → collection → insert → get →
// len → filtered vector query → phrase search → update via closure →
// delete → close) plus the FFI version == 1 skew check.
import Corvid
import Foundation
import Testing

@Suite
struct SmokeTest {

    @Test
    func ffiVersionIsOne() {
        #expect(Corvid.ffiVersion == Corvid.expectedFFIVersion)
        #expect(Corvid.ffiVersion == 1)
        Corvid.checkLoaded() // idempotent — the gate re-verifies nothing
    }

    @Test
    func endToEnd() throws {
        let db = try Corvid.openMemory()
        defer { db.close() }

        let coll = try db.collection("notes")
        #expect(coll.name == "notes")

        // Insert a document covering the leaf types + nesting.
        let doc: [String: Any?] = [
            "title": "corvid quick tour",
            "n": 42,
            "score": 9.5,
            "published": true,
            "meta": ["author": "ada", "tags": ["db", "ffi"]] as [String: Any?],
            "embedding": [0.1, 0.2, 0.3] as [Float],
        ]
        let k1 = Data("k1".utf8)
        try coll.insert(k1, doc)

        // Get: decode mirrors the encode shapes (Int / Double / Bool /
        // String / nested map+array / [Float]).
        let got = try coll.get(k1) as? [String: Any?]
        #expect(got?["title"] as? String == "corvid quick tour")
        #expect(got?["n"] as? Int == 42)
        #expect(got?["score"] as? Double == 9.5)
        #expect(got?["published"] as? Bool == true)
        let meta = got?["meta"] as? [String: Any?]
        #expect(meta?["author"] as? String == "ada")
        #expect((meta?["tags"] as? [Any?])?.count == 2)
        #expect((got?["embedding"] as? [Float])?.count == 3)

        #expect(try coll.len() == 1)
        #expect(try db.collections() == ["notes"])

        // Filtered vector query: index over the embeddings, then filter
        // AND vector-source in one builder, consumed by run().
        try coll.createVectorIndex("embedding", metric: .cosine)
        let rows = try coll.query()
            .filter(field("published").eq(true))
            .vector("embedding", [0.1, 0.2, 0.3], k: 5)
            .run()
        let keys = rows.map { $0.key }
        #expect(keys.first == k1)

        // Phrase search (the direct positional call, not the builder).
        let k2 = Data("k2".utf8)
        try coll.insert(k2, [
            "title": "an embedded database tour",
            "published": true,
            "embedding": [0.9, 0.1, 0.0] as [Float],
        ] as [String: Any?])
        let hits = try coll.phraseSearch(field: "title", phrase: "embedded database", k: 5)
        #expect(hits.map { $0.key } == [k2])

        // Update via closure: read-modify-write with a rethrown path on
        // throw (exercised below), nil-current and nil-return semantics
        // untouched here.
        try coll.update(k1) { current in
            var m = (current as? [String: Any?]) ?? [:]
            m["n"] = 43
            return m
        }
        let after = try coll.get(k1) as? [String: Any?]
        #expect(after?["n"] as? Int == 43)

        // A throwing closure aborts the update and rethrows here.
        #expect(throws: Boomerang.self) {
            try coll.update(k1) { _ in throw Boomerang() }
        }
        let untouched = try coll.get(k1) as? [String: Any?]
        #expect(untouched?["n"] as? Int == 43) // the store stayed as it was

        // Delete.
        #expect(try coll.delete(k1) == true)
        #expect(try coll.get(k1) == nil)
        #expect(try coll.len() == 1)
    }

    private struct Boomerang: Error {}
}
