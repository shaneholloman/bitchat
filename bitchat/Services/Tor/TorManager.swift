import Foundation
import Network
import Darwin

// Declare C entrypoint for Tor when statically linked from an xcframework.
@_silgen_name("tor_main")
private func tor_main_c(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

/// Minimal Tor integration scaffold.
/// - Boots a local Tor client (once integrated) and exposes a SOCKS5 proxy
///   on 127.0.0.1:socksPort. All app networking should await readiness and
///   route via this proxy. Fails closed by default when Tor is unavailable.
/// - Drop-in ready: add your Tor framework and complete `startTor()`.
@MainActor
final class TorManager: ObservableObject {
    static let shared = TorManager()

    // SOCKS endpoint where the embedded Tor should listen.
    let socksHost: String = "127.0.0.1"
    let socksPort: Int = 39050

    // Optional ControlPort for debugging/diagnostics once Tor is integrated.
    let controlHost: String = "127.0.0.1"
    let controlPort: Int = 39051

    // State
    // True only when SOCKS is reachable AND bootstrap has reached 100%.
    @Published private(set) var isReady: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var lastError: Error?
    @Published private(set) var bootstrapProgress: Int = 0
    @Published private(set) var bootstrapSummary: String = ""
    
    // Internal readiness trackers
    private var socksReady: Bool = false { didSet { recomputeReady() } }
    private var restarting: Bool = false

    // Whether the app must enforce Tor for all connections (fail-closed).
    // This is the default. For local development, you may compile with
    // `-DBITCHAT_DEV_ALLOW_CLEARNET` to temporarily allow direct network.
    var torEnforced: Bool {
        #if BITCHAT_DEV_ALLOW_CLEARNET
        return false
        #else
        return true
        #endif
    }

    // Returns true only when Tor is actually up (or dev fallback is compiled).
    var networkPermitted: Bool {
        if torEnforced { return isReady }
        // Dev bypass allows network even if Tor is not running
        return true
    }

    private var didStart = false
    private var controlMonitorStarted = false
    private var pathMonitor: NWPathMonitor?

    private init() {}

    // MARK: - Public API

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        isStarting = true
        lastError = nil
        ensureFilesystemLayout()
        startTor()
        startPathMonitorIfNeeded()
    }

    /// Await Tor bootstrap to readiness. Returns true if network is permitted (Tor ready or dev bypass).
    /// Nonisolated to avoid blocking the main actor during waits.
    nonisolated func awaitReady(timeout: TimeInterval = 25.0) async -> Bool {
        await MainActor.run { self.startIfNeeded() }
        let deadline = Date().addingTimeInterval(timeout)
        // Early exit if network already permitted
        if await MainActor.run(body: { self.networkPermitted }) { return true }
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if await MainActor.run(body: { self.networkPermitted }) { return true }
        }
        return await MainActor.run(body: { self.networkPermitted })
    }

    // MARK: - Filesystem (torrc + data dir)

    func dataDirectoryURL() -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("bitchat/tor", isDirectory: true)
            return dir
        } catch {
            return nil
        }
    }

    func torrcURL() -> URL? {
        dataDirectoryURL()?.appendingPathComponent("torrc")
    }

    private func ensureFilesystemLayout() {
        guard let dir = dataDirectoryURL() else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Always (re)write torrc at launch so DataDirectory is correct for this container
            if let torrc = torrcURL() {
                try torrcTemplate().data(using: .utf8)?.write(to: torrc, options: .atomic)
            }
        } catch {
            // Non-fatal; Tor will surface errors during start if paths are missing
        }
    }

    /// Minimal, safe torrc for an embedded client.
    func torrcTemplate() -> String {
        var lines: [String] = []
        if let dir = dataDirectoryURL()?.path {
            lines.append("DataDirectory \(dir)")
        }
        lines.append("ClientOnly 1")
        lines.append("SOCKSPort \(socksHost):\(socksPort)")
        lines.append("ControlPort \(controlHost):\(controlPort)")
        lines.append("CookieAuthentication 1")
        lines.append("AvoidDiskWrites 1")
        lines.append("MaxClientCircuitsPending 8")
        // Keep defaults for guard/exit selection to preserve anonymity properties
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Integration Hook

    /// Start the embedded Tor. This stub intentionally compiles without any Tor dependency.
    /// Integrate your Tor framework here and set `isReady = true` once bootstrapped.
    private func startTor() {
        // If linked statically (xcframework with static framework), call tor_run_main directly.
        if startTorViaLinkedSymbol() { return }

        // Dynamic loading path is intended for dynamic frameworks only.
        if startTorViaDlopen() { return }

        #if BITCHAT_DEV_ALLOW_CLEARNET
        // Dev bypass: permit network immediately (no Tor). Use ONLY for local development.
        self.isReady = true
        self.isStarting = false
        #else
        // Production default: fail closed until Tor framework is dropped in and bootstraps.
        self.isReady = false
        self.isStarting = false
        #endif
    }
    /// Probe the local SOCKS port until it's ready or a timeout elapses.
    private func waitForSocksReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeSocksOnce() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func probeSocksOnce() async -> Bool {
        await withCheckedContinuation { cont in
            let params = NWParameters.tcp
            let host = NWEndpoint.Host.ipv4(.loopback)
            guard let port = NWEndpoint.Port(rawValue: UInt16(socksPort)) else {
                cont.resume(returning: false)
                return
            }
            let endpoint = NWEndpoint.hostPort(host: host, port: port)
            let conn = NWConnection(to: endpoint, using: params)

            var resumed = false
            let resumeOnce: (Bool) -> Void = { value in
                if !resumed {
                    resumed = true
                    cont.resume(returning: value)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(true)
                    conn.cancel()
                case .failed, .cancelled:
                    resumeOnce(false)
                    conn.cancel()
                default:
                    break
                }
            }

            // Failsafe timeout to avoid hanging if no callback occurs
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                resumeOnce(false)
                conn.cancel()
            }

            conn.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    // MARK: - Dynamic loader path (no Swift module required)

    /// Attempt to locate an embedded tor framework binary and launch Tor via `tor_run_main`.
    /// Returns true if the attempt started and port probing was scheduled.
    private func startTorViaDlopen() -> Bool {
        guard let fwURL = frameworkBinaryURL() else {
            SecureLogger.log("TorManager: no embedded tor framework found", category: SecureLogger.session, level: .warning)
            return false
        }

        // Load the library
        let mode = RTLD_NOW | RTLD_LOCAL
        SecureLogger.log("TorManager: dlopen(\(fwURL.lastPathComponent))…", category: SecureLogger.session, level: .info)
        guard let handle = dlopen(fwURL.path, mode) else {
            let err = String(cString: dlerror())
            self.lastError = NSError(domain: "TorManager", code: -10, userInfo: [NSLocalizedDescriptionKey: "dlopen failed: \(err)"])
            self.isStarting = false
            return false
        }

        // Resolve tor_main(argc, argv)
        typealias TorMainType = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        guard let sym = dlsym(handle, "tor_main") else {
            // Keep handle open but report error
            let err = String(cString: dlerror())
            self.lastError = NSError(domain: "TorManager", code: -11, userInfo: [NSLocalizedDescriptionKey: "dlsym tor_main failed: \(err)"])
            self.isStarting = false
            return false
        }
        let torMain = unsafeBitCast(sym, to: TorMainType.self)
        self._dlHandle = handle

        // Prepare args: tor -f <torrc>
        var argv: [String] = ["tor"]
        if let torrc = torrcURL()?.path {
            argv.append(contentsOf: ["-f", torrc])
        }
        // Run Tor on a background thread to avoid blocking the main actor
        SecureLogger.log("TorManager: launching tor_main with torrc", category: SecureLogger.session, level: .info)
        let argc = Int32(argv.count)
        DispatchQueue.global(qos: .utility).async {
            // Build stable C argv in this thread
            let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            let cArgv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count + 1)
            for i in 0..<cStrings.count { cArgv[i] = cStrings[i] }
            cArgv[cStrings.count] = nil

            _ = torMain(argc, cArgv)

            // Free args after exit (Tor usually never returns)
            for ptr in cStrings.compactMap({ $0 }) { free(ptr) }
            cArgv.deallocate()
        }

        // Start control-port monitor and probe readiness asynchronously
        startControlMonitorIfNeeded()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
                self.socksReady = ready
                if !ready {
                    self.lastError = NSError(domain: "TorManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "Tor SOCKS not reachable after dlopen start"])
                    SecureLogger.log("TorManager: SOCKS not reachable (timeout)", category: SecureLogger.session, level: .error)
                } else {
                    SecureLogger.log("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: SecureLogger.session, level: .info)
                }
                // isStarting will be cleared when bootstrap reaches 100%
            }
        }

        return true
    }

    private var _dlHandle: UnsafeMutableRawPointer?

    private func frameworkBinaryURL() -> URL? {
        // Try common embedded locations for the framework binary name
        let candidates = [
            "tor-nolzma.framework/tor-nolzma",
            "Tor.framework/Tor",
        ]
        if let base = Bundle.main.privateFrameworksURL {
            for rel in candidates {
                let url = base.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        // For macOS apps, also try Contents/Frameworks explicitly
        #if os(macOS)
        if let appURL = Bundle.main.bundleURL as URL?,
           let frameworksURL = Optional(appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)) {
            for rel in candidates {
                let url = frameworksURL.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        #endif
        return nil
    }

    // MARK: - Static-link path (no module import)
    private func startTorViaLinkedSymbol() -> Bool {
        // Attempt to start tor_run_main directly (statically linked). If the
        // symbol is not present at link-time, builds will fail — which is
        // expected when the xcframework is absent.
        var argv: [String] = ["tor"]
        if let torrc = torrcURL()?.path { argv.append(contentsOf: ["-f", torrc]) }

        SecureLogger.log("TorManager: starting tor_main (static)", category: SecureLogger.session, level: .info)
        let argc = Int32(argv.count)
        DispatchQueue.global(qos: .utility).async {
            // Build stable C argv in this thread
            let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            let cArgv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count + 1)
            for i in 0..<cStrings.count { cArgv[i] = cStrings[i] }
            cArgv[cStrings.count] = nil

            _ = tor_main_c(argc, cArgv)

            // If tor_main ever returns, free memory
            for ptr in cStrings.compactMap({ $0 }) { free(ptr) }
            cArgv.deallocate()
        }

        // Start control monitor early
        startControlMonitorIfNeeded()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
                self.socksReady = ready
                if ready {
                    SecureLogger.log("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: SecureLogger.session, level: .info)
                } else {
                    self.lastError = NSError(domain: "TorManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "Tor SOCKS not reachable after static start"])
                    SecureLogger.log("TorManager: SOCKS not reachable (timeout)", category: SecureLogger.session, level: .error)
                }
                // isStarting will be cleared when bootstrap reaches 100%
            }
        }
        return true
    }
    
    // MARK: - ControlPort monitoring (bootstrap progress)
    private func startControlMonitorIfNeeded() {
        guard !controlMonitorStarted else { return }
        controlMonitorStarted = true
        // Use a simple GETINFO poll on all platforms to avoid long-lived blocking streams
        Task.detached(priority: .utility) { [weak self] in
            await self?.bootstrapPollLoop()
        }
    }

    private func controlMonitorLoop() async {}

    private func tryControlSessionOnce() async -> Bool { false }

    // iOS: Poll GETINFO periodically to track bootstrap progress without long-lived control readers.
    private func bootstrapPollLoop() async {
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            if let info = await controlGetBootstrapInfo() {
                await MainActor.run {
                    self.bootstrapProgress = info.progress
                    self.bootstrapSummary = info.summary
                    if info.progress >= 100 { self.isStarting = false }
                    self.recomputeReady()
                }
                if info.progress >= 100 { break }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func controlGetBootstrapInfo() async -> (progress: Int, summary: String)? {
        guard let text = await controlExchange(lines: ["GETINFO status/bootstrap-phase"], timeout: 2.0) else { return nil }
        var progress = self.bootstrapProgress
        var summary = self.bootstrapSummary
        // Search entire response for PROGRESS and SUMMARY tokens
        // Typical: "250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=75 TAG=... SUMMARY=\"...\"\r\n250 OK\r\n"
        let tokens = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").split(separator: " ")
        for t in tokens {
            if t.hasPrefix("PROGRESS=") {
                progress = Int(t.split(separator: "=").last ?? "0") ?? progress
            } else if t.hasPrefix("SUMMARY=") {
                let raw = String(t.dropFirst("SUMMARY=".count))
                summary = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return (progress, summary)
    }

    // MARK: - Foreground recovery and control helpers

    func ensureRunningOnForeground() {
        // If we can talk to ControlPort, wake Tor and verify bootstrap; else restart.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Avoid restarts while starting/restarting
            if await MainActor.run(body: { self.isStarting || self.restarting }) { return }
            let ok = await self.controlPingBootstrap()
            if ok {
                _ = await self.controlSendSignal("ACTIVE")
                return
            }
            // If Tor is still bootstrapping (SOCKS up but progress < 100), don't thrash; let monitor update
            let stillBootstrapping = await MainActor.run(body: { self.socksReady && self.bootstrapProgress < 100 })
            if stillBootstrapping { return }
            await self.restartTor()
        }
    }

    func goDormantOnBackground() {
        Task.detached { [weak self] in
            _ = await self?.controlSendSignal("DORMANT")
        }
    }

    private func restartTor() async {
        await MainActor.run { self.restarting = true; self.isReady = false; self.socksReady = false; self.bootstrapProgress = 0; self.bootstrapSummary = ""; self.isStarting = true }
        // Try graceful shutdown if control is reachable
        _ = await controlSendSignal("SHUTDOWN")
        // Wait for SOCKS to go down
        let downDeadline = Date().addingTimeInterval(5)
        while Date() < downDeadline {
            if await !probeSocksOnce() { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await MainActor.run { self.didStart = false }
        await MainActor.run { self.startIfNeeded() }
        await MainActor.run { self.restarting = false }
    }

    private func recomputeReady() {
        let ready = socksReady && bootstrapProgress >= 100
        if ready != isReady {
            isReady = ready
        }
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let queue = DispatchQueue(label: "TorPathMonitor")
        monitor.pathUpdateHandler = { [weak self] _ in
            // On any path change, poke Tor/recover (hop to main actor).
            Task { @MainActor in
                self?.ensureRunningOnForeground()
            }
        }
        monitor.start(queue: queue)
    }

    // Lightweight control: authenticate and GETINFO bootstrap-phase.
    private func controlPingBootstrap(timeout: TimeInterval = 3.0) async -> Bool {
        let data = await controlExchange(lines: ["GETINFO status/bootstrap-phase"], timeout: timeout)
        guard let text = data else { return false }
        return text.contains("status/bootstrap-phase")
    }

    private func controlSendSignal(_ signal: String, timeout: TimeInterval = 3.0) async -> Bool {
        let text = await controlExchange(lines: ["SIGNAL \(signal)"], timeout: timeout)
        return (text?.contains("250")) == true
    }

    private func controlExchange(lines: [String], timeout: TimeInterval) async -> String? {
        guard let cookiePath = dataDirectoryURL()?.appendingPathComponent("control_auth_cookie"),
              let cookie = try? Data(contentsOf: cookiePath) else { return nil }
        let cookieHex = cookie.map { String(format: "%02X", $0) }.joined()

        let queue = DispatchQueue(label: "TorControl", qos: .userInitiated)
        let params = NWParameters.tcp
        guard let port = NWEndpoint.Port(rawValue: UInt16(controlPort)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let conn = NWConnection(to: endpoint, using: params)

        var resultText = ""
        var completed = false
        func send(_ text: String) {
            let data = (text + "\r\n").data(using: .utf8) ?? Data()
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
        func receiveLoop(deadline: Date) async {
            while Date() < deadline {
                let ok: Bool = await withCheckedContinuation { cont in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                        if let data = data, !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                            resultText.append(s)
                        }
                        if isComplete || error != nil { completed = true }
                        cont.resume(returning: true)
                    }
                }
                if !ok || completed { break }
                // Small delay to avoid tight loop
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        conn.start(queue: queue)
        // Send immediately; NWConnection will queue until ready
        send("AUTHENTICATE \(cookieHex)")
        // Send requested lines
        for line in lines { send(line) }
        // Ask tor to close
        send("QUIT")
        await receiveLoop(deadline: Date().addingTimeInterval(timeout))
        conn.cancel()
        return resultText
    }
}
