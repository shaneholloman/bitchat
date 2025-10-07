# Proper ChatViewModel Re-Architecture Vision

**Date:** 2025-10-07
**Purpose:** Design the RIGHT architecture for ChatViewModel decomposition

---

## Current State (The Problem)

```
ChatViewModel: 5,355 lines
Responsibilities: EVERYTHING
- UI state management
- Message sending (mesh + Nostr + DMs)
- Message receiving (mesh + Nostr + DMs)
- Channel management (mesh ↔ geohash switching)
- Peer management
- Verification flows
- Favorites management
- Command processing
- Autocomplete
- Location handling
- Emergency panic
- Nostr integration
- Bluetooth state
- Plus ~50 more things

Pattern: GOD OBJECT anti-pattern
```

---

## Proper Architecture (The Solution)

### Core Principle: **Coordinators + Services + Repositories**

```
ChatViewModel (target: < 1,000 lines)
    - ONLY UI state (@Published properties)
    - ONLY thin coordination between layers
    - NO business logic
    - NO direct service calls
    ├── Coordinators/ (Business logic orchestration)
    │   ├── MessageCoordinator
    │   ├── ChannelCoordinator
    │   ├── PeerCoordinator
    │   └── VerificationCoordinator
    ├── Services/ (Domain logic)
    │   ├── Formatting, Colors, etc.
    │   └── ... (existing)
    └── Repositories/ (Data access)
        ├── MessageRepository
        ├── PeerRepository
        └── ChannelRepository
```

---

## Layer 1: ChatViewModel (< 1,000 lines) - UI State ONLY

### Responsibilities
```swift
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Coordinators (inject, don't create)
    private let messageCoordinator: MessageCoordinator
    private let channelCoordinator: ChannelCoordinator
    private let peerCoordinator: PeerCoordinator
    private let verificationCoordinator: VerificationCoordinator

    // MARK: - UI State (@Published ONLY)
    @Published var messages: [BitchatMessage] = []
    @Published var selectedChannel: ChannelID = .mesh
    @Published var selectedPrivateChatPeer: String? = nil
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteSuggestions: [String] = []
    @Published var connectedPeers: [BitchatPeer] = []
    @Published var showBluetoothAlert: Bool = false
    @Published var bluetoothAlertMessage: String = ""
    // ... ~15-20 @Published properties for UI state

    // MARK: - User Actions (thin wrappers)
    func sendMessage(_ content: String) {
        messageCoordinator.sendMessage(content)
    }

    func switchChannel(_ channel: ChannelID) {
        channelCoordinator.switchTo(channel)
    }

    func startPrivateChat(with peerID: String) {
        messageCoordinator.startPrivateChat(with: peerID)
    }

    func verifyPeer(_ peerID: String) {
        verificationCoordinator.verify(peerID)
    }

    // ... ~30-40 thin wrapper functions
}
```

**Size:** ~800-1,000 lines
**Purpose:** UI state + thin coordination
**No business logic whatsoever**

---

## Layer 2: Coordinators (Business Logic Orchestration)

### MessageCoordinator (~500 lines)

```swift
@MainActor
final class MessageCoordinator {
    // MARK: - Dependencies
    private weak var viewModel: ChatViewModel?
    private let meshService: Transport
    private let nostrService: NostrMessageService
    private let messageRepository: MessageRepository
    private let formatter: MessageFormattingService

    // MARK: - Public API
    func sendMessage(_ content: String) {
        // 1. Validate
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // 2. Route based on context
        if let peer = viewModel?.selectedPrivateChatPeer {
            sendPrivateMessage(content, to: peer)
        } else {
            sendPublicMessage(content)
        }
    }

    private func sendPublicMessage(_ content: String) {
        switch viewModel?.selectedChannel {
        case .mesh:
            sendMeshMessage(content)
        case .location(let ch):
            sendGeohashMessage(content, channel: ch)
        case nil:
            break
        }
    }

    private func sendPrivateMessage(_ content: String, to peerID: String) {
        // Route: Bluetooth if connected, Nostr if mutual favorite, error otherwise
        if meshService.isPeerConnected(PeerID(str: peerID)) {
            sendMeshDM(content, to: peerID)
        } else if isMutualFavorite(peerID) {
            sendNostrDM(content, to: peerID)
        } else {
            viewModel?.showError("Cannot send - peer not connected")
        }
    }

    func receiveMessage(_ message: BitchatMessage) {
        // 1. Validate (spam filter, blocking, etc.)
        guard shouldAccept(message) else { return }

        // 2. Process (format, cache, etc.)
        let processed = processMessage(message)

        // 3. Store
        messageRepository.save(processed)

        // 4. Notify ViewModel
        viewModel?.updateMessages(messageRepository.getVisible())
    }

    // ... ~400 more lines of message orchestration
}
```

