import Foundation

/// Production countdown state, intentionally independent of AppKit and wall
/// time. A new/replaced block's first tick is zero; neither a prior block nor
/// an empty/hidden interval can supply time that predates that block.
struct BufferAutoSendClock {
    private struct Entry {
        let text: String
        var age: TimeInterval = 0
        var lastUptime: TimeInterval?
    }

    private var sourceIdentity: ObjectIdentifier?
    private var workspaceID: String?
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []

    var ages: [UUID: TimeInterval] { entries.mapValues(\.age) }

    mutating func reset() { self = Self() }

    mutating func pause() {
        for id in order { entries[id]?.lastUptime = nil }
    }

    /// Called on every workbench refresh, not just timer ticks. This observes
    /// an empty drain or same-ID text replacement even between two timer fires.
    mutating func synchronize(sourceIdentity: ObjectIdentifier,
                              workspaceID: String,
                              blocks: [BufferModel.Block]) {
        if self.sourceIdentity != sourceIdentity || self.workspaceID != workspaceID {
            reset()
            self.sourceIdentity = sourceIdentity
            self.workspaceID = workspaceID
        }
        order = blocks.map(\.id)
        let liveIDs = Set(order)
        entries = entries.filter { liveIDs.contains($0.key) }
        for block in blocks where entries[block.id]?.text != block.text {
            entries[block.id] = Entry(text: block.text)
        }
    }

    /// Returns the ready head without removing its age. Only actual source
    /// consumption, reconciled above, can retire a successfully sent block.
    mutating func tick(uptime: TimeInterval,
                       canAge: Bool,
                       lifetime: TimeInterval) -> UUID? {
        guard canAge, uptime.isFinite, lifetime > 0 else {
            pause()
            return nil
        }
        for id in order {
            guard var entry = entries[id] else { continue }
            let elapsed = entry.lastUptime.map { uptime - $0 } ?? 0
            entry.age = min(lifetime, entry.age + min(max(elapsed, 0), lifetime))
            entry.lastUptime = uptime
            entries[id] = entry
        }
        guard let head = order.first,
              (entries[head]?.age ?? 0) >= lifetime else { return nil }
        return head
    }
}

/// Automatic delivery is a Default-buffer behaviour. A plugin workspace
/// decides for itself when its output is finished — translation emits a unit
/// once it resolves, stream input delivers on the boundaries it chose — and a
/// countdown layered on top of that competed with the plugin instead of
/// serving the user. Music has no delivery rail at all.
enum BufferAutoSendAvailabilityRules {
    static func isAvailable(pluginSelected: Bool, musicSelected: Bool) -> Bool {
        !pluginSelected && !musicSelected
    }
}
