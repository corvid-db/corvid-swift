# corvid-swift — the binding's plan

corvid-swift is the **Swift binding for Apple platforms** (iOS 13+,
macOS 10.15+) for the `corvid` embedded database. Like its siblings
(`corvid-c`/`corvid-jvm`/`corvid-js`/…), it exists to prove,
continuously and outside the engine repo, that corvid's **published FFI
artifacts** — here the `CorvidEngine.xcframework` shipped on each
engine release — drive a real consumer to the same verdicts the
engine's own suite produces; on top of that proof it carries the
idiomatic Swift API.

Engine repo: `corvid-db/corvid` (read-only upstream; never a submodule,
never vendored). Canonical docs: the corvid docs site's FFI section
(the `docs/FFI.md` contract in the engine repo — 124 symbols, frozen
enums, §8 idiom gate).

## The architecture ruling: an SPM library over the xcframework binary target, release artifacts only

**Swift Package Manager package**, product `Corvid`: a source target
that calls the engine's C ABI **directly** through the clang module the
binary target forms. No C shim of our own (that is the corvid-jvm
shape, where JNI demands one — Swift consumes C natively; `import
CorvidEngine` exposes every `corvid_*` symbol), no code generation, no
dynamic loading — the static library **links at build time**.

- **Binary target `CorvidEngine`**: the engine release's
  `corvid-swift-<tag>.zip` (CorvidEngine.xcframework: iOS device +
  fat iOS-simulator + fat macOS staticlib slices), pinned TWICE — the
  URL's tag and the sha256 `checksum:`. The release cascade bumps both
  together; the tag-driven release gate (below) refuses a tag that
  disagrees with either.
- **Why a binary xcframework and not source-built Rust**: the binding
  installs in one line (`dependencies: [.package(url: …)]`) with no
  Rust toolchain, and it verifies the exact bytes the engine ships —
  the same release-artifact discipline every sibling applies (a
  published-artifact defect is a FINDING against the engine, never
  patched around here).
- **Platform scope**: iOS (device + simulator, arm64 + x86_64) and
  macOS (arm64 + x86_64). watchOS/visionOS/tvOS slices are a recorded
  follow-up — the engine adds an xcframework slice the same way the
  day one is requested (DESIGN decision log, 2026-09-03).
- **Swift 5 language mode** under a 6.0 tools manifest: the wrapper
  types are `@unchecked Sendable` exactly where FFI.md §6's thread
  contract says the underlying handles are thread-safe (db/collection)
  and NOT Sendable where they are not (builders, iterators, value
  handles are single-threaded). Strict-mode annotations would be
  ceremony on top of the ABI's own contract.

Consequences, all locked:

- **No Rust toolchain, ever.** `swift test` / `swift build` fetches the
  pinned zip itself (SwiftPM resolves binary targets by URL +
  checksum); CI and consumers need only Xcode/Swift.
- **Pin EXACT engine tags** — today `v0.4.1` (the first engine release
  that ships the xcframework). The pin lives in three places the
  cascade rewrites together: `.engine-pin`, the `Package.swift`
  binary-target URL, and the README. The release gate verifies all
  three agree plus the checksum against the release's checksums.txt.
- **No vendored binaries in git.** The xcframework is fetched, never
  committed (`.build/` is gitignored).
- **Published-artifact defects are findings, not patches.**

## The API mapping (C ABI → Swift)

The review center-of-gravity, mirroring corvid-jvm's table — every row
is enforced by the golden suite where the fixture grammar reaches it:

