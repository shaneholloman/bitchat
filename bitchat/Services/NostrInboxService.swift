//
// NostrInboxService.swift
// bitchat
//
// Centralizes Nostr subscribe/unsubscribe and event de-duplication for inbox flows.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

@MainActor
final class NostrInboxService {
    private var processedIDs: Set<String> = []
    private var order: [String] = []
    private let cap: Int

    init(capacity: Int = TransportConfig.uiProcessedNostrEventsCap) {
        self.cap = capacity
    }

    private func track(_ id: String) -> Bool {
        if processedIDs.contains(id) { return false }
        processedIDs.insert(id)
        order.append(id)
        if order.count > cap {
            let overflow = order.count - cap
            for _ in 0..<overflow {
                if let oldest = order.first {
                    order.removeFirst()
                    processedIDs.remove(oldest)
                }
            }
        }
        return true
    }

    func reset() {
        processedIDs.removeAll()
        order.removeAll()
    }

    // Subscribe to public geohash ephemeral events (kind 20000)
    @discardableResult
    func subscribeGeohashEphemeral(
        geohash: String,
        lookbackSeconds: TimeInterval,
        limit: Int,
        relayCount: Int,
        subID: String? = nil,
        handler: @escaping (NostrEvent) -> Void
    ) -> String {
        let id = subID ?? "geo-\(geohash)"
        let filter = NostrFilter.geohashEphemeral(
            geohash,
            since: Date().addingTimeInterval(-lookbackSeconds),
            limit: limit
        )
        let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: geohash, count: relayCount)
        NostrRelayManager.shared.subscribe(filter: filter, id: id, relayUrls: relays) { [weak self] event in
            guard let self = self else { return }
            guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
            guard self.track(event.id) else { return }
            handler(event)
        }
        return id
    }

    // Subscribe to gift wraps (DMs) for a given pubkey
    @discardableResult
    func subscribeGiftWrapsFor(
        pubkeyHex: String,
        lookbackSeconds: TimeInterval,
        subID: String? = nil,
        handler: @escaping (NostrEvent) -> Void
    ) -> String {
        let id = subID ?? "dm-\(pubkeyHex.prefix(8))"
        let filter = NostrFilter.giftWrapsFor(pubkey: pubkeyHex, since: Date().addingTimeInterval(-lookbackSeconds))
        NostrRelayManager.shared.subscribe(filter: filter, id: id) { [weak self] event in
            guard let self = self else { return }
            guard self.track(event.id) else { return }
            handler(event)
        }
        return id
    }

    func unsubscribe(id: String) {
        NostrRelayManager.shared.unsubscribe(id: id)
    }
}
