// hybrid — the flagship: filter + vector + BM25, RRF fusion, MMR
// rerank, limit.
//
// Hybrid retrieval over a 4-document corpus: a pre-ranking `kind`
// filter, a vector (ANN) source and a BM25 text source, both
// contributing top-2 candidate lists, fused with Reciprocal Rank
// Fusion (k = 60) and reranked for diversity with MMR (lambda = 1.0),
// capped at 2 rows. The printed scores are RRF rank sums: s1 is rank 1
// of both sources (1/61 + 1/61 = 2/61), s3 rank 2 of both (2/62).
//
// Run: swift run Hybrid

import Corvid
import Foundation

// docs:begin:hybrid
let db = try Corvid.openMemory()
defer { db.close() }

let docs = try db.collection("docs")

try docs.insert(
    Data("s1".utf8),
    ["kind": "doc", "body": "rust embedded database",
     "v": [1.0, 0.0] as [Float]] as [String: Any?])
try docs.insert(
    Data("s2".utf8),
    ["kind": "doc", "body": "python web frameworks",
     "v": [0.0, 1.0] as [Float]] as [String: Any?])
try docs.insert(
    Data("s3".utf8),
    ["kind": "doc", "body": "rust again database",
     "v": [0.9, 0.1] as [Float]] as [String: Any?])
try docs.insert(Data("m1".utf8), ["kind": "meta"]) // filtered out below

// The flagship query: filter + vector + text, RRF + MMR + limit.
// render flattens the Any?-boxed values Swift's dictionary printing
// would show as Optional(...).
func render(_ doc: Any?) -> String {
    guard let d = doc as? [String: Any?] else { return String(describing: doc ?? "nil") }
    return "[" + d.sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value.map { String(describing: $0) } ?? "nil")" }
        .joined(separator: ", ") + "]"
}

let rows = Array(try docs.query()
    .filter(try field("kind").eq("doc"))
    .vector("v", [1.0, 0.0], k: 2, metric: .cosine)
    .text("body", "rust database", k: 2)
    .fuseRRF(k: 60)
    .rerankMMR(lambda: 1)
    .limit(n: 2)
    .select(["body"])
    .run())
for (rank, r) in rows.enumerated() {
    print(String(format: "%d. %@ score=%.6f %@",
                 rank + 1, String(decoding: r.key, as: UTF8.self), r.score, render(r.doc)))
}
// docs:end:hybrid
