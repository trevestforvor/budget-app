import Foundation

/// FNV-1a: a fast, stable, non-cryptographic hash for ids that must come out the same on every run and platform
/// (Swift's `Hasher` is seeded per process). Never use it to hide a secret or an account number; that needs a keyed
/// HMAC on the server.
public enum StableHash {
    public static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    /// A second seed, for the high half of `hex128`.
    static let secondSeed: UInt64 = 0x84222325cbf29ce4
    static let prime: UInt64 = 0x100_0000_01b3

    /// 64-bit FNV-1a over the UTF-8 bytes of `text`.
    public static func fnv1a64(_ text: String, seed: UInt64 = offsetBasis) -> UInt64 {
        var hash = seed
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// 32 hex digits: two FNV-1a passes with different seeds, each zero-padded to 16.
    public static func hex128(_ text: String) -> String {
        padded(fnv1a64(text, seed: secondSeed)) + padded(fnv1a64(text))
    }

    /// 12 hex digits, zero-padded: enough to tell a few thousand things apart.
    public static func short(_ text: String) -> String {
        String(padded(fnv1a64(text)).suffix(12))
    }

    static func padded(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