**Responsibilities:**
- Message sending (all transports)
- Message receiving (all transports)
- Message routing (mesh vs Nostr vs DM)
- Message validation
- Delivery tracking
- Read receipts

**Does NOT:**
- Hold UI state
- Know about SwiftUI
- Access ViewModel properties directly

---

### ChannelCoordinator (~300 lines)

```swift
@MainActor
final class ChannelCoordinator {
    // MARK: - Dependencies
    private weak var viewModel: ChatViewModel?
    private let locationService: LocationChannelManager
    private let nostrService: NostrMessageService
    private let channelRepository: ChannelRepository

    // MARK: - Public API
    func switchTo(_ channel: ChannelID) {
        // 1. Unsubscribe from old channel
        unsubscribeFromCurrent()

        // 2. Update state
        channelRepository.setActive(channel)

        // 3. Subscribe to new channel
        subscribe(to: channel)

        // 4. Load message history
        let messages = channelRepository.getMessages(for: channel)
        viewModel?.updateMessages(messages)

        // 5. Update participants
        switch channel {
        case .mesh:
            updateMeshParticipants()
        case .location(let ch):
            updateGeohashParticipants(ch.geohash)
        }
    }

    private func subscribe(to channel: ChannelID) {
        switch channel {
        case .mesh:
            // Mesh is always active
            break
        case .location(let ch):
            subscribeToGeohash(ch.geohash)
        }
    }

    private func subscribeToGeohash(_ geohash: String) {
        // 1. Derive Nostr identity for this geohash
        guard let identity = try? NostrIdentityBridge.deriveIdentity(forGeohash: geohash) else { return }

        // 2. Subscribe to Nostr events for this geohash
        nostrService.subscribe(
            geohash: geohash,
            identity: identity,
            onMessage: { [weak self] event in
                self?.handleGeohashMessage(event)
            }
        )
    }

    // ... ~250 more lines of channel orchestration
}
```

**Responsibilities:**
- Channel switching (mesh ↔ geohash)
- Channel subscriptions (Nostr)
- Channel-specific message loading
- Participant tracking per channel
- Timeline management

**Does NOT:**
- Send messages
- Handle DMs
- Know about UI rendering

---

### PeerCoordinator (~300 lines)

```swift
@MainActor
final class PeerCoordinator {
    // MARK: - Dependencies
    private weak var viewModel: ChatViewModel?
    private let meshService: Transport
    private let peerRepository: PeerRepository
    private let identityManager: SecureIdentityStateManagerProtocol
    private let favoritesService: FavoritesPersistenceService

    // MARK: - Public API
    func updatePeerList() {
        // 1. Get mesh peers
        let meshPeers = meshService.currentPeerSnapshots()

        // 2. Get favorites (including offline)
        let favorites = favoritesService.favorites

        // 3. Merge into unified peer list
        let unified = peerRepository.unifyPeers(mesh: meshPeers, favorites: favorites)

        // 4. Update ViewModel
        viewModel?.updatePeers(unified)
    }

    func toggleFavorite(_ peerID: String) {
        // 1. Get peer's Noise public key
        guard let peer = peerRepository.get(peerID) else { return }

        // 2. Update favorites
        if peer.isFavorite {
            favoritesService.removeFavorite(peerNoisePublicKey: peer.noisePublicKey)
        } else {
            favoritesService.addFavorite(
                peerNoisePublicKey: peer.noisePublicKey,
                peerNickname: peer.nickname
            )
        }

        // 3. Refresh peer list
        updatePeerList()
    }

    func block(_ peerID: String) {
        identityManager.setBlocked(peerID, isBlocked: true)
        peerRepository.remove(peerID)
        viewModel?.updatePeers(peerRepository.getAll())
    }

    // ... ~250 more lines of peer management
}
```

