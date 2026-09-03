// ErrCodesTest.swift — pins the frozen error-code table (FFI.md §1.3:
// values are never renumbered) — the docs/SURFACE.tsv mapping for the
// engine's corvid::Error rows. The fixtures prove the codes the suite
// can trigger (10/11/12/14/15/17); the redb-internal fault variants
// have no public trigger (the engine's own radar exempts them), so the
// table itself is the proof that every variant maps to its documented
// code. Code 19 (BUSY) is FFI-only: compact exclusivity, with no
// engine Error variant.
import Testing
@testable import Corvid

struct ErrCodesTest {

    @Test func errorCodeTableIsFrozen() {
        let frozen: [(CorvidErrorCode, UInt32)] = [
            (.ok, 0),
            (.database, 1),
            (.transaction, 2),
            (.table, 3),
            (.storage, 4),
            (.commit, 5),
            (.setDurability, 6),
            (.compaction, 7),
            (.decode, 8),
            (.corruptIndex, 9),
            (.reservedCollection, 10),
            (.invalidName, 11),
            (.argument, 12),
            (.incompatibleFormat, 13),
            (.emptyIndexTraining, 14),
            (.schemaViolation, 15),
            (.invalidDump, 16),
            (.backupTargetExists, 17),
            (.io, 18),
            (.busy, 19),
        ]
        let all = CorvidErrorCode.allCases
        #expect(all.count == 20, "table must hold exactly the 20 frozen codes (0..19), has \(all.count)")
        for (code, want) in frozen {
            #expect(code.rawValue == want, "\(code) = \(code.rawValue), want \(want) (frozen table drifted)")
        }
        // The reverse lookup used by the error surface.
        for (code, _) in frozen {
            #expect(CorvidErrorCode(rawValue: code.rawValue) == code,
                    "CorvidErrorCode(rawValue: \(code.rawValue)) must round-trip \(code)")
        }
    }
}
