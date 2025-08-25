import Foundation

/// Centralized knobs for transport- and UI-related limits.
/// Keep values aligned with existing behavior when replacing magic numbers.
enum TransportConfig {
    // BLE / Protocol
    static let bleDefaultFragmentSize: Int = 469            // ~512 MTU minus protocol overhead
    static let messageTTLDefault: UInt8 = 7                 // Default TTL for mesh flooding
    static let bleMaxInFlightAssemblies: Int = 128          // Cap concurrent fragment assemblies
    static let bleHighDegreeThreshold: Int = 6              // For adaptive TTL/probabilistic relays

    // UI / Storage Caps
    static let privateChatCap: Int = 1337
    static let meshTimelineCap: Int = 1337
    static let geoTimelineCap: Int = 1337
    static let contentLRUCap: Int = 2000

    // Timers
    static let networkResetGraceSeconds: TimeInterval = 600 // 10 minutes
    static let basePublicFlushInterval: TimeInterval = 0.08  // ~12.5 fps batching

    // BLE duty/announce/connect
    static let bleConnectRateLimitInterval: TimeInterval = 0.5
    static let bleMaxCentralLinks: Int = 6
    static let bleDutyOnDuration: TimeInterval = 5.0
    static let bleDutyOffDuration: TimeInterval = 10.0
    static let bleAnnounceMinInterval: TimeInterval = 1.0
}
