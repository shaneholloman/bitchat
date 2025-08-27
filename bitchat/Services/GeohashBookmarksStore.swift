import Foundation
import Combine

/// Stores a user-maintained list of bookmarked geohash channels.
/// - Persistence: UserDefaults (JSON string array)
/// - Semantics: geohashes are normalized to lowercase base32 and de-duplicated
final class GeohashBookmarksStore: ObservableObject {
    static let shared = GeohashBookmarksStore()

    @Published private(set) var bookmarks: [String] = []

    private let storeKey = "locationChannel.bookmarks"
    private var membership: Set<String> = []

    private init() {
        load()
    }

    // MARK: - Public API
    func isBookmarked(_ geohash: String) -> Bool {
        return membership.contains(Self.normalize(geohash))
    }

    func toggle(_ geohash: String) {
        let gh = Self.normalize(geohash)
        if membership.contains(gh) {
            remove(gh)
        } else {
            add(gh)
        }
    }

    func add(_ geohash: String) {
        let gh = Self.normalize(geohash)
        guard !gh.isEmpty else { return }
        guard !membership.contains(gh) else { return }
        bookmarks.insert(gh, at: 0)
        membership.insert(gh)
        persist()
    }

    func remove(_ geohash: String) {
        let gh = Self.normalize(geohash)
        guard membership.contains(gh) else { return }
        if let idx = bookmarks.firstIndex(of: gh) { bookmarks.remove(at: idx) }
        membership.remove(gh)
        persist()
    }

    // MARK: - Persistence
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return }
        if let arr = try? JSONDecoder().decode([String].self, from: data) {
            // Sanitize, normalize, dedupe while preserving order (first occurrence wins)
            var seen = Set<String>()
            var list: [String] = []
            for raw in arr {
                let gh = Self.normalize(raw)
                guard !gh.isEmpty else { continue }
                if !seen.contains(gh) {
                    seen.insert(gh)
                    list.append(gh)
                }
            }
            bookmarks = list
            membership = seen
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    // MARK: - Helpers
    private static func normalize(_ s: String) -> String {
        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
        return s
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
            .filter { allowed.contains($0) }
    }

    #if DEBUG
    /// Testing-only reset helper
    func _resetForTesting() {
        bookmarks.removeAll()
        membership.removeAll()
        persist()
    }
    #endif
}
