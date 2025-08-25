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

    // BLE discovery/quality thresholds
    static let bleDynamicRSSIThresholdDefault: Int = -90
    static let bleConnectionCandidatesMax: Int = 20
    static let blePendingWriteBufferCapBytes: Int = 1_000_000

    // Nostr
    static let nostrReadAckInterval: TimeInterval = 0.35 // ~3 per second

    // UI thresholds
    static let uiLateInsertThreshold: TimeInterval = 15.0
    static let uiProcessedNostrEventsCap: Int = 2000

    // BLE maintenance & thresholds
    static let bleMaintenanceInterval: TimeInterval = 10.0
    static let bleMaintenanceLeewaySeconds: Int = 1
    static let bleIsolationRelaxThresholdSeconds: TimeInterval = 60
    static let bleRecentTimeoutWindowSeconds: TimeInterval = 60
    static let bleRecentTimeoutCountThreshold: Int = 3
    static let bleRSSIIsolatedBase: Int = -90
    static let bleRSSIIsolatedRelaxed: Int = -92
    static let bleRSSIConnectedThreshold: Int = -85
    static let bleRSSIHighTimeoutThreshold: Int = -80

    // Location
    static let locationDistanceFilterMeters: Double = 1000
    static let locationLiveRefreshInterval: TimeInterval = 5.0

    // Nostr geohash
    static let nostrGeohashInitialLookbackSeconds: TimeInterval = 3600
    static let nostrGeohashInitialLimit: Int = 200
    static let nostrGeoRelayCount: Int = 5

    // Compression
    static let compressionThresholdBytes: Int = 100

    // Message deduplication
    static let messageDedupMaxAgeSeconds: TimeInterval = 300
    static let messageDedupMaxCount: Int = 1000

    // Verification QR
    static let verificationQRMaxAgeSeconds: TimeInterval = 5 * 60

    // Nostr relay backoff
    static let nostrRelayInitialBackoffSeconds: TimeInterval = 1.0
    static let nostrRelayMaxBackoffSeconds: TimeInterval = 300.0
    static let nostrRelayBackoffMultiplier: Double = 2.0
    static let nostrRelayMaxReconnectAttempts: Int = 10
    static let nostrRelayDefaultFetchLimit: Int = 100

    // Geo relay directory
    static let geoRelayFetchIntervalSeconds: TimeInterval = 60 * 60 * 24

    // BLE operational delays
    static let bleInitialAnnounceDelaySeconds: TimeInterval = 2.0
    static let bleConnectTimeoutSeconds: TimeInterval = 8.0
    static let bleRestartScanDelaySeconds: TimeInterval = 0.1
    static let blePostSubscribeAnnounceDelaySeconds: TimeInterval = 0.1
    static let blePostAnnounceDelaySeconds: TimeInterval = 0.4
}
