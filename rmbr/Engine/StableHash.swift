import Foundation

/// A hash that is identical across processes and launches.
///
/// Swift's `Hasher` is seeded randomly per process, so it cannot be used to derive an
/// identifier that must be stable across runs. Moment identity, anchor identity and
/// the source fingerprint all need that stability: without it, two compositions of the
/// same unchanged day would disagree, and every cache would miss (RQ-001).
enum StableHash {
    /// FNV-1a, 64 bit.
    static func value(of string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func hex(of string: String) -> String {
        String(value(of: string), radix: 16)
    }

    static func hex(of parts: [String]) -> String {
        hex(of: parts.joined(separator: "\u{1f}"))
    }
}
