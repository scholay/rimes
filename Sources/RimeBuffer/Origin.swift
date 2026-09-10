import Foundation

/// Where a buffer block came from. This is the first-class provenance the
/// workbench is built on: it drives the source badge in the UI, the echo
/// guard on delivery, and (later) per-source gating. Kept minimal for M1 —
/// the `.processor` case arrives with the processor subsystem (M3).
enum Origin: Equatable {
    /// Local Rime commit — the only origin that exists before the workbench.
    case rime
    /// Typed into the workbench's own field while another input method owned
    /// the keyboard. Still the user typing locally — the distinction from
    /// `.rime` is which input method composed it, which matters for a log
    /// read weeks later and for nothing else.
    case localInput(inputSourceID: String)
    /// Text explicitly imported from the system pasteboard while the workbench
    /// is operating without an IMK capture target.
    case clipboard
    /// Marine local-agent draft (transitional; folds into `.mcp` once Marine
    /// moves onto the MCP gateway).
    case marine
    /// A user-invoked workbench action supplied by an installed process-outside
    /// plugin. The identifier comes from the plugin manifest and is display /
    /// provenance data only; plugins never receive an IMK client reference.
    case plugin(id: String)
    /// A trusted in-process transform. The mirror bit is inherited from every
    /// source block used to derive the result, preventing remote-peer text from
    /// being translated and echoed back to the originating Mac.
    case processor(id: String, allowsRemoteMirror: Bool)
    /// Model Context Protocol client (a local agent). `client` is its self-
    /// reported, unverified name — for display only.
    case mcp(client: String)
    /// Plain HTTP push into the local gateway.
    case http(source: String)
    /// Subscribed external Server-Sent-Events feed.
    case sse(feed: String)
    /// Streamed stdout of an `ssh <host> <command>` child process.
    case ssh(host: String)
    /// Text received from a paired Mac over the encrypted LAN channel.
    case remotePeer(deviceID: String)

    /// Whether a block of this origin may be mirrored to the paired Mac on
    /// delivery. Text that CAME from a peer must never be echoed back, or two
    /// paired Macs bounce it forever — this is the echo guard, in one place.
    /// Everything else (local typing, agent drafts, network sources) mirrors
    /// as before.
    var allowsRemoteMirror: Bool {
        switch self {
        case .remotePeer: return false
        case let .processor(_, allowsRemoteMirror): return allowsRemoteMirror
        default: return true
        }
    }

    /// Short tag for logs — never the content, only the provenance.
    var tag: String {
        switch self {
        case .rime: return "rime"
        case let .localInput(inputSourceID): return "local:\(inputSourceID)"
        case .clipboard: return "clipboard"
        case .marine: return "marine"
        case let .plugin(id): return "plugin:\(id)"
        case let .processor(id, _): return "processor:\(id)"
        case .mcp: return "mcp"
        case .http: return "http"
        case .sse: return "sse"
        case .ssh: return "ssh"
        case .remotePeer: return "remote"
        }
    }
}
