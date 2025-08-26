//
// ReadReceiptTracker.swift
// bitchat
//
// Centralized tracker for sent read receipts with simple persistence.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

final class ReadReceiptTracker {
    private let defaults: UserDefaults
    private let key = "sentReadReceipts"
    private let queue = DispatchQueue(label: "chat.bitchat.readreceipts", attributes: .concurrent)
    private var set: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            self.set = Set(arr)
        }
    }

    func contains(_ id: String) -> Bool {
        queue.sync { set.contains(id) }
    }

    func insert(_ id: String) {
        queue.async(flags: .barrier) {
            if self.set.insert(id).inserted { self.persist() }
        }
    }

    func insert<S: Sequence>(_ ids: S) where S.Element == String {
        queue.async(flags: .barrier) {
            var changed = false
            for id in ids { changed = self.set.insert(id).inserted || changed }
            if changed { self.persist() }
        }
    }

    func remove(_ id: String) {
        queue.async(flags: .barrier) {
            if self.set.remove(id) != nil { self.persist() }
        }
    }

    func removeAll() {
        queue.async(flags: .barrier) {
            if !self.set.isEmpty { self.set.removeAll(); self.persist() }
        }
    }

    /// Keep only IDs present in the allow-list; useful for pruning stale entries.
    func prune(toAllowedIDs allowed: Set<String>) {
        queue.async(flags: .barrier) {
            let newSet = self.set.intersection(allowed)
            if newSet.count != self.set.count { self.set = newSet; self.persist() }
        }
    }

    /// Snapshot current set for read-only operations (avoid long-lived copies in hot paths)
    func snapshot() -> Set<String> { queue.sync { set } }

    private func persist() {
        let arr = Array(set)
        if let data = try? JSONEncoder().encode(arr) {
            defaults.set(data, forKey: key)
        } else {
            SecureLogger.log("❌ Failed to encode read receipts for persistence",
                             category: SecureLogger.session, level: .error)
        }
    }
}

