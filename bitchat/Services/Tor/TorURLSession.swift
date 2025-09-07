import Foundation
#if os(macOS)
import CFNetwork
#endif

/// Provides a shared URLSession that routes traffic via Tor's SOCKS5 proxy
/// when Tor is enforced/ready. Falls back to a default session only when
/// compiled with the `BITCHAT_DEV_ALLOW_CLEARNET` flag.
final class TorURLSession {
    static let shared = TorURLSession()

    // Default (no proxy) session for local development when dev bypass is enabled.
    private lazy var defaultSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // Proxied (SOCKS5) session that routes through Tor.
    private lazy var torSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        // Keep in sync with TorManager defaults
        let host = "127.0.0.1"
        let port = 39050
        #if os(macOS)
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: host,
            kCFNetworkProxiesSOCKSPort as String: port
        ]
        #else
        // iOS: CFNetwork SOCKS proxy keys are unavailable at compile time.
        // Using the documented string keys keeps the build green. On some iOS
        // versions, URLSession may ignore per-session SOCKS; we still enforce
        // Tor via fail-closed gating and can add platform-specific transport
        // if needed.
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": port
        ]
        #endif
        return URLSession(configuration: cfg)
    }()

    var session: URLSession {
        #if BITCHAT_DEV_ALLOW_CLEARNET
        // Dev bypass: use direct session. Call sites may still await Tor if desired.
        return defaultSession
        #else
        // Production: always use the Tor-proxied session. Call sites ensure readiness.
        return torSession
        #endif
    }
}
