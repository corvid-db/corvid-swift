// geo — points, radius, bbox, nearest-k with real coordinates.
//
// Four German cities stored with their real lat/lon (the [lat, lon]
// array encoding; a {"lat": …, "lon": …} map encodes the same point).
// Distances are haversine kilometres:
//
//   radius 600 km from central Berlin (52.52, 13.40):
//     berlin 0.000000, potsdam 26.621424, hamburg 255.120591,
//     munchen 503.833264 — nearest first, inclusive boundary.
//   bbox (47..55, 5..15): all four, key order, the 0.0 sentinel
//     (a box has no center to measure from).
//   nearest 2: berlin, potsdam — exact haversine order.
//
// These are the same points and tolerances the engine's golden geo
// fixture asserts (~1e-6 km).
//
// Run: swift run Geo

import Corvid
import Foundation

let cities: [(String, Double, Double)] = [
    ("berlin", 52.52, 13.40),
    ("potsdam", 52.40, 13.06),
    ("hamburg", 53.55, 9.99),
    ("munchen", 48.14, 11.58),
]

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func show(_ label: String, _ hits: [GeoHit]) {
    let line = hits.map {
        String(format: "%@ %0.6fkm", String(decoding: $0.key, as: UTF8.self), $0.distanceKm)
    }.joined(separator: " ")
    print("\(pad(label, 34)) [\(line)]")
}

// docs:begin:geo
let db = try Corvid.openMemory()
defer { db.close() }

let places = try db.collection("places")

for (name, lat, lon) in cities {
    try places.insert(Data(name.utf8), [
        "name": name,
        "loc": [lat, lon] as [Any?], // the [lat, lon] array encoding
    ] as [String: Any?])
}
try places.createGeoIndex("loc")

show("within 600km of Berlin:", Array(try places.geoWithinRadius("loc", lat: 52.52, lon: 13.40, radiusKm: 600.0)))
show("bbox 47..55N, 5..15E:", Array(try places.geoWithinBBox("loc", minLat: 47.0, minLon: 5.0, maxLat: 55.0, maxLon: 15.0)))
show("nearest 2 to Berlin:", Array(try places.geoNearest("loc", lat: 52.52, lon: 13.40, k: 2)))
// docs:end:geo