**Responsibilities:**
- Peer list management
- Favorites handling
- Blocking/unblocking
- Peer state updates
- Connection tracking

**Does NOT:**
- Send/receive messages
- Handle channels
- Know about verification

---

### VerificationCoordinator (~200 lines)

```swift
@MainActor
final class VerificationCoordinator {
    // MARK: - Dependencies
    private weak var viewModel: ChatViewModel?
    private let meshService: Transport
    private let identityManager: SecureIdentityStateManagerProtocol
    private let verificationService: VerificationService

    // MARK: - State
    private var pendingVerifications: [String: PendingVerification] = [:]

    // MARK: - Public API
    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        // 1. Find matching peer by Noise key
        guard let peer = findPeer(by: qr.noiseKeyHex) else { return false }

        // 2. Generate challenge nonce
        let nonce = generateNonce()

        // 3. Store pending verification
        pendingVerifications[peer.peerID.id] = PendingVerification(
            noiseKeyHex: qr.noiseKeyHex,
            signKeyHex: qr.signKeyHex,
            nonceA: nonce,
            startedAt: Date()
        )

        // 4. Send challenge
        meshService.sendVerifyChallenge(to: peer.peerID, noiseKeyHex: qr.noiseKeyHex, nonceA: nonce)

        return true
    }

    func handleVerifyChallenge(from peerID: String, payload: Data) {
        // 1. Parse TLV
        guard let tlv = verificationService.parseVerifyChallenge(payload) else { return }

        // 2. Check rate limiting
        guard !isRateLimited(peerID) else { return }

        // 3. Send response
        meshService.sendVerifyResponse(to: PeerID(str: peerID), noiseKeyHex: tlv.noiseKeyHex, nonceA: tlv.nonceA)
    }

    func handleVerifyResponse(from peerID: String, payload: Data) {
        // 1. Get pending verification
        guard let pending = pendingVerifications[peerID] else { return }

        // 2. Parse and verify signature
        guard let resp = verificationService.parseVerifyResponse(payload),
              verificationService.verifySignature(resp, with: pending.signKeyHex, nonce: pending.nonceA) else {
            viewModel?.showError("Verification failed - invalid signature")
            pendingVerifications.removeValue(forKey: peerID)
            return
        }

        // 3. Mark as verified
        identityManager.setVerified(fingerprint: pending.noiseKeyHex.sha256(), verified: true)

        // 4. Update ViewModel
        viewModel?.markPeerVerified(peerID)

        // 5. Clean up
        pendingVerifications.removeValue(forKey: peerID)
    }

    // ... ~150 more lines
}
```

**Responsibilities:**
- QR code verification flow
- Challenge/response handling
- Verified state management
- Rate limiting verification attempts

**Does NOT:**
- Send regular messages
- Manage peers
- Handle channels

---

## Layer 3: Services (Domain Logic)

### Already Good (Keep These)
```
✅ MessageFormattingService (618 lines) - Message rendering
✅ ColorPaletteService (328 lines) - Peer colors
✅ SpamFilterService (222 lines) - Rate limiting
```

### New Services Needed

#### NostrMessageService (~400 lines)
```swift
final class NostrMessageService {
    // All Nostr-specific message logic
    func sendDM(content: String, to pubkey: String) async throws -> String
    func receiveDM(_ giftWrap: NostrEvent) async throws -> DecryptedMessage
    func sendPublicEvent(content: String, geohash: String) async throws
    func subscribeToChannel(_ geohash: String, handler: @escaping (NostrEvent) -> Void)
    // ... handles ALL Nostr message protocol details
}
```

#### MeshMessageService (~200 lines)
```swift
final class MeshMessageService {
    // All mesh-specific message logic
    func sendPublic(content: String, mentions: [String])
    func sendPrivate(content: String, to peerID: String)
    func receivePublic(_ packet: BitchatPacket)
    func receivePrivate(_ packet: BitchatPacket)
    // ... handles ALL mesh message protocol details
}
```

---

## Layer 4: Repositories (Data Access)

