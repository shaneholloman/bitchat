import Foundation

/// Lightweight background counter for location notes (kind 1) at block-level geohash.
@MainActor
final class LocationNotesCounter: ObservableObject {
    static let shared = LocationNotesCounter()

    @Published private(set) var geohash: String? = nil
    @Published private(set) var count: Int? = nil

    private var subscriptionID: String? = nil
    private var noteIDs = Set<String>()

    private init() {}

    func subscribe(geohash gh: String) {
        let norm = gh.lowercased()
        if geohash == norm { return }
        cancel()
        geohash = norm
        count = nil
        noteIDs.removeAll()

        let subID = "locnotes-count-\(norm)-\(UUID().uuidString.prefix(6))"
        subscriptionID = subID
        let filter = NostrFilter.geohashNotes(norm, since: nil, limit: 500)
        let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: norm, count: TransportConfig.nostrGeoRelayCount)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: relays) { [weak self] event in
            guard let self = self else { return }
            guard event.kind == NostrProtocol.EventKind.textNote.rawValue else { return }
            guard event.tags.contains(where: { $0.count >= 2 && $0[0].lowercased() == "g" && $0[1].lowercased() == norm }) else { return }
            if !self.noteIDs.contains(event.id) {
                self.noteIDs.insert(event.id)
                self.count = self.noteIDs.count
            }
        }
    }

    func cancel() {
        if let sub = subscriptionID {
            NostrRelayManager.shared.unsubscribe(id: sub)
        }
        subscriptionID = nil
        geohash = nil
        count = nil
        noteIDs.removeAll()
    }
}

