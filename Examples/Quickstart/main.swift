// quickstart — the README tour as a runnable file.
//
// Open an in-memory database, create a collection, insert three small
// documents carrying 2-d embeddings, run a kNN vector query under
// cosine, and print the ranked rows. Close what you opened.
//
// Run: swift run Quickstart

import Corvid
import Foundation

// docs:begin:quickstart
let db = try Corvid.openMemory()
defer { db.close() }

let docs = try db.collection("docs")

try docs.insert(
    Data("p1".utf8),
    ["title": "rust embedded database", "kind": "doc",
     "v": [1.0, 0.0] as [Float]] as [String: Any?])
try docs.insert(
    Data("p2".utf8),
    ["title": "python web frameworks", "kind": "doc",
     "v": [0.0, 1.0] as [Float]] as [String: Any?])
try docs.insert(
    Data("p3".utf8),
    ["title": "rust again database", "kind": "doc",
     "v": [0.9, 0.1] as [Float]] as [String: Any?])

// kNN: the 3 nearest documents to (1, 0) under cosine. Project the
// field the printout needs (docs decode in full either way; select
// trims the payload). render flattens the Any?-boxed values Swift's
// dictionary printing would show as Optional(...).
func render(_ doc: Any?) -> String {
    guard let d = doc as? [String: Any?] else { return String(describing: doc ?? "nil") }
    return "[" + d.sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value.map { String(describing: $0) } ?? "nil")" }
        .joined(separator: ", ") + "]"
}

let rows = Array(try docs.query()
    .vector("v", [1.0, 0.0], k: 3, metric: .cosine)
    .select(["title"])
    .run())
for (rank, r) in rows.enumerated() {
    print(String(format: "%d. %@ score=%.6f %@",
                 rank + 1, String(decoding: r.key, as: UTF8.self), r.score, render(r.doc)))
}
// docs:end:quickstart