### MessageRepository (~200 lines)
```swift
@MainActor
final class MessageRepository {
    // MARK: - Storage
    private var meshTimeline: [BitchatMessage] = []
    private var geoTimelines: [String: [BitchatMessage]] = [:]
    private var privateChats: [String: [BitchatMessage]] = [:]

    // MARK: - Public API
    func save(_ message: BitchatMessage, to channel: ChannelID)
    func getMessages(for channel: ChannelID) -> [BitchatMessage]
    func getPrivateChat(with peerID: String) -> [BitchatMessage]
    func clearChannel(_ channel: ChannelID)

    // Handles all message storage, capping, trimming
    // NO business logic, JUST data access
}
```

### PeerRepository (~150 lines)
```swift
@MainActor
final class PeerRepository {
    // MARK: - Storage
    private var peers: [String: BitchatPeer] = [:]
    private var peerIndex: [String: BitchatPeer] = [:]

    // MARK: - Public API
    func save(_ peer: BitchatPeer)
    func get(_ peerID: String) -> BitchatPeer?
    func getAll() -> [BitchatPeer]
    func remove(_ peerID: String)
    func unifyPeers(mesh: [MeshPeer], favorites: [Favorite]) -> [BitchatPeer]

    // Handles all peer storage
    // NO business logic, JUST data access
}
```

### ChannelRepository (~100 lines)
```swift
@MainActor
final class ChannelRepository {
    // MARK: - Storage
    private var activeChannel: ChannelID = .mesh
    private var subscriptions: [String: String] = [:]

    // MARK: - Public API
    func setActive(_ channel: ChannelID)
    func getActive() -> ChannelID
    func saveSubscription(id: String, for channel: String)
    func getSubscriptions() -> [String: String]

    // Handles channel state storage
    // NO business logic, JUST data access
}
```

---

## Data Flow Architecture

### Sending a Message (Example)

```
User types "hello" in UI
    ↓
1. ContentView calls viewModel.sendMessage("hello")
    ↓
2. ChatViewModel delegates to messageCoordinator.sendMessage("hello")
    ↓
3. MessageCoordinator:
    a. Gets active channel from channelRepository
    b. Determines transport (mesh or Nostr)
    c. Creates BitchatMessage
    d. Saves to messageRepository
    e. Calls appropriate service:
       - MeshMessageService.sendPublic() for mesh
       - NostrMessageService.sendPublicEvent() for geohash
    ↓
4. Service handles protocol details, returns result
    ↓
5. MessageCoordinator updates messageRepository with delivery status
    ↓
6. messageRepository notifies observers
    ↓
7. ChatViewModel @Published properties update
    ↓
8. SwiftUI re-renders
```

**Benefits:**
- Clear responsibilities at each layer
- Easy to test (mock repositories)
- Easy to swap implementations
- Single Responsibility Principle
- Testable business logic

---

## Receiving a Message (Example)

```
Bluetooth packet arrives
    ↓
1. BLEService decrypts, creates BitchatPacket
    ↓
2. BLEService calls delegate: didReceivePublicMessage(message)
    ↓
3. ChatViewModel implements BitchatDelegate:
    func didReceivePublicMessage(_ message: BitchatMessage) {
        messageCoordinator.receiveMessage(message)
    }
    ↓
4. MessageCoordinator:
    a. Validates message (spam filter)
    b. Checks if blocked
    c. Determines target (public/private)
    d. Processes (formatting cached for later)
    e. Saves to messageRepository
    f. Updates delivery status if DM
    ↓
5. messageRepository notifies ChatViewModel
    ↓
6. ChatViewModel updates @Published messages
    ↓
7. SwiftUI re-renders
```

---

## Comparison: Current vs Proper

### Current Architecture (BAD)
```
ChatViewModel (5,355 lines)
├── Does EVERYTHING
├── Mixes UI state with business logic
├── Directly calls services
├── Holds all data
├── Impossible to test
└── Unmaintainable

Testing requires:
- Mock BLEService
- Mock NostrRelayManager
- Mock 10+ other services
- Set up entire app state
= IMPOSSIBLE in practice
```

### Proper Architecture (GOOD)
```
ChatViewModel (< 1,000 lines)
├── ONLY UI state
├── Delegates to coordinators
├── No business logic
└── Easy to test

MessageCoordinator (~500 lines)
├── Orchestrates message flows
├── Uses repositories for data
├── Uses services for logic
└── Testable with mocked dependencies

MessageRepository (~200 lines)
├── ONLY data access
├── No business logic
└── Trivial to test

Testing MessageCoordinator:
- Mock MessageRepository (easy)
- Mock MeshMessageService (easy)
- Mock NostrMessageService (easy)
= Actually testable!
```

