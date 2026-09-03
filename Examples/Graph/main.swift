// graph — directed edges over a small corpus, and delete cascade.
//
// Three documents (ga, gb, gc) linked by a `parent_of` relation, plus
// one edge pointing at `gd` which never exists as a document (dangling
// edges are allowed), and a weighted `route` relation. Demonstrates
// neighbors (key order), in-neighbors, weighted neighbors, BFS
// traverse at 1 and 2 hops (cycle-safe), and the delete cascade:
// deleting a key removes its edges in the same transaction — deleting
// the never-a-document `gd` still drops the `gb -> gd` edge (spec
// §4.8/§4.11).
//
// Run: swift run Graph

import Corvid
import Foundation

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func show(_ label: String, _ keys: [Data]) {
    let line = keys.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
    print("\(pad(label, 36)) [\(line)]")
}

// docs:begin:graph
let db = try Corvid.openMemory()
defer { db.close() }

let nodes = try db.collection("nodes")

for key in ["ga", "gb", "gc"] {
    try nodes.insert(Data(key.utf8), ["n": key] as [String: Any?])
}

try nodes.link(Data("ga".utf8), "parent_of", Data("gb".utf8))
try nodes.link(Data("ga".utf8), "parent_of", Data("gc".utf8))
try nodes.link(Data("gb".utf8), "parent_of", Data("gd".utf8)) // gd never a document
try nodes.linkWeighted(Data("ga".utf8), "route", Data("gb".utf8), weight: 2.5)
try nodes.linkWeighted(Data("ga".utf8), "route", Data("gd".utf8), weight: 0.75)

let ga = Data("ga".utf8)
let gb = Data("gb".utf8)

show("neighbors(ga)", Array(try nodes.neighbors(ga, "parent_of")))
show("in_neighbors(gb)", Array(try nodes.inNeighbors(gb, "parent_of")))
let routes = try nodes.neighborsWeighted(ga, "route")
    .map { String(format: "%@=%0.2f", String(decoding: $0.key, as: UTF8.self), $0.weight) }
    .joined(separator: " ")
print("\(pad("routes from ga (weighted):", 36)) [\(routes)]")
show("traverse(ga, 1 hop)", Array(try nodes.traverse(ga, "parent_of", hops: 1)))
show("traverse(ga, 2 hops)", Array(try nodes.traverse(ga, "parent_of", hops: 2)))

// Delete cascade: remove gc (a document) and gd (never a document).
print("delete gc: existed = \(try nodes.delete(Data("gc".utf8)))")
let existedGd = try nodes.delete(Data("gd".utf8))
print("delete gd: existed = \(existedGd) (never a document; its edges still cascade)")

show("neighbors(ga) after deletes", Array(try nodes.neighbors(ga, "parent_of")))
show("neighbors(gb) after deletes", Array(try nodes.neighbors(gb, "parent_of")))
show("traverse(ga, 2 hops) after", Array(try nodes.traverse(ga, "parent_of", hops: 2)))
// docs:end:graph
