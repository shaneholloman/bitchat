import Foundation

/// Directory of online Nostr relays with approximate GPS locations, used for geohash routing.
struct GeoRelayDirectory {
    struct Entry: Hashable {
        let host: String
        let lat: Double
        let lon: Double
    }

    static let shared = GeoRelayDirectory()
    private let entries: [Entry]

    private init() {
        self.entries = GeoRelayDirectory.loadEntries()
    }

    /// Returns up to `count` relay URLs (wss://) closest to the geohash center.
    func closestRelays(toGeohash geohash: String, count: Int = 5) -> [String] {
        let center = Geohash.decodeCenter(geohash)
        return closestRelays(toLat: center.lat, lon: center.lon, count: count)
    }

    /// Returns up to `count` relay URLs (wss://) closest to the given coordinate.
    func closestRelays(toLat lat: Double, lon: Double, count: Int = 5) -> [String] {
        guard !entries.isEmpty else { return [] }
        let sorted = entries
            .sorted { a, b in
                haversineKm(lat, lon, a.lat, a.lon) < haversineKm(lat, lon, b.lat, b.lon)
            }
            .prefix(count)
        return sorted.map { "wss://\($0.host)" }
    }

    // MARK: - Loading
    private static func loadEntries() -> [Entry] {
        // Try bundled resource first
        if let url = Bundle.main.url(forResource: "online_relays_gps", withExtension: "csv") ??
                     Bundle.main.url(forResource: "online_relays_gps", withExtension: "csv", subdirectory: "relays"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            return parseCSV(text)
        }
        // Try filesystem path (development/test environments)
        if let cwd = FileManager.default.currentDirectoryPath as String?,
           let data = try? Data(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent("relays/online_relays_gps.csv")),
           let text = String(data: data, encoding: .utf8) {
            return parseCSV(text)
        }
        // No data available
        SecureLogger.log("GeoRelayDirectory: relay CSV not found; falling back to default relay set", category: SecureLogger.session, level: .warning)
        return []
    }

    private static func parseCSV(_ text: String) -> [Entry] {
        var result: Set<Entry> = []
        let lines = text.split(whereSeparator: { $0.isNewline })
        // Skip header if present
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if idx == 0 && line.lowercased().contains("relay url") { continue }
            let parts = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            let host = parts[0].replacingOccurrences(of: "wss://", with: "")
            guard let lat = Double(parts[1]), let lon = Double(parts[2]) else { continue }
            result.insert(Entry(host: host, lat: lat, lon: lon))
        }
        return Array(result)
    }
}

// MARK: - Distance
private func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let r = 6371.0 // Earth radius in km
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat/2) * sin(dLat/2) + cos(lat1 * .pi/180) * cos(lat2 * .pi/180) * sin(dLon/2) * sin(dLon/2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return r * c
}
