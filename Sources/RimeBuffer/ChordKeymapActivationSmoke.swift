import Foundation

/// Queues the asynchronous engine boundary while exercising the real
/// coordinator, generated-file preparation and file rollback in a temp tree.
private final class ChordKeymapActivationSmokeRuntime {
    struct PendingDeployment {
        let profile: ChordKeymapProfile
        let completion: (Bool) -> Void
    }

    let root: URL
    let files: ChordKeymapRuntimeFiles
    let activeURL: URL
    let originalSchema: Data
    let originalList: Data
    let originalActive: Data
    var active: ChordKeymapProfile
    var selectedSchemaID: String
    var enabled = true
    var engineReady = true
    var recovery: String?
    var failPreparation = false
    var failPreparationRestoration = false
    var failRestore = false
    var failActivation = false
    var events: [String] = []
    var resumedEnabledStates: [Bool] = []
    var pending: [PendingDeployment] = []

    init(root: URL, previous: ChordKeymapProfile, selection: String) throws {
        self.root = root
        files = ChordKeymapRuntimeFiles(root: root)
        activeURL = root.appendingPathComponent("applied-profile.json")
        active = previous
        selectedSchemaID = selection
        originalSchema = Data(try ChordKeymapCompiler.schemaYAML(for: previous).utf8)
        originalList = Data("patch:\n  schema_list:\n    - schema: rime_ice\n    - schema: \(previous.schemaID)\n  menu:\n    page_size: 7\n".utf8)
        originalActive = try JSONEncoder().encode(previous)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try files.writeSchema(for: previous)
        try originalList.write(to: root.appendingPathComponent("default.custom.yaml"), options: .atomic)
        try originalActive.write(to: activeURL, options: .atomic)
    }

    var runtime: ChordKeymapActivationCoordinator.Runtime {
        ChordKeymapActivationCoordinator.Runtime(
            isEnabled: { self.enabled },
            startEngine: { self.events.append("start"); return self.engineReady },
            activeProfile: { self.active },
            selectedSchemaID: { self.selectedSchemaID },
            prepare: { profile in
                self.events.append("prepare")
                if self.failPreparationRestoration {
                    try self.files.writeSchema(for: profile)
                    throw ChordKeymapActivationError.restorationFailed("injected preparation restoration failure")
                }
                if self.failPreparation { throw ChordKeymapActivationError.message("injected preparation failure") }
                return try self.files.prepare(profile)
            },
            restore: { snapshot in
                self.events.append("restore")
                if self.failRestore { throw ChordKeymapActivationError.message("injected restoration failure") }
                try self.files.restore(snapshot)
            },
            activate: { profile in
                self.events.append("activate")
                // The production store atomically publishes disk before cache;
                // a persistence error cannot update its active in-memory value.
                if self.failActivation { throw ChordKeymapActivationError.message("injected persistence failure") }
                try JSONEncoder().encode(profile).write(to: self.activeURL, options: .atomic)
                self.active = profile
            },
            selectSchema: { id in
                self.events.append("select")
                self.selectedSchemaID = id
            },
            deployAndVerify: { profile, completion in
                self.events.append("deploy")
                self.pending.append(PendingDeployment(profile: profile, completion: completion))
            },
            publish: { event in
                switch event {
                case .willChange: self.events.append("willChange")
                case .maintenanceWillBegin: self.events.append("maintenanceWillBegin")
                case .didChange: self.events.append("didChange")
                case .maintenanceDidEnd:
                    self.events.append("maintenanceDidEnd")
                    self.resumedEnabledStates.append(self.enabled)
                }
            },
            invalidateSchemaCache: { self.events.append("invalidateCache") },
            recoveryMessage: { self.recovery },
            setRecoveryMessage: { message in
                self.events.append(message == nil ? "clearRecovery" : "setRecovery")
                self.recovery = message
            },
            disableChord: {
                self.events.append("disable")
                self.enabled = false
                self.selectedSchemaID = "rime_ice"
            }
        )
    }

    func finishDeployment(deployed: Bool = true, verified: Bool) {
        let request = pending.removeFirst()
        events.append("deployed")
        if deployed { events.append("verify") }
        request.completion(deployed && verified)
    }

    func originalFilesRestored(for profile: ChordKeymapProfile) throws -> Bool {
        try Data(contentsOf: root.appendingPathComponent(profile.schemaID + ".schema.yaml")) == originalSchema
            && Data(contentsOf: root.appendingPathComponent("default.custom.yaml")) == originalList
            && Data(contentsOf: activeURL) == originalActive
    }
}

