// Corvid.swift — the FFI version gate + the database constructors.
//
// The engine is STATICALLY linked (the CorvidEngine.xcframework binary
// target), so there is no load step — the gate is a version-SKEW check:
// it verifies corvid_ffi_version() == 1 once, at first use, and fails
// loudly if the linked CorvidEngine disagrees with this wrapper (the
// coordinated-bump discipline of FFI.md §8: bindings pin exact engine
// tags, so a skew is a build defect, never a runtime condition to
// handle).
import CorvidEngine
import Foundation

public enum Corvid {

    /// The ABI version this binding is written against (FFI.md §4.1/§8).
    public static let expectedFFIVersion: UInt32 = 1

    private static let gate = Gate()

    /// Verifies (once, under a lock — first use may race across threads)
    /// that the linked engine's ABI version is `expectedFFIVersion`;
    /// every entry point runs through this gate.
    public static func checkLoaded() {
        let g = gate
        g.lock.lock()
        defer { g.lock.unlock() }
        if g.verified { return }
        let v = corvid_ffi_version()
        guard v == expectedFFIVersion else {
            fatalError(
                "corvid: FFI version mismatch — the linked CorvidEngine reports \(v), "
                    + "this binding requires \(expectedFFIVersion) (wrapper/xcframework skew?)")
        }
        g.verified = true
    }

    /// The linked engine's ABI version (verified == `expectedFFIVersion`
    /// at first use).
    public static var ffiVersion: UInt32 {
        checkLoaded()
        return corvid_ffi_version()
    }

    /// Open (creating if absent) a file-backed database at `path`.
    /// Throws CorvidError(.database) / (.incompatibleFormat) / (.io).
    public static func open(_ path: String) throws -> Db {
        try Values.withUTF8(path) { p, n in
            try Db(consuming: corvid_open(p, n))
        }
    }

    /// A purely in-memory database (no file).
    public static func openMemory() throws -> Db {
        try Db(consuming: corvid_open_memory())
    }

    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var verified = false
    }
}
