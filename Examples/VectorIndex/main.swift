// vector-index — three vector-index families, ANN vs exact.
//
// A file-backed database (the on-disk index is a disk-resident HNSW
// graph persisted inside the db file) with eight 4-d documents. The
// same embedding is stored under three fields so each index family can
// be demonstrated side by side:
//
//   vMem  — in-memory HNSW              (createVectorIndex)
//   vDisk — on-disk HNSW                (createVectorIndexOnDisk)
//   vQ    — in-memory binary-quantized  (createVectorIndexQuantized)
//
// The exact (streaming-scan) ranking is printed first, then the ANN
// (approx) ranking served by each index. The unquantized indexes
// answer identically to the scan on this corpus; the binary-quantized
// one genuinely diverges — the recall/footprint trade-off quantization
// makes (binary packs each float32 to one sign bit, ~32x smaller).
// Finally the db is closed and reopened: the on-disk graph reloads and
// serves the same ANN answer without a rebuild.
//
// Scores are RRF ranks (1/(60 + rank)) — the lone vector source's row
// score — so they reflect each lane's own ranking.
//
// Run: swift run VectorIndex

import Corvid
import Foundation

let corpus: [(String, [Float])] = [
    ("k0", [1.0, 0.0, 0.0, 0.0]), // nearest
    ("k1", [0.95, 0.05, 0.0, 0.0]),
    ("k2", [0.0, 1.0, 0.0, 0.0]),
    ("k3", [0.0, 0.9, 0.1, 0.0]),
    ("k4", [0.0, 0.0, 1.0, 0.0]),
    ("k5", [0.7, 0.7, 0.0, 0.0]),
    ("k6", [0.0, 0.0, 0.0, 1.0]),
    ("k7", [0.98, 0.02, 0.0, 0.0]),
]

let probe: [Float] = [1.0, 0.0, 0.0, 0.0]

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func runQuery(_ items: Collection, _ field: String, approx: Bool, _ label: String) throws {
    let q = try items.query().vector(field, probe, k: 4, metric: .cosine)
    if approx { _ = try q.approx() }
    let line = Array(try q.run())
        .map { String(format: "%@(%0.6f)", String(decoding: $0.key, as: UTF8.self), $0.score) }
        .joined(separator: " ")
    print("\(pad(label, 38)) \(line)")
}

// docs:begin:vector_index
let path = NSTemporaryDirectory() + "corvid-swift-example-vector-index.redb"
try? FileManager.default.removeItem(atPath: path) // reruns start clean (single-file db)

do {
    let db = try Corvid.open(path)
    defer { db.close() }
    let items = try db.collection("items")
    for (key, v) in corpus {
        try items.insert(Data("\(key)".utf8),
                         ["v_mem": v, "v_disk": v, "v_q": v] as [String: Any?])
    }
    try items.createVectorIndex("v_mem", metric: .cosine)
    try items.createVectorIndexOnDisk("v_disk", metric: .cosine)
    try items.createVectorIndexQuantized("v_q", metric: .cosine, quant: .binary)

    print("top-4 nearest to (1,0,0,0) under cosine:")
    try runQuery(items, "v_mem", approx: false, "exact (scan):")
    try runQuery(items, "v_mem", approx: true, "ann in-memory HNSW:")
    try runQuery(items, "v_disk", approx: true, "ann on-disk HNSW:")
    try runQuery(items, "v_q", approx: true, "ann binary-quantized:")
    print("(the quantized lane trades recall for a ~32x smaller index)")
}

// Reopen: the on-disk graph reloads (no rebuild) and answers again.
do {
    let db = try Corvid.open(path)
    defer { db.close() }
    let items = try db.collection("items")
    try runQuery(items, "v_disk", approx: true, "ann on-disk after reopen:")
}

try? FileManager.default.removeItem(atPath: path)
// docs:end:vector_index
