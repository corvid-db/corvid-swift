# corvid-swift

The Swift binding for
[corvid](https://github.com/corvid-db/corvid) — the embedded
multi-modal database — on **Apple platforms**: iOS 13+ (device and
simulator, arm64 + x86_64) and macOS 10.15+ (arm64 + x86_64). One
Swift Package, no Rust toolchain, no C shim: the wrapper calls the
engine's frozen C ABI directly through the clang module formed from
the prebuilt `CorvidEngine.xcframework` (iOS device + fat
iOS-simulator + fat macOS staticlib slices) that each engine release
publishes — and it proves, continuously and outside the engine repo,
that the published xcframework drives a real Swift consumer to the
same verdicts the engine's own suite produces: the golden-suite port
in `Tests/CorvidTests/GoldenTest.swift` replays the engine's 267-line
fixture suite through this binding, every line dispatched, every
expectation checked.

**Documentation:** the [corvid docs site](https://corvid-db.github.io/docs/)
is canonical — the [C ABI section](https://corvid-db.github.io/docs/ffi/)
documents every symbol this binding links (handles, ownership, errors,
threading), and [docs/PLAN.md](docs/PLAN.md) records this binding's
architecture ruling, the lifetime mapping, and the platform scope
(watchOS/visionOS/tvOS are a recorded, additive follow-up).

**Installing:** Swift Package Manager — the package URL is the repo:

```swift
dependencies: [
    .package(url: "https://github.com/corvid-db/corvid-swift.git", from: "0.4.1")
]
```

```swift
.target(name: "App", dependencies: [
    .product(name: "Corvid", package: "corvid-swift"),
])
```

Nothing else: the engine is statically linked from the pinned
xcframework (the binary target's URL tag + sha256 checksum are the
pin — the release cascade bumps both together), there is no runtime
download, no dynamic loading, and no `corvid_*` symbol search path.
Xcode 16+/Swift 6 toolchain (Swift 5 language mode); no other
dependencies.

## The API in one screen

```swift
import Corvid

let db = try Corvid.openMemory()
let docs = try db.collection("docs")

try docs.insert(
    Data("s1".utf8),
    ["kind": "doc",
     "body": "rust embedded database",
     "v": [1.0, 0.0] as [Float]] as [String: Any?])

let rows = Array(try docs.query()
    .filter(try field("kind").eq("doc"))
    .vector("v", [1.0, 0.0], k: 2, metric: .cosine)
    .run())
// rows.map { String(decoding: $0.key, as: UTF8.self) } == ["s1", ...]

let phrase = Array(try docs.phraseSearch(
    field: "body", phrase: "embedded database", k: 2))

db.close() // deinit also closes; Db/Collection are thread-safe
```

Documents are Swift values: `[String: Any?]` maps and `[Any?]` arrays
whose leaves are `Bool`, `Int`, `UInt` (by bit pattern), `Double`,
`Float`, `String`, `Data`, and `[Float]` vectors; decoding yields the
canonical shapes (`nil`/`Bool`/`Int`/`Double`/`String`/`Data`/
`[Float]`/`[Any?]`/`[String: Any?]`), NaNs bit-exact. Keys are
`Data`. **Vectors are `[Float]`** — inside a document literal, write
`"v": [1.0, 0.0] as [Float]`; a bare `[1.0, 0.0]` infers `[Double]`
and encodes as an *array* of two floats, which is correct but is not
a vector. Errors are `throws` + `CorvidError` (the frozen code table +
the engine's message, read in the same call that failed). Throwing
closures passed to `update`/`scan` abort the engine call and rethrow
at the call site.

## The architecture ruling (short form)

SPM library product `Corvid` over binary target `CorvidEngine`
(the engine release's xcframework, pinned by URL tag + sha256; the
release gate verifies both against the engine release's checksums
before a tag goes out). Swift consumes C natively — unlike
corvid-jvm's JNI shim there is no shim here; the wrapper
(`Sources/Corvid`) is a thin lifetime/error/concurrency discipline
over the 124 frozen symbols (FFI.md §8: values frozen, symbols
append-only). Handles are `final class`es with `deinit` frees and
consume-on-use invalidation; `Db`/`Collection` are `@unchecked
Sendable` per the ABI's §6 thread contract, builders and iterators
are not Sendable; the cursors (`Rows`, `GeoHits`, `Strs`,
`GroupIter`) are single-pass `Sequence & IteratorProtocol`
conformers — iterate once (`for` loop or `materialize`-style `map`).

Full reasoning, the C-ABI→Swift mapping table, and the task ledger:
[docs/PLAN.md](docs/PLAN.md).

## Gates

- `swift test` — the golden suite (8 fixtures, 267/267 lines), the
  deep integration pass, the frozen error-code table, the smoke —
  against the DOWNLOADED xcframework at the pin.
- `scripts/surface-gate.sh` — every engine construct at the pinned
  tag mapped (api + proving test) or N/A with a reason
  (`docs/SURFACE.tsv`), N/A count baseline-pinned.
- CI adds an iOS-Simulator compile leg (the simulator slice links).
- Release (`v*` tag): the gate verifies tag == `.engine-pin` ==
  the manifest's URL version, and the manifest checksum == the actual
  zip's sha256 == the engine release's checksums entry, then creates
  the GitHub release — the SPM tag IS the publish.

The version rides the engine's release cascade (engine tag `vX.Y.Z` →
`from: "X.Y.Z"` here): `bump.sh` in the engine repo rewrites the pin,
the URL, the checksum, and this README's coordinates together.
