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
    @Published private(set) var isReady: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var lastError: Error?
    @Published private(set) var bootstrapProgress: Int = 0
    @Published private(set) var bootstrapSummary: String = ""

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

    private init() {}

    // MARK: - Public API

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        isStarting = true
        lastError = nil
        ensureFilesystemLayout()
        startTor()
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
        // Start control-port monitor and probe readiness asynchronously
        startControlMonitorIfNeeded()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
                self.isReady = ready
                self.isStarting = false
                if !ready {
                    self.lastError = NSError(domain: "TorManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "Tor SOCKS not reachable after dlopen start"])
                    SecureLogger.log("TorManager: SOCKS not reachable (timeout)", category: SecureLogger.session, level: .error)
                } else {
                    SecureLogger.log("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: SecureLogger.session, level: .info)
                }
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
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
                self.isReady = ready
                self.isStarting = false
                if ready {
                    SecureLogger.log("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: SecureLogger.session, level: .info)
                } else {
                    self.lastError = NSError(domain: "TorManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "Tor SOCKS not reachable after static start"])
                    SecureLogger.log("TorManager: SOCKS not reachable (timeout)", category: SecureLogger.session, level: .error)
                }
            }
        }
        return true
    }
    
    // MARK: - ControlPort monitoring (bootstrap progress)
    private func startControlMonitorIfNeeded() {
        #if os(iOS)
        // iOS: no-op; we skip ControlPort monitoring to keep startup lean.
        return
        #else
        guard !controlMonitorStarted else { return }
        controlMonitorStarted = true
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.controlMonitorLoop()
        }
        #endif
    }

    private func controlMonitorLoop() async {
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            if await self.tryControlSessionOnce() { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func tryControlSessionOnce() async -> Bool {
        guard let cookiePath = dataDirectoryURL()?.appendingPathComponent("control_auth_cookie") else { return false }
        guard let cookie = try? Data(contentsOf: cookiePath) else { return false }
        let cookieHex = cookie.map { String(format: "%02X", $0) }.joined()

        var inStream: InputStream?
        var outStream: OutputStream?
        Stream.getStreamsToHost(withName: controlHost, port: controlPort, inputStream: &inStream, outputStream: &outStream)
        guard let input = inStream, let output = outStream else { return false }
        input.open(); output.open()

        func send(_ s: String) {
            let bytes = Array(s.utf8)
            _ = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: bytes.count)
            }
        }
        func readLine(timeout: TimeInterval = 3.0) -> String? {
            var data = Data()
            let start = Date()
            var buf = [UInt8](repeating: 0, count: 1024)
            while Date().timeIntervalSince(start) < timeout {
                if input.hasBytesAvailable {
                    let n = input.read(&buf, maxLength: buf.count)
                    if n > 0 {
                        data.append(buf, count: n)
                        if let range = data.range(of: Data([13,10])) { // CRLF
                            let lineData = data.prefix(upTo: range.lowerBound)
                            let line = String(data: lineData, encoding: .utf8)
                            let rest = data.suffix(from: range.upperBound)
                            data = Data(rest)
                            return line
                        }
                    } else if n == 0 {
                        break
                    }
                }
                usleep(20_000)
            }
            return nil
        }

        // Greeting
        _ = readLine()
        send("AUTHENTICATE \(cookieHex)\r\n")
        guard let auth = readLine(), auth.hasPrefix("250") else {
            input.close(); output.close(); return false
        }
        send("SETEVENTS STATUS_CLIENT\r\n")
        _ = readLine() // 250 OK

        while true {
            if Task.isCancelled { break }
            guard let line = readLine(timeout: 10.0) else { continue }
            if line.hasPrefix("650 ") && line.contains("BOOTSTRAP") {
                var progress = self.bootstrapProgress
                var summary = self.bootstrapSummary
                for part in line.split(separator: " ") {
                    if part.hasPrefix("PROGRESS=") {
                        progress = Int(part.split(separator: "=").last ?? "0") ?? progress
                    } else if part.hasPrefix("SUMMARY=") {
                        let raw = String(part.dropFirst("SUMMARY=".count))
                        summary = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }
                await MainActor.run {
                    self.bootstrapProgress = progress
                    self.bootstrapSummary = summary
                }
                if progress >= 100 { break }
            }
        }

        input.close(); output.close()
        return true
    }
}
