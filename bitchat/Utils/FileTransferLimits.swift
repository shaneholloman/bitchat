import Foundation

/// Centralized thresholds for Bluetooth file transfers to keep payload sizes sane on constrained radios.
enum FileTransferLimits {
    /// Absolute ceiling enforced for any file payload (voice, image, other).
    static let maxPayloadBytes: Int = 8 * 1024 * 1024 // 8 MiB
    /// Voice notes stay small for low-latency relays.
    static let maxVoiceNoteBytes: Int = 2 * 1024 * 1024 // 2 MiB
    /// Compressed images after downscaling should comfortably fit under this budget.
    static let maxImageBytes: Int = 4 * 1024 * 1024 // 4 MiB

    static func isValidPayload(_ size: Int) -> Bool {
        size <= maxPayloadBytes
    }
}
