// DeepCheck.swift — the wrapper's deep integration pass: every surface
// the golden-suite grammar does not reach (admin paths, scan aborts,
// graph, geo, schema, TTL, the full aggregate set), asserted directly.
import Corvid
import Foundation
import Testing

@Suite
struct DeepCheck {

    @Test
    func mutationsReadsPageScan() throws {
        let db = try Corvid.openMemory()
        defer { db.close() }
        let c = try db.collection("m")

        // putMany + len + page walk feeding nextAfter back
        try c.putMany(
            keys: [Data("a".utf8), Data("b".utf8), Data("c".utf8), Data("d".utf8)],
            docs: [["n": 1, "tag": "x"] as [String: Any?],
                   ["n": 2, "tag": "y"] as [String: Any?],
                   ["n": 3, "tag": "x"] as [String: Any?],
                   ["n": 4, "tag": "y"] as [String: Any?]])
        #expect(try c.len() == 4)

        var walked: [String] = []
        var after: Data? = nil
        while true {
            let p = try c.page(after: after, limit: 2)
            walked += p.rows.map { String(decoding: $0.key, as: UTF8.self) }
            guard let nx = p.nextAfter else { break }
            after = nx
        }
        #expect(walked == ["a", "b", "c", "d"])

        // scan: count, early stop, throwing abort + rethrow
        var seen = 0
        try c.scan { _, _ in
            seen += 1
            return true
        }
        #expect(seen == 4)
        var first = 0
        try c.scan { _, _ in
            first += 1
            return false // stop is not an error
        }
        #expect(first == 1)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try c.scan { _, _ in throw Boom() }
        }

        // insertAuto + patch + getFields + compareAndSet
        let auto = try c.insertAuto(["n": 5] as [String: Any?])
        #expect(auto.count == 20)
        try c.patch(Data("a".utf8), ["extra": true] as [String: Any?])
        let gf = try c.getFields(Data("a".utf8), "n", "extra", "missing")
        #expect(gf?["n"] as? Int == 1)
        #expect(gf?["extra"] as? Bool == true)
        // the projection answers only the asked fields (getFields is the
        // one API where a missing key comes back as an explicit null —
        // compare by key SET, not Any??-vs-nil)
        #expect(gf?.keys.sorted() == ["extra", "missing", "n"])
        #expect(try c.compareAndSet(Data("a".utf8), expected: ["n": 1, "tag": "x", "extra": true] as [String: Any?], replacement: ["n": 10] as [String: Any?]) == true)
        #expect(try c.compareAndSet(Data("a".utf8), expected: nil, replacement: nil) == false)
        #expect(try c.compareAndSet(Data("zz".utf8), expected: nil, replacement: ["k": 1] as [String: Any?]) == true) // absent -> insert

