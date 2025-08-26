//
// NostrOutboxService.swift
// bitchat
//
// Centralized Nostr outbox for sending PMs and ACKs.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

@MainActor
final class NostrOutboxService {
    private let transport: NostrTransport

    init(meshService: Transport) {
        let t = NostrTransport()
        t.senderPeerID = meshService.myPeerID
        self.transport = t
    }

    func sendGeohashPM(content: String, toRecipientHex recipientHex: String, from identity: NostrIdentity, messageID: String) {
        transport.sendPrivateMessageGeohash(content: content, toRecipientHex: recipientHex, from: identity, messageID: messageID)
    }

    func sendGeohashDeliveredAck(messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        transport.sendDeliveryAckGeohash(for: messageID, toRecipientHex: recipientHex, from: identity)
    }

    func sendGeohashReadAck(messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        transport.sendReadReceiptGeohash(messageID, toRecipientHex: recipientHex, from: identity)
    }
}