func runChordKeymapActivationSmokeTest() -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    func fail(_ message: String) -> Bool {
        print("chord-keymap-activation-smoke: FAIL \(message)")
        return false
    }
    func failed(_ result: Result<Void, Error>?) -> Bool {
        if case .failure? = result { return true }
        return false
    }
    func succeeded(_ result: Result<Void, Error>?) -> Bool {
        if case .success? = result { return true }
        return false
    }
    func precedes(_ first: String, _ second: String, in events: [String]) -> Bool {
        guard let firstIndex = events.firstIndex(of: first),
              let secondIndex = events.firstIndex(of: second) else { return false }
        return firstIndex < secondIndex
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rimes-chord-activation-smoke-\(UUID().uuidString.lowercased())", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let previous = try ChordKeymapProfile(
            id: "8b6f221d-705e-4f51-a876-b46d23439244", name: "原方案",
            leftKeys: "q", rightKeys: "y",
            mappings: [ChordKeymapEntry(keys: "qy", output: "ni", kind: .syllable)]
        ).validated()
        let candidate = try ChordKeymapProfile(
            id: "f6be038a-7b74-4da0-99ab-7e1a4ea73668", name: "新方案",
            leftKeys: "q", rightKeys: "y",
            mappings: [ChordKeymapEntry(keys: "qy", output: "hao", kind: .syllable)]
        ).validated()
        var revised = previous
        revised.mappings[0].output = "hao"

        // New profiles publish only after successful deployment verification;
        // applying an optional map does not replace an ordinary current schema.
        do {
            let box = try ChordKeymapActivationSmokeRuntime(
                root: root.appendingPathComponent("success-ordinary"), previous: previous,
                selection: "rime_ice"
            )
            box.recovery = "旧错误"
            let coordinator = ChordKeymapActivationCoordinator(runtime: box.runtime)
            var result: Result<Void, Error>?
            coordinator.apply(profile: candidate) { result = $0; box.events.append("completion") }
            guard result == nil, coordinator.isApplying, box.active == previous,
                  box.pending.map(\.profile) == [candidate],
                  box.events == ["start", "willChange", "maintenanceWillBegin", "prepare", "deploy"] else {
                return fail("activation or session resume occurred before verification")
            }
            let beforeOverlap = box.events
            var overlap: Result<Void, Error>?
            coordinator.apply(profile: previous) { overlap = $0 }
            guard failed(overlap), box.events == beforeOverlap, box.pending.count == 1 else {
                return fail("overlapping apply must not start another transaction")
            }
            box.finishDeployment(verified: true)
            guard succeeded(result), !coordinator.isApplying, box.active == candidate,
                  box.selectedSchemaID == "rime_ice", box.recovery == nil,
                  !box.events.contains("select"),
                  box.resumedEnabledStates == [true],
                  Array(box.events.suffix(8)) == ["deployed", "verify", "activate", "clearRecovery",
                                                 "invalidateCache", "didChange", "maintenanceDidEnd", "completion"],
                  try JSONDecoder().decode(ChordKeymapProfile.self, from: Data(contentsOf: box.activeURL)) == candidate else {
                return fail("successful activation ordering/ordinary selection/durable snapshot")
            }
        }

        do {
            let box = try ChordKeymapActivationSmokeRuntime(
                root: root.appendingPathComponent("success-chord"), previous: previous,
                selection: previous.schemaID
            )
            let coordinator = ChordKeymapActivationCoordinator(runtime: box.runtime)
            var result: Result<Void, Error>?
            coordinator.apply(profile: candidate) { result = $0 }
            box.finishDeployment(verified: true)
            guard succeeded(result), box.selectedSchemaID == candidate.schemaID,
                  precedes("activate", "select", in: box.events),
                  precedes("select", "maintenanceDidEnd", in: box.events) else {
                return fail("previous chord selection must retarget before sessions resume")
            }
        }

        // A failed verification restores the exact list/schema bytes before a
        // second asynchronous verification of the old profile can resume input.
        do {
            let box = try ChordKeymapActivationSmokeRuntime(
                root: root.appendingPathComponent("verify-failure"), previous: previous,
                selection: previous.schemaID
            )
            let coordinator = ChordKeymapActivationCoordinator(runtime: box.runtime)
            var result: Result<Void, Error>?
            coordinator.apply(profile: candidate) { result = $0 }
            box.finishDeployment(verified: false)
            guard result == nil, coordinator.isApplying, box.active == previous,
                  box.pending.map(\.profile) == [previous],
                  !box.events.contains("activate"), box.resumedEnabledStates.isEmpty,
                  try box.originalFilesRestored(for: previous),
                  !FileManager.default.fileExists(atPath: box.root.appendingPathComponent(candidate.schemaID + ".schema.yaml").path) else {
                return fail("failed new profile must restore bytes before recovery verification")
            }
            box.finishDeployment(verified: true)
            guard failed(result), !coordinator.isApplying, box.enabled,
                  box.selectedSchemaID == previous.schemaID, box.resumedEnabledStates == [true] else {
                return fail("verified rollback must keep original active schema")
            }
        }

        // Same-ID edits overwrite a generated source. Both unsuccessful deploy
        // and unsuccessful old-profile verification must disable chord routing.
        do {
            let box = try ChordKeymapActivationSmokeRuntime(
                root: root.appendingPathComponent("same-id-recovery-failure"), previous: previous,
                selection: previous.schemaID
            )
            let coordinator = ChordKeymapActivationCoordinator(runtime: box.runtime)
            var result: Result<Void, Error>?
            coordinator.apply(profile: revised) { result = $0 }
            guard try Data(contentsOf: box.root.appendingPathComponent(previous.schemaID + ".schema.yaml")) != box.originalSchema else {
                return fail("same-ID fixture must actually replace the generated schema")
            }
            box.finishDeployment(deployed: false, verified: false)
            guard box.pending.map(\.profile) == [previous],
                  try box.originalFilesRestored(for: previous) else {
                return fail("same-ID rollback must restore the old source and applied snapshot")
            }
            box.finishDeployment(verified: false)
            guard failed(result), !coordinator.isApplying, !box.enabled,
                  box.selectedSchemaID == "rime_ice", coordinator.recoveryMessage != nil,
                  box.resumedEnabledStates == [false],
                  precedes("disable", "didChange", in: box.events) else {
                return fail("failed recovery must disable custom routes before sessions resume")
            }
        }

        do {
            let box = try ChordKeymapActivationSmokeRuntime(
                root: root.appendingPathComponent("restore-failure"), previous: previous,
                selection: previous.schemaID
            )
            box.failRestore = true
            let coordinator = ChordKeymapActivationCoordinator(runtime: box.runtime)
            var result: Result<Void, Error>?
            coordinator.apply(profile: revised) { result = $0 }
            box.finishDeployment(verified: false)
            guard failed(result), box.pending.isEmpty, !box.enabled,
                  box.active == previous, box.selectedSchemaID == "rime_ice",
                  box.resumedEnabledStates == [false], coordinator.recoveryMessage != nil else {
                return fail("restoration failure must not reopen a mismatched same-ID schema")
            }
        }

        do {
            let box = try ChordKeymapActivationSmokeRuntime(
                root: root.appendingPathComponent("persistence-failure"), previous: previous,
                selection: previous.schemaID
            )
            box.failActivation = true
            let coordinator = ChordKeymapActivationCoordinator(runtime: box.runtime)
            var result: Result<Void, Error>?
            coordinator.apply(profile: revised) { result = $0 }
            box.finishDeployment(verified: true)
            guard result == nil, coordinator.isApplying,
                  box.pending.map(\.profile) == [previous], box.active == previous,
                  precedes("activate", "restore", in: box.events),
                  try box.originalFilesRestored(for: previous) else {
                return fail("activation persistence error must enter verified rollback")
            }
            box.finishDeployment(verified: true)
            guard failed(result), box.enabled, box.selectedSchemaID == previous.schemaID,
                  box.resumedEnabledStates == [true] else {
                return fail("persistence error must retain the old working profile")
            }
        }

        do {
            let box = try ChordKeymapActivationSmokeRuntime(
                root: root.appendingPathComponent("prepare-restoration-failure"), previous: previous,
                selection: previous.schemaID
            )
            box.failPreparationRestoration = true
            let coordinator = ChordKeymapActivationCoordinator(runtime: box.runtime)
            var result: Result<Void, Error>?
            coordinator.apply(profile: revised) { result = $0 }
            guard failed(result), !coordinator.isApplying, box.pending.isEmpty,
                  box.active == previous, box.selectedSchemaID == "rime_ice",
                  box.resumedEnabledStates == [false], coordinator.recoveryMessage != nil,
                  precedes("disable", "maintenanceDidEnd", in: box.events) else {
                return fail("partial preparation with failed restoration must disable before resuming")
            }
        }

        // Early guards cannot publish lifecycle events or mutate files. A
        // preparation failure that restores its own transaction still resumes.
        do {
            let box = try ChordKeymapActivationSmokeRuntime(
                root: root.appendingPathComponent("early-failures"), previous: previous,
                selection: "rime_ice"
            )
            let coordinator = ChordKeymapActivationCoordinator(runtime: box.runtime)
            var result: Result<Void, Error>?
            coordinator.extensionDeploymentInProgress = true
            coordinator.apply(profile: candidate) { result = $0 }
            guard failed(result), box.events.isEmpty else { return fail("extension deployment overlap") }
            coordinator.extensionDeploymentInProgress = false
            box.enabled = false
            coordinator.apply(profile: candidate) { result = $0 }
            guard failed(result), box.events.isEmpty else { return fail("disabled extension guard") }
            box.enabled = true
            box.engineReady = false
            coordinator.apply(profile: candidate) { result = $0 }
            guard failed(result), box.events == ["start"] else { return fail("engine unavailable guard") }
            box.engineReady = true
            box.failPreparation = true
            box.events.removeAll()
            coordinator.apply(profile: candidate) { result = $0 }
            guard failed(result), !coordinator.isApplying, box.pending.isEmpty,
                  box.active == previous, box.resumedEnabledStates == [true],
                  try box.originalFilesRestored(for: previous) else {
                return fail("preparation error must preserve pre-transaction files and active state")
            }
        }
    } catch {
        return fail(error.localizedDescription)
    }
    print("chord-keymap-activation-smoke: PASS")
    return true
}