        // deleteBatch + deleteWhere (and/or/not)
        #expect(try c.deleteBatch([Data("b".utf8), Data("nope".utf8)]) == 1)
        let removed = try c.deleteWhere(
            try field("tag").eq("y").or(try field("n").ge(10)).not())
        #expect(removed >= 1)
    }

    @Test
    func ttl() throws {
        let db = try Corvid.openMemory()
        defer { db.close() }
        let c = try db.collection("ttl")
        try c.insertWithTTL(Data("e".utf8), ["v": 1] as [String: Any?], expiresAt: 100)
        #expect(try c.getTTL(Data("e".utf8)) == 100)
        try c.setTTL(Data("e".utf8), expiresAt: 50)
        #expect(try c.getTTL(Data("e".utf8)) == 50)
        #expect(try c.getTTL(Data("none".utf8)) == nil)
        #expect(try c.purgeExpired(50) == 1) // inclusive <= now
        #expect(try c.get(Data("e".utf8)) == nil)
    }

    @Test
    func graph() throws {
        let db = try Corvid.openMemory()
        defer { db.close() }
        let c = try db.collection("g")
        try c.link(Data("a".utf8), "knows", Data("b".utf8))
        try c.linkWeighted(Data("a".utf8), "knows", Data("c".utf8), weight: 2.5)
        try c.link(Data("b".utf8), "knows", Data("d".utf8))
        try c.link(Data("c".utf8), "knows", Data("d".utf8))

        #expect(Array(try c.neighbors(Data("a".utf8), "knows")).map { String(decoding: $0, as: UTF8.self) } == ["b", "c"])
        #expect(Array(try c.inNeighbors(Data("d".utf8), "knows")).map { String(decoding: $0, as: UTF8.self) } == ["b", "c"])
        let w = try c.neighborsWeighted(Data("a".utf8), "knows")
        #expect(w.map { String(decoding: $0.key, as: UTF8.self) } == ["b", "c"])
        #expect(w.map { $0.weight } == [1.0, 2.5])
        #expect(Array(try c.traverse(Data("a".utf8), "knows", hops: 2)).map { String(decoding: $0, as: UTF8.self) } == ["b", "c", "d"])
        #expect(try c.unlink(Data("a".utf8), "knows", Data("c".utf8)) == true)
        #expect(try c.unlink(Data("a".utf8), "knows", Data("c".utf8)) == false)
    }

    @Test
    func geo() throws {
        let db = try Corvid.openMemory()
        defer { db.close() }
        let c = try db.collection("geo")
        // Berlin ~52.52,13.40; Potsdam ~52.39,13.06; Sydney -33.87,151.21
        try c.insert(Data("berlin".utf8), ["loc": [52.52, 13.40] as [Any?]] as [String: Any?])
        try c.insert(Data("potsdam".utf8), ["loc": ["lat": 52.39, "lon": 13.06] as [String: Any?]] as [String: Any?])
        try c.insert(Data("sydney".utf8), ["loc": [-33.87, 151.21] as [Any?]] as [String: Any?])

        let near = Array(try c.geoWithinRadius("loc", lat: 52.52, lon: 13.40, radiusKm: 50))
        #expect(near.map { String(decoding: $0.key, as: UTF8.self) } == ["berlin", "potsdam"])
        #expect(near.first?.doc != nil)

        let box = Array(try c.geoWithinBBox("loc", minLat: 52.0, minLon: 13.0, maxLat: 53.0, maxLon: 14.0))
        #expect(box.map { String(decoding: $0.key, as: UTF8.self) } == ["berlin", "potsdam"])
        #expect(box.first?.distanceKm == 0.0) // the bbox sentinel

        let k1 = try c.geoNearest("loc", lat: 52.52, lon: 13.40, k: 1)
        #expect(k1.map { String(decoding: $0.key, as: UTF8.self) } == ["berlin"])

        // pred geoWithin inside a query
        let hits = try c.query().filter(field("loc").geoWithin(lat: 52.52, lon: 13.40, radiusKm: 50)).run()
        #expect(hits.map { String(decoding: $0.key, as: UTF8.self) } == ["berlin", "potsdam"])
    }

    @Test
    func predicatesAndAggregates() throws {
        let db = try Corvid.openMemory()
        defer { db.close() }
        let c = try db.collection("agg")
        try c.putMany(
            keys: (0..<6).map { Data("k\($0)".utf8) },
            docs: (0..<6).map { ["n": $0, "g": $0 % 2 == 0 ? "even" : "odd", "t": "v\($0)"] as [String: Any?] })

        // pred DSL breadth
        #expect(try c.query().filter(field("n").between(1, 3)).count() == 3)
        #expect(try c.query().filter(field("n").isIn([1, 3, 99])).count() == 2)
        #expect(try c.query().filter(field("t").startsWith("v1")).count() == 1)
        #expect(try c.query().filter(field("t").contains("5")).count() == 1)
        #expect(try c.query().filter(field("n").exists()).count() == 6)
        #expect(try c.query().filter(field("n").gt(3).and(field("g").eq("odd"))).count() == 1)

        // aggregates
        #expect(try c.query().count() == 6)
        #expect(try c.query().countDistinct("g") == 2)
        #expect(try c.query().sum("n") == 15)
        #expect(try c.query().avg("n") == 2.5)
        #expect(try c.query().min("n") as? Int == 0)
        #expect(try c.query().max("t") as? String == "v5")
        #expect(try c.query().filter(field("n").lt(0)).avg("n") == nil)

        // single-pass iterators: materialize once, then assert (a second
        // map() over GroupIter/GeoHits reads an exhausted cursor)
        let gc = Array(try c.query().groupCount("g"))
        #expect(gc.map(\.key) == ["even", "odd"])
        #expect(gc.map(\.value) == [3.0, 3.0])
        let gs = Array(try c.query().groupSum("g", "n"))
        #expect(gs.map(\.key) == ["even", "odd"])
        #expect(gs.map(\.value) == [6.0, 9.0])
        let ga = Array(try c.query().groupAvg("g", "n"))
        #expect(ga.map(\.key) == ["even", "odd"])
        #expect(ga.map(\.value) == [2.0, 3.0])

        // text source + knobs + select/limit/offset/orderBy
        try c.createTextIndex("t")
        let q = try c.query()
            .text("t", "v1 v3", k: 10)
            .fuseRRF(k: 60)
            .limit(n: 2)
            .offset(n: 0)
            .select(["t"])
        let rows = Array(try q.run())
        #expect(rows.count == 2)
        #expect((rows.first?.doc as? [String: Any?])?.keys.sorted() == ["t"])

        let ordered = Array(try c.query().orderBy("n", descending: true).run())
        #expect(ordered.map { ($0.doc as? [String: Any?])?["n"] as? Int } == [5, 4, 3, 2, 1, 0])

        let vec = try c.query().vector("n", [1], k: 3, metric: .dot)
        _ = Array(try vec.run()) // consumed fine
    }

    @Test
    func schemaIndexes() throws {
        let db = try Corvid.openMemory()
        defer { db.close() }
        let c = try db.collection("s")
        try c.setSchema([
            FieldDef(name: "name", type: .text, required: true, unique: true),
            FieldDef(name: "age", type: .int),
        ])
        let got = try c.schema()
        #expect(got?.count == 2)
        #expect(got?[0].name == "name")
        #expect(got?[0].type == .text)
        #expect(got?[0].required == true)
        #expect(got?[0].unique == true)
        #expect(got?[1].type == .int)
        #expect(got?[1].required == false)

        try c.insert(Data("u1".utf8), ["name": "ada", "age": 36] as [String: Any?])
        #expect(throws: CorvidError.self) {
            try c.insert(Data("u2".utf8), ["name": "ada"] as [String: Any?]) // unique violation
        }

        // index creators run (values-only; per-variant behavior is the golden suite's job)
        try c.createScalarIndex("age")
        try c.createCompoundIndex(["name", "age"])
        try c.createGeoIndex("loc")
        try c.createVectorIndexQuantized("emb", metric: .l2, quant: .scalar)
        try c.createVectorIndexOnDisk("emb", metric: .cosine)
        try c.createVectorIndexOnDiskQuantized("emb", metric: .dot, quant: .binary)
    }

    @Test
    func adminDumpLoadBackupCompact() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("corvid-swift-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // populate a, dump it, close
        let db = try Corvid.open(tmp.appendingPathComponent("a.corvid").path)
        let c = try db.collection("docs")
        try c.insert(Data("x".utf8), ["hello": "world"] as [String: Any?])
        let dump = tmp.appendingPathComponent("dump.txt").path
        try db.dumpToPath(dump)
        db.close()

        // load the dump into a fresh db (same collection), verify, then
        // with a rename into a DIFFERENT collection name
        let db2 = try Corvid.open(tmp.appendingPathComponent("b.corvid").path)
        try db2.loadFromPath(dump)
        #expect(try db2.collection("docs").len() == 1)
        try db2.loadFromPathWithRenames(dump, ["docs": "d2"])
        #expect(try db2.collection("d2").len() == 1)
        db2.close()

        // physical backup of a closed db's file, reopened and verified;
        // compaction returns true while no derived handles are open
        let backupPath = tmp.appendingPathComponent("backup.corvid").path
        let db3 = try Corvid.open(tmp.appendingPathComponent("b.corvid").path)
        try db3.backup(toPath: backupPath)
        #expect(try db3.compact() == true)
        db3.close()
        let db4 = try Corvid.open(backupPath)
        defer { db4.close() }
        #expect(try db4.collection("docs").len() == 1)
        #expect(try db4.collection("docs").get(Data("x".utf8)) != nil)
    }
}