---

## Migration Strategy

### Phase 1: Create Repositories (1 week)
```
1. MessageRepository (~200 lines)
   - Extract all message storage from ChatViewModel
   - Move meshTimeline, geoTimelines, privateChats

2. PeerRepository (~150 lines)
   - Extract all peer storage
   - Move peers, peerIndex, etc.

3. ChannelRepository (~100 lines)
   - Extract channel state
   - Move activeChannel, subscriptions

Result: ChatViewModel ~4,900 lines
No behavior change, just data layer separation
```

### Phase 2: Create Coordinators (2 weeks)
```
1. MessageCoordinator (~500 lines)
   - Extract all message sending logic
   - Extract all message receiving logic
   - Extract routing logic

2. ChannelCoordinator (~300 lines)
   - Extract channel switching
   - Extract subscription management
   - Extract geohash logic

3. PeerCoordinator (~300 lines)
   - Extract peer management
   - Extract favorites logic
   - Extract blocking logic

4. VerificationCoordinator (~200 lines)
   - Extract QR verification
   - Extract fingerprint management

Result: ChatViewModel ~3,600 lines
Major architectural improvement
```

### Phase 3: Thin ViewModel (1 week)
```
1. Move remaining logic to coordinators
2. ChatViewModel becomes pure UI state
3. All @Published properties for UI
4. Thin wrappers only

Result: ChatViewModel ~800-1,000 lines
Clean architecture achieved
```

**Total timeline: 4-5 weeks of focused work**

---

## Alternative: Hybrid Approach (Pragmatic)

If full re-architecture is too much:

### Keep What Works
```
✅ MessageFormattingService (good)
✅ ColorPaletteService (good)
✅ SpamFilterService (good)
✅ GeohashParticipantsService (OK)
❌ Delete DeliveryTrackingService (merge back)
❌ Delete SystemMessagingService (merge back)
```

### Extract Just 2-3 BIG Coordinators
```
1. MessageSendingCoordinator (~450 lines)
   - All sendMessage() variants
   - Routing logic
   - Message creation

2. ChannelCoordinator (~300 lines)
   - Channel switching
   - Subscriptions
   - Timeline management

3. (Optional) VerificationCoordinator (~200 lines)
   - QR verification flow
```

**Result:** ChatViewModel ~4,100 lines in 2-3 days
**Benefit:** Major improvement without full re-architecture

---

## My Recommendation

### Option A: Merge PR #1, Plan Full Re-Architecture
```
Timeline: 4-5 weeks
Effort: HIGH
Risk: MEDIUM
Benefit: Professional-grade architecture

Steps:
1. Merge PR #1 (get wins now)
2. Design proper architecture (1 week)
3. Create repositories (1 week)
4. Create coordinators (2 weeks)
5. Thin ViewModel (1 week)
```

### Option B: Extract 1-2 Big Coordinators Now
```
Timeline: 1-2 days
Effort: MEDIUM
Risk: MEDIUM
Benefit: Significant improvement

Steps:
1. Extract MessageSendingCoordinator (462 lines) - 3 hours
2. Extract ChannelCoordinator (300 lines) - 2 hours
3. Test thoroughly - 1 hour

Result: ~4,600 lines, < 5,000 milestone achieved
```

### Option C: Stop Here
```
Timeline: Now
Effort: ZERO
Risk: ZERO
Benefit: Consolidate wins

PR #1 delivers:
- 3 good services
- 100% memory safety
- Good documentation
- Solid foundation
```

---

## What I Recommend RIGHT NOW

**Option C: Stop and merge PR #1.**

**Why:**
- We've worked 6+ hours
- PR #1 has real value (3 good services + memory fixes)
- You've learned what works (big extractions) and what doesn't (tiny ones)
- Proper coordinator extraction needs fresh energy and careful design
- Better to ship wins now, plan next phase properly

**Then:**
- Take a break
- Review PR #1 with team
- Plan proper coordinator architecture separately
- Execute when fresh with 2-3 focused days

---

**But if you want to push:** I can extract MessageSendingCoordinator (462 lines) right now in ~2 hours. It would hit < 5,000 milestone.

**Your choice?**
