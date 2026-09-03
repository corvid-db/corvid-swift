// text-search — BM25 ranking, English and CJK.
//
// Six notes (three English, three CJK) searched through a text index
// with the query builder's BM25 source. Row scores are RRF ranks
// (1/(60 + rank)); the *order* is the BM25 ranking.
//
// The CJK strings exercise the engine's dictionary-free CJK
// segmentation: maximal runs of CJK characters are tokenized as
// sliding BIGRAMS (「東京」… → "東京", …), so an unsegmented CJK query
// matches by its bigrams — "城市" (city) matches both city notes,
// "数据库" (database) matches the ML note.
//
// Phrase matching: engine v0.3.0 added the DIRECT positional
// corvid_phrase_search to the ABI (consecutive in-order analyzed
// tokens, stop words collapsing out of adjacency), surfaced here as
// Collection.phraseSearch — Row.score is the BM25 phrase sum, not the
// builder's fused RRF scale.
//
// Run: swift run TextSearch

import Corvid
import Foundation

let corpus: [(String, String)] = [
    ("n1", "the quick brown fox jumps over the lazy dog"),
    ("n2", "a quick red fox leaps over a sleeping dog"),
    ("n3", "slow green turtle crosses the road"),
    ("n4", "東京是一座巨大的城市"),  // Tokyo is a huge city
    ("n5", "大阪是関西最大的城市"),  // Osaka is Kansai's biggest city
    ("n6", "机器学习正在改变数据库"), // ML is changing databases
]

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func search(_ notes: Collection, _ query: String, _ label: String) throws {
    let line = Array(try notes.query().text("body", query, k: 3).run())
        .map { String(format: "%@(%0.6f)", String(decoding: $0.key, as: UTF8.self), $0.score) }
        .joined(separator: " ")
    print("\(pad(label, 28)) -> \(line)")
}

func phrase(_ notes: Collection, _ query: String, _ label: String) throws {
    let line = Array(try notes.phraseSearch(field: "body", phrase: query, k: 3))
        .map { String(format: "%@(%0.6f)", String(decoding: $0.key, as: UTF8.self), $0.score) }
        .joined(separator: " ")
    print("\(pad(label, 28)) -> \(line)")
}

// docs:begin:text_search
let db = try Corvid.openMemory()
defer { db.close() }

let notes = try db.collection("notes")

for (key, body) in corpus {
    try notes.insert(Data(key.utf8), ["body": body] as [String: Any?])
}
try notes.createTextIndex("body")

try search(notes, "quick fox", "bm25 \"quick fox\":")
try search(notes, "quick dog", "bm25 \"quick dog\":")
try search(notes, "城市", "bm25 CJK 城市 (city):")
try search(notes, "数据库", "bm25 CJK 数据库 (database):")

try phrase(notes, "fox jumps over", "phrase \"fox jumps over\":")
try phrase(notes, "over jumps fox", "phrase \"over jumps fox\" (reversed — no match):")
try phrase(notes, "leaps over a sleeping", "phrase with stop words collapsed:")
// docs:end:text_search
