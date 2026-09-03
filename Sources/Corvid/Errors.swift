// Errors.swift — the error surface: CorvidError carries the engine's
// error CODE (FFI.md §1.3, frozen per §8), mapped 1:1 onto
// CorvidErrorCode.
//
// The same-call guarantee (FFI.md §3): the engine's last-error slot is
// thread-local, and every wrapper reads the code+message IMMEDIATELY
// after the failing call, on the same thread, with no intervening corvid
// call — the read always sees THIS failure's detail.
import CorvidEngine
import Foundation

/// The engine's error codes (corvid_err, FFI.md §1.3). 1–18 map 1:1 onto
/// the engine's `corvid::Error` variants; 19 (busy) is FFI-only.
public enum CorvidErrorCode: UInt32, Sendable, CaseIterable {
    /// No error recorded on this thread.
    case ok = 0
    /// Opening/creating the file failed.
    case database = 1
    /// Beginning a read/write txn failed.
    case transaction = 2
    /// Opening a storage table failed.
    case table = 3
    /// A storage read/write failed.
    case storage = 4
    /// Committing a write txn failed.
    case commit = 5
    /// Changing txn durability failed.
    case setDurability = 6
    /// Compacting the file failed.
    case compaction = 7
    /// Stored bytes are not a decodable Value.
    case decode = 8
    /// Persisted index state is corrupt.
    case corruptIndex = 9
    /// Collection name uses the `__` prefix.
    case reservedCollection = 10
    /// Name has a NUL byte or interior `__`.
    case invalidName = 11
    /// Argument outside its domain, the FFI's own NULL/UTF-8 discipline
    /// (FFI.md §7) — and this binding's use-after-close /
    /// use-after-consume guards.
    case argument = 12
    /// Foreign format version.
    case incompatibleFormat = 13
    /// PQ create with no training vectors — every PQ training-domain
    /// failure folds here (`m == 0`, `k` outside `2..=256`,
    /// `dim % m != 0`, mixed dimensions, no usable vectors).
    case emptyIndexTraining = 14
    /// Write violates the declared schema.
    case schemaViolation = 15
    /// Malformed / unknown-version dump.
    case invalidDump = 16
    /// Backup path already exists.
    case backupTargetExists = 17
    /// I/O error (dump/load paths, files).
    case io = 18
    /// FFI-only: `compact()` while derived handles are still open.
    case busy = 19

    /// Maps an ABI code; an appended unknown code reads as `ok` (the
    /// frozen table grows by append only — the message still carries
    /// the detail).
    public static func of(_ raw: UInt32) -> CorvidErrorCode {
        CorvidErrorCode(rawValue: raw) ?? .ok
    }
}

/// The failure surface of every API call, carrying the engine's error
/// code and message (read in the same call that failed).
///
///     do {
///         let db = try Corvid.open(path)
///     } catch let e as CorvidError where e.code == .schemaViolation {
///         // ...
///     }
public struct CorvidError: Error, CustomStringConvertible {
    public let code: CorvidErrorCode
    public let message: String

    public init(code: CorvidErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "[\(code.rawValue)] \(message)" }
}

/// Reads the thread-local last error IMMEDIATELY (the same-call
/// guarantee, FFI.md §3) and returns it as a `CorvidError`.
func lastError() -> CorvidError {
    let raw = corvid_last_error_code().rawValue
    var len: Int = 0
    let msgPtr = corvid_last_error_message(&len)
    let message = msgPtr.map {
        String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer($0), count: len), as: UTF8.self)
    } ?? ""
    return CorvidError(code: CorvidErrorCode.of(raw), message: message)
}

/// Converts a CORVID_ERR status into a thrown `CorvidError`, reading
/// the detail in the same call that failed.
func check(_ status: corvid_status) throws {
    if status != CORVID_OK { throw lastError() }
}
