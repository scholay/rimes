import Carbon.HIToolbox
import Foundation

/// Live authority for callbacks entering this process through InputMethodKit.
///
/// ETInput stays alive for its global utility-window shortcuts even while a
/// different input source is selected. macOS can still deliver late lifecycle
/// or key callbacks to the old IMK connection during that handoff. Those
/// callbacks must pass through without rebuilding a Rime focus lease or
/// touching the old client.
enum RimeInputSourceAuthority {
    static func isOwnInputSourceID(
        _ inputSourceID: String,
        ownBundleID: String = Bundle.main.bundleIdentifier
            ?? RimesIdentity.bundleIdentifier
    ) -> Bool {
        inputSourceID == ownBundleID
            || inputSourceID.hasPrefix(ownBundleID + ".")
    }

    static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?
            .takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(
                source,
                kTISPropertyInputSourceID
              ) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    /// Query TIS at the callback boundary instead of trusting a notification
    /// cache. The distributed source-change notification can arrive after a
    /// stale activate/key callback, which is precisely the race this gate
    /// closes.
    static func currentSourceIsOwn() -> Bool {
        guard let inputSourceID = currentInputSourceID() else { return false }
        return isOwnInputSourceID(inputSourceID)
    }
}