| C ABI (corvid.h / FFI.md) | corvid-swift |
| --- | --- |
| opaque handles (`corvid_db*`, …) | `final class`es — `Db`, `Collection`, `Query`, `Rows`, `GroupIter`, `Strs`, `GeoHits`, `SchemaIterator`, `Value` (the value-handle world), `Predicate`; `deinit` calls the one right `_free` (idempotent guard), and every consume-by-call site invalidates the wrapper BEFORE the native call, whatever its outcome (FFI.md §8's unconditional consumption) — a consumed wrapper throws on reuse |
| `CORVID_ERR` + thread-local last error | `throws` + `CorvidError` (`struct CorvidError: Error` with `code: CorvidErrorCode`, `message: String`); the code+message are read IMMEDIATELY inside the same function that saw `CORVID_ERR` (the same-call guarantee, FFI.md §3) |
| frozen enums (`corvid_metric`, `corvid_quant`, `corvid_err`, `corvid_field_type`, `corvid_value_type`, `corvid_cmp`) | Swift `enum`s with `: UInt32` raw values carrying the exact ABI values (they are frozen — appended values only) |
| consumed-by-call args (pred trees, query builders) | invalidated before the call (see handles row) — the double-free UB class cannot happen |
| borrowed views (`_ref` buffers, row documents, callback args) | copied into Swift-owned `Data`/`[String: Any?]`/`String` inside the same native call that observed them — nothing borrowed is retained past the call |
| `corvid_update_fn` / `corvid_scan_fn` | Swift closures, synchronous on the calling thread; a **throwing closure aborts the engine call** (store untouched, `ARGUMENT` recorded) and the closure's own error surfaces at the call site — never swallowed, never unwound through C frames (the JNI/go-binding ruling, Swift-shaped) |
| strings | `String` both ways via REAL UTF-8 (`Array(string.utf8)` + length; decode with `String(decoding:as:)`) — never terminated-pointer assumptions |
| keys / bytes / vectors | `Data` (or `[UInt8]`) for keys and blobs; `[Float]` for vectors |
| documents | the dynamic shape mirrors corvid-jvm's Kotlin: `[String: Any?]` maps / `[Any?]` arrays whose leaf types are `Bool`, `Int` (i64), `UInt` (u64), `Double`, `Float`, `String`, nested maps/arrays — runtime type-check with `CorvidError(.argument)` on anything else; decode produces the same shapes (integers as `Int`, floats as `Double`, vectors as `[Float]`) |
| `corvid_ffi_version()` | `Corvid.checkLoaded()` gates == 1 at first use — the engine is statically linked, so this catches a wrapper/xcframework version skew, not a load failure |

### Lifetime and ownership specifics

- `Db`: `close()` (idempotent) + `deinit`; derived `Collection`s keep
  the engine alive independently (FFI.md §2) — the wrapper does NOT
  lifetime-manage children, exactly like the Kotlin binding.
- `Query`: **consumed by `run()`** (and by every aggregate) whatever
  the outcome; the builder shape is `var`-free — setters return the
  builder (fluent) and mutation happens on the handle.
- `Rows`/`GroupIter`/`Strs`/`GeoHits`: `Sequence`-conforming
  single-pass iterators; `deinit` frees.
- `Value` handles built for inserts/updates are consumed by the call.

## The golden suite — the verifier

The engine's 8-fixture / 267-executable-line suite, replayed through
THIS binding against the DOWNLOADED xcframework — the same fixture
files vendored byte-identically in `golden/`. The interpreter ports
corvid-jvm's `GoldenTest.kt` (the most literal of the ports — same
line grammar `COLL/INSERT/QF_COUNT/…`, same expected-output
comparison, same fixture-coverage accounting); `swift test` runs it on
macOS. The port proves the mapping table above row by row.

`docs/SURFACE.tsv` + `scripts/surface-gate.sh` complete the verifier
posture (ported from corvid-jvm): every engine construct at the pinned
tag mapped (api + proving test) or N/A with a reason, N/A count pinned
to the committed baseline.

## CI + release

- **ci.yml**: macOS runner — `swift test` (golden suite), plus an
  iOS-simulator compile leg (`xcodebuild -scheme Corvid -destination
  'generic/platform=iOS Simulator' build`) proving the simulator slice
  links; and the surface gate.
- **release.yml** (tag `v*`): gate — the tag must equal `.engine-pin`
  AND the `Package.swift` binary-target URL's version AND the README's
  first install version; the zip at that URL is re-downloaded, its
  sha256 checked against BOTH the release's `checksums.txt` and the
  manifest's `checksum:` literal (a drifted checksum is a hard,
  explained failure). On green: create the GitHub release (notes only
  — the binary lives on the engine's release; the SPM tag IS the
  publish).

## Tasks (SDD ledger)

- **T1 wrapper core** — errors/enums, the value world (encode/decode),
  `Db`/`Collection` CRUD + scan/page/len, TTL, link/unlink, indexes
  (all eleven creators), admin (backup/compact/dump/load/renames),
  schema (set/schema-iterate); smoke test against the real xcframework
  passes (`swift test`).
- **T2 query surface** — `Query` builder (filter/vector/text/fuse_rrf/
  rerank_mmr/approx/limit/offset/order_by/select), predicates (`Field`
  DSL over dotted paths, and/or/not, every `corvid_pred_*`),
  `Rows`/`GroupIter` decoding, every aggregate, phrase/geo/vector
  search entry points on `Collection`.
- **T3 golden + verifier** — the fixture interpreter + all 8 files
  through it (267/267), SURFACE.tsv + surface-gate, ci.yml, release.yml.
- **T4 docs** — README (install via SPM, quick start, platform table),
  this PLAN's task ledger closure, docs-site page (corvid-docs
  bindings/corvid-swift.md, separate repo).

Out of scope, recorded: watchOS/visionOS/tvOS slices; Swift strict
concurrency mode; Combine/async wrappers (the ABI is synchronous —
callers wrap); a CocoaPods podspec (SPM is the distribution; a podspec
is additive the day it is asked for).
