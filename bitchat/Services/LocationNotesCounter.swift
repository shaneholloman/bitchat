import Foundation

/// Lightweight background counter for location notes (kind 1) at block-level geohash.
@MainActor
final class LocationNotesCounter: ObservableObject {
    static let shared = LocationNotesCounter()

    @Published private(set) var geohash: String? = nil
    @Published private(set) var count: Int? = 0
    @Published private(set) var initialLoadComplete: Bool = false

    // Support multiple subscriptions (e.g., building + parent block fallback)
    private var subscriptionIDs: Set<String> = []
    private var noteIDs = Set<String>()

    private init() {}

    func subscribe(geohash gh: String) {
        let norm = gh.lowercased()
        if geohash == norm { return }
        cancel()
        geohash = norm
        count = 0
        noteIDs.removeAll()
        initialLoadComplete = false

        // Subscribe to both building and parent block to capture legacy notes
        var targets: [String] = [norm]
        if norm.count >= 8 {
            let parent7 = String(norm.prefix(7))
            if parent7 != norm { targets.append(parent7) }
        }
        var pendingEOSE = Set<String>()
        for target in targets {
            let subID = "locnotes-count-\(target)-\(UUID().uuidString.prefix(6))"
            subscriptionIDs.insert(subID)
            pendingEOSE.insert(subID)
            let filter = NostrFilter.geohashNotes(target, since: nil, limit: 500)
            let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: target, count: TransportConfig.nostrGeoRelayCount)
            NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: relays, handler: { [weak self] event in
                guard let self = self else { return }
                guard event.kind == NostrProtocol.EventKind.textNote.rawValue else { return }
                // Ensure matching g-tag for either building or parent block
                let matches = event.tags.contains(where: { $0.count >= 2 && $0[0].lowercased() == "g" && targets.contains($0[1].lowercased()) })
                guard matches else { return }
                if !self.noteIDs.contains(event.id) {
                    self.noteIDs.insert(event.id)
                    self.count = self.noteIDs.count
                }
            }, onEOSE: { [weak self] in
                guard let self = self else { return }
                pendingEOSE.remove(subID)
                if pendingEOSE.isEmpty { self.initialLoadComplete = true }
            })
        }
    }

    func cancel() {
        for sub in subscriptionIDs { NostrRelayManager.shared.unsubscribe(id: sub) }
        subscriptionIDs.removeAll()
        geohash = nil
        count = 0
        noteIDs.removeAll()
    }
}
