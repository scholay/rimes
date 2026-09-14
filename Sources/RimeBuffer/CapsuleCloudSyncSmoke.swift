import CryptoKit
import Foundation

func runCapsuleCloudSyncSmokeTest() -> Bool {
    print("== RIMES Capsule iCloud sync smoke ==")

    let fileManager = FileManager.default
    let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
        "rimes-capsule-cloud-sync-smoke-\(UUID().uuidString)",
        isDirectory: true
    )
    let deviceARoot = fixtureRoot.appendingPathComponent(
        "device-a",
        isDirectory: true
    )
    let deviceBRoot = fixtureRoot.appendingPathComponent(
        "device-b",
        isDirectory: true
    )
    let localARoot = deviceARoot.appendingPathComponent(
        "capsule",
        isDirectory: true
    )
    let localBRoot = deviceBRoot.appendingPathComponent(
        "capsule",
        isDirectory: true
    )
    let cloudRoot = fixtureRoot.appendingPathComponent(
        "fake-icloud",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: fixtureRoot) }

    let baseDate = Date(timeIntervalSince1970: 1_788_200_000)
    let clockA = CapsuleCloudSyncSmokeClock(baseDate)
    let clockB = CapsuleCloudSyncSmokeClock(baseDate)
    let storeA = CapsuleContentStore(
        rootURL: localARoot,
        now: { clockA.value }
    )
    let storeB = CapsuleContentStore(
        rootURL: localBRoot,
        now: { clockB.value }
    )

    do {
        try fileManager.createDirectory(
            at: cloudRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try capsuleCloudSyncSmokeMakeEmpty(storeA)
        try capsuleCloudSyncSmokeMakeEmpty(storeB)

        let libraryID = try CapsuleCloudSyncEngine.prepareLibrary(at: cloudRoot)
        let engineA = CapsuleCloudSyncEngine(
            contentStore: storeA,
            localRootURL: localARoot,
            cloudRootURL: cloudRoot,
            stateURL: deviceARoot.appendingPathComponent("sync/state.json"),
            libraryID: libraryID,
            now: { clockA.value }
        )
        let engineB = CapsuleCloudSyncEngine(
            contentStore: storeB,
            localRootURL: localBRoot,
            cloudRootURL: cloudRoot,
            stateURL: deviceBRoot.appendingPathComponent("sync/state.json"),
            libraryID: libraryID,
            now: { clockB.value }
        )

        let text = try storeA.put(CapsuleContentWriteRequest(
            type: .note,
            title: "Cross-device smoke note",
            content: "initial-text-payload"
        ))
        let firstUpload = try engineA.synchronize()
        guard firstUpload.uploaded == 1,
              firstUpload.downloaded == 0,
              firstUpload.deleted == 0,
              firstUpload.conflicts == 0 else {
            return capsuleCloudSyncSmokeFail("initial text upload counts")
        }

        let firstDownload = try engineB.synchronize()
        guard firstDownload.downloaded == 1,
              firstDownload.uploaded == 0,
              firstDownload.deleted == 0,
              firstDownload.conflicts == 0,
              try storeB.record(id: text.id).content
                == "initial-text-payload" else {
            return capsuleCloudSyncSmokeFail("cross-device text download")
        }
        guard capsuleCloudSyncSmokeIsNoop(try engineA.synchronize()),
              capsuleCloudSyncSmokeIsNoop(try engineB.synchronize()) else {
            return capsuleCloudSyncSmokeFail("idempotent text synchronization")
        }

        // Skill bodies are device-local absolute paths. They must remain in
        // the creating Capsule only and must never leak through cloud entries,
        // cloud conflicts, or the comparison-state cache.
        let sensitiveSkillPath = fixtureRoot.appendingPathComponent(
            "private-workspace/server-keys/skill-fixture",
            isDirectory: true
        ).path
        try fileManager.createDirectory(
            atPath: sensitiveSkillPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let localSkill = try storeA.put(CapsuleContentWriteRequest(
            type: .skill,
            title: "Device-local sensitive Skill",
            content: sensitiveSkillPath
        ))
        let skillSyncA = try engineA.synchronize()
        let skillSyncB = try engineB.synchronize()
        let skillForbiddenBytes = Data(sensitiveSkillPath.utf8)
        let skillLeakSurfaces = try capsuleCloudSyncSmokeRegularFiles(
            below: cloudRoot
        ) + [
            deviceARoot.appendingPathComponent("sync/state.json"),
            deviceBRoot.appendingPathComponent("sync/state.json"),
        ]
        guard skillSyncA.uploaded == 0,
              skillSyncA.deferred == 0,
              skillSyncB.downloaded == 0,
              try storeA.record(id: localSkill.id).content
                == sensitiveSkillPath,
              capsuleCloudSyncSmokeRecordIsAbsent(localSkill.id, in: storeB),
              try skillLeakSurfaces.allSatisfy({ url in
                  try Data(contentsOf: url).range(of: skillForbiddenBytes) == nil
              }) else {
            return capsuleCloudSyncSmokeFail(
                "Skill absolute path remains local-only"
            )
        }

        // Extra front matter is part of the Obsidian-readable source, not
        // disposable product metadata. A direct local edit must cross devices
        // even when title and body stay unchanged.
        let textOnA = try storeA.record(id: text.id)
        var textDocument = try String(
            contentsOf: textOnA.summary.fileURL,
            encoding: .utf8
        )
        textDocument = textDocument.replacingOccurrences(
            of: "updated_at:",
            with: "tags: [\"icloud-smoke\"]\nupdated_at:"
        )
        try Data(textDocument.utf8).write(
            to: textOnA.summary.fileURL,
            options: .atomic
        )
        guard try engineA.synchronize().uploaded == 1,
              try engineB.synchronize().downloaded == 1,
              try String(
                contentsOf: storeB.record(id: text.id).summary.fileURL,
                encoding: .utf8
              ).contains("tags: [\"icloud-smoke\"]"),
              capsuleCloudSyncSmokeIsNoop(try engineA.synchronize()),
              capsuleCloudSyncSmokeIsNoop(try engineB.synchronize()) else {
            return capsuleCloudSyncSmokeFail(
                "Obsidian front matter synchronization"
            )
        }

        // Obsidian or another editor may normalize an ISO-8601 timestamp by
        // removing fractional seconds. Both the cloud codec and the local
        // apply path must accept that standards-compliant spelling.
        let plainDate = try storeA.put(CapsuleContentWriteRequest(
            type: .note,
            title: "Plain ISO-8601 fixture",
            content: "plain-iso8601-cross-device"
        ))
        guard try engineA.synchronize().uploaded == 1 else {
            return capsuleCloudSyncSmokeFail("plain ISO-8601 baseline")
        }
        let plainDateCloudEntry = cloudRoot.appendingPathComponent(
            "v1/entries/\(plainDate.id.uuidString.lowercased()).md"
        )
        var plainDateLines = try String(
            contentsOf: plainDateCloudEntry,
            encoding: .utf8
        ).split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let dateLine = plainDateLines.firstIndex(where: {
            $0.hasPrefix("updated_at:")
        }) else {
            return capsuleCloudSyncSmokeFail("plain ISO-8601 front matter")
        }
        plainDateLines[dateLine] = "updated_at: \"2026-09-01T00:00:00Z\""
        try Data(plainDateLines.joined(separator: "\n").utf8).write(
            to: plainDateCloudEntry,
            options: .atomic
        )
        let plainDateDownload = try engineB.synchronize()
        guard plainDateDownload.downloaded == 1,
              try storeB.record(id: plainDate.id).content
                == "plain-iso8601-cross-device",
              try storeB.record(id: plainDate.id).summary.updatedAt
                == Date(timeIntervalSince1970: 1_788_220_800) else {
            return capsuleCloudSyncSmokeFail(
                "plain ISO-8601 cloud and local apply"
            )
        }

        let sourceDirectory = fixtureRoot.appendingPathComponent(
            "source-media",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let imageData = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x52, 0x49, 0x4d, 0x45, 0x53, 0x2d, 0x49, 0x4d, 0x41, 0x47, 0x45,
        ])
        let pdfData = Data("%PDF-1.4\n% RIMES sync fixture\n%%EOF\n".utf8)
        let sourceImage = sourceDirectory.appendingPathComponent("fixture.png")
        let sourcePDF = sourceDirectory.appendingPathComponent("fixture.pdf")
        try imageData.write(to: sourceImage, options: .atomic)
        try pdfData.write(to: sourcePDF, options: .atomic)

        clockA.value = baseDate.addingTimeInterval(10)
        let image = try storeA.put(CapsuleContentWriteRequest(
            type: .image,
            title: "Cross-device image",
            content: sourceImage.path
        ))
        let pdf = try storeA.put(CapsuleContentWriteRequest(
            type: .pdf,
            title: "Cross-device PDF",
            content: sourcePDF.path
        ))
        let mediaUpload = try engineA.synchronize()
        let mediaDownload = try engineB.synchronize()
        guard mediaUpload.uploaded == 2,
              mediaUpload.conflicts == 0,
              mediaDownload.downloaded == 2,
              mediaDownload.conflicts == 0 else {
            return capsuleCloudSyncSmokeFail("media synchronization counts")
        }

        let downloadedImage = try storeB.record(id: image.id)
        let downloadedPDF = try storeB.record(id: pdf.id)
        let downloadedImageURL = URL(fileURLWithPath: downloadedImage.content)
        let downloadedPDFURL = URL(fileURLWithPath: downloadedPDF.content)
        let localBAssets = localBRoot.appendingPathComponent(
            "assets",
            isDirectory: true
        ).standardizedFileURL.path + "/"
        guard downloadedImage.summary.type == .image,
              downloadedPDF.summary.type == .pdf,
              downloadedImageURL.standardizedFileURL.path
                .hasPrefix(localBAssets),
              downloadedPDFURL.standardizedFileURL.path
                .hasPrefix(localBAssets),
              capsuleCloudSyncSmokeHash(
                try Data(contentsOf: downloadedImageURL)
              ) == capsuleCloudSyncSmokeHash(imageData),
              capsuleCloudSyncSmokeHash(
                try Data(contentsOf: downloadedPDFURL)
              ) == capsuleCloudSyncSmokeHash(pdfData),
              capsuleCloudSyncSmokeIsNoop(try engineA.synchronize()),
              capsuleCloudSyncSmokeIsNoop(try engineB.synchronize()) else {
            return capsuleCloudSyncSmokeFail(
                "media materialization and content hashes"
            )
        }

        // A missing managed cache is self-healing even when the cloud entry
        // itself has not changed.
        try fileManager.removeItem(at: downloadedPDFURL)
        let managedCacheHeal = try engineB.synchronize()
        let healedPDF = try storeB.record(id: pdf.id)
        guard managedCacheHeal.downloaded == 1,
              healedPDF.content == downloadedPDFURL.path,
              fileManager.fileExists(atPath: downloadedPDFURL.path),
              capsuleCloudSyncSmokeHash(
                try Data(contentsOf: downloadedPDFURL)
              ) == capsuleCloudSyncSmokeHash(pdfData) else {
            return capsuleCloudSyncSmokeFail(
                "unchanged cloud entry rematerializes missing managed asset"
            )
        }

        // An external file can be on a removable/offline volume. Its absence
        // must not cause Capsule to rewrite the body into its managed cache.
        let externalPDFOnA = try storeA.record(id: pdf.id)
        guard externalPDFOnA.content == sourcePDF.path else {
            return capsuleCloudSyncSmokeFail("external PDF baseline path")
        }
        try fileManager.removeItem(at: sourcePDF)
        let externalOfflineSync = try engineA.synchronize()
        guard externalOfflineSync.downloaded == 0,
              externalOfflineSync.uploaded == 0,
              try storeA.record(id: pdf.id).content == sourcePDF.path,
              !fileManager.fileExists(atPath: sourcePDF.path) else {
            return capsuleCloudSyncSmokeFail(
                "offline external media path is never rewritten"
            )
        }

        let passwordStore = CapsulePasswordStore(
            rootURL: localARoot,
            now: { clockA.value }
        )
        let password = try passwordStore.put(CapsulePasswordWriteRequest(
            title: "Sync exclusion credential fixture",
            body: "- 密码：credential-sync-smoke-current-secret"
        ))
        guard fileManager.fileExists(atPath: password.fileURL.path),
              fileManager.fileExists(atPath: passwordStore.masterKeyURL.path),
              capsuleCloudSyncSmokeIsNoop(try engineA.synchronize()) else {
            return capsuleCloudSyncSmokeFail("local password fixture creation")
        }
        let masterKey = try Data(contentsOf: passwordStore.masterKeyURL)
        let encryptedPasswordDocument = try Data(contentsOf: password.fileURL)
        let cloudFiles = try capsuleCloudSyncSmokeRegularFiles(
            below: cloudRoot
        )
        let forbiddenPlaintexts = [
            "Sync exclusion credential fixture",
            "credential-sync-smoke.invalid",
            "credential-sync-smoke-user",
            "credential-sync-smoke-current-secret",
            "credential-sync-smoke-old-secret",
        ].map { Data($0.utf8) }
        guard !cloudFiles.isEmpty,
              cloudFiles.allSatisfy({ file in
                let name = file.lastPathComponent.lowercased()
                return !name.contains("password")
                    && !name.contains("master-key")
              }),
              try cloudFiles.allSatisfy({ file in
                let data = try Data(contentsOf: file)
                return data != masterKey
                    && data != encryptedPasswordDocument
                    && data.range(of: masterKey) == nil
                    && forbiddenPlaintexts.allSatisfy {
                        data.range(of: $0) == nil
                    }
              }) else {
            return capsuleCloudSyncSmokeFail(
                "Password/master-key/plaintext cloud exclusion"
            )
        }

        clockA.value = baseDate.addingTimeInterval(20)
        let concurrent = try storeA.put(CapsuleContentWriteRequest(
            type: .note,
            title: "Concurrent fixture",
            content: "concurrent-base"
        ))
        guard try engineA.synchronize().uploaded == 1,
              try engineB.synchronize().downloaded == 1 else {
            return capsuleCloudSyncSmokeFail("concurrent fixture baseline")
        }

        // True concurrency is resolved by coordinated cloud acceptance order,
        // never by comparing two devices' untrusted wall clocks. A uploads
        // first; B has an absurdly newer clock but must still archive its
        // local loser and accept A.
        clockA.value = Date(timeIntervalSince1970: 100)
        _ = try storeA.put(CapsuleContentWriteRequest(
            id: concurrent.id,
            type: .note,
            title: "Concurrent fixture from A",
            content: "edit-from-device-a"
        ))
        clockB.value = Date(timeIntervalSince1970: 4_102_444_800)
        _ = try storeB.put(CapsuleContentWriteRequest(
            id: concurrent.id,
            type: .note,
            title: "Concurrent fixture from B",
            content: "edit-from-device-b"
        ))
        let firstConcurrentResult = try engineA.synchronize()
        let resolvingResult = try engineB.synchronize()
        guard firstConcurrentResult.uploaded == 1,
              firstConcurrentResult.conflicts == 0,
              resolvingResult.uploaded == 0,
              resolvingResult.downloaded == 1,
              resolvingResult.conflicts == 1,
              try storeB.record(id: concurrent.id).content
                == "edit-from-device-a" else {
            return capsuleCloudSyncSmokeFail(
                "coordinated-cloud concurrent winner ignores device clocks"
            )
        }
        let convergenceResult = try engineA.synchronize()
        let winningA = try storeA.record(id: concurrent.id)
        let winningB = try storeB.record(id: concurrent.id)
        let conflictDirectory = cloudRoot
            .appendingPathComponent("v1/conflicts", isDirectory: true)
            .appendingPathComponent(
                concurrent.id.uuidString.lowercased(),
                isDirectory: true
            )
        let archivedConflicts = try capsuleCloudSyncSmokeRegularFiles(
            below: conflictDirectory
        )
        guard convergenceResult.downloaded == 0,
              convergenceResult.conflicts == 1,
              winningA.content == "edit-from-device-a",
              winningB.content == "edit-from-device-a",
              winningA.summary.title == "Concurrent fixture from A",
              winningB.summary.title == "Concurrent fixture from A",
              archivedConflicts.count == 1,
              try archivedConflicts.contains(where: {
                  try Data(contentsOf: $0).range(
                    of: Data("edit-from-device-b".utf8)
                  ) != nil
              }) else {
            return capsuleCloudSyncSmokeFail(
                "conflict archive and cross-device convergence "
                    + "(downloaded=\(convergenceResult.downloaded), "
                    + "conflicts=\(convergenceResult.conflicts), "
                    + "archives=\(archivedConflicts.count), "
                    + "a=\(winningA.content), b=\(winningB.content))"
            )
        }

        try storeA.remove(id: concurrent.id)
        clockA.value = baseDate.addingTimeInterval(50)
        let deletionUpload = try engineA.synchronize()
        let cloudEntry = cloudRoot.appendingPathComponent(
            "v1/entries/\(concurrent.id.uuidString.lowercased()).md"
        )
        let cloudTombstone = cloudRoot.appendingPathComponent(
            "v1/tombstones/\(concurrent.id.uuidString.lowercased()).json"
        )
        guard deletionUpload.deleted == 1,
              !fileManager.fileExists(atPath: cloudEntry.path),
              fileManager.fileExists(atPath: cloudTombstone.path) else {
            return capsuleCloudSyncSmokeFail("cloud tombstone creation")
        }
        let deletionDownload = try engineB.synchronize()
        guard deletionDownload.deleted == 1,
              capsuleCloudSyncSmokeRecordIsAbsent(
                concurrent.id,
                in: storeA
              ),
              capsuleCloudSyncSmokeRecordIsAbsent(
                concurrent.id,
                in: storeB
              ) else {
            return capsuleCloudSyncSmokeFail("cross-device tombstone deletion")
        }

        // The comparison state is deliberately stored outside the Capsule
        // root. If that root is lost and recreated, a new local-library marker
        // must invalidate the old baseline so cloud entries are downloaded,
        // not interpreted as intentional local deletions.
        let cloudEntriesDirectory = cloudRoot.appendingPathComponent(
            "v1/entries",
            isDirectory: true
        )
        let cloudTombstonesDirectory = cloudRoot.appendingPathComponent(
            "v1/tombstones",
            isDirectory: true
        )
        let entriesBeforeRebuild = try capsuleCloudSyncSmokeUUIDs(
            in: cloudEntriesDirectory,
            pathExtension: "md"
        )
        let tombstonesBeforeRebuild = try capsuleCloudSyncSmokeUUIDs(
            in: cloudTombstonesDirectory,
            pathExtension: "json"
        )
        try fileManager.removeItem(at: localARoot)
        let rebuildResult = try engineA.synchronize()
        let recoveredIDs = Set(
            try storeA.listRecords().map(\.summary.id)
        )
        let tombstonesAfterRebuild = try capsuleCloudSyncSmokeUUIDs(
            in: cloudTombstonesDirectory,
            pathExtension: "json"
        )
        guard rebuildResult.downloaded == entriesBeforeRebuild.count,
              entriesBeforeRebuild.isSubset(of: recoveredIDs),
              tombstonesAfterRebuild == tombstonesBeforeRebuild,
              entriesBeforeRebuild.isDisjoint(with: tombstonesAfterRebuild) else {
            return capsuleCloudSyncSmokeFail(
                "local-root rebuild restores cloud without mass tombstones"
            )
        }

        // `defaultEntryID` is fixed across devices. A customized cloud record
        // must replace a freshly auto-seeded default on a rebuilt device.
        clockA.value = baseDate.addingTimeInterval(80)
        _ = try storeA.put(CapsuleContentWriteRequest(
            id: CapsuleContentStore.defaultEntryID,
            type: .note,
            title: "Customized remote default",
            content: "custom-default-from-cloud"
        ))
        guard try engineA.synchronize().uploaded == 1 else {
            return capsuleCloudSyncSmokeFail("custom default cloud upload")
        }
        try fileManager.removeItem(at: localBRoot)
        _ = try storeB.seedDefaultsIfNeeded()
        let typedDefaultOnB = try storeB.record(
            id: CapsuleContentStore.defaultEntryID
        )
        var typedDefaultMarkdown = try String(
            contentsOf: typedDefaultOnB.summary.fileURL,
            encoding: .utf8
        )
        typedDefaultMarkdown = typedDefaultMarkdown.replacingOccurrences(
            of: "capsule: memory",
            with: "capsule: note"
        )
        try Data(typedDefaultMarkdown.utf8).write(
            to: typedDefaultOnB.summary.fileURL,
            options: .atomic
        )
        let localTypedDefault = try storeB.record(
            id: CapsuleContentStore.defaultEntryID
        )
        let defaultConflictDirectory = cloudRoot
            .appendingPathComponent("v1/conflicts", isDirectory: true)
            .appendingPathComponent(
                CapsuleContentStore.defaultEntryID.uuidString.lowercased(),
                isDirectory: true
            )
        let defaultConflictsBefore = try capsuleCloudSyncSmokeRegularFiles(
            below: defaultConflictDirectory
        ).count
        let customDefaultDownload = try engineB.synchronize()
        let customDefaultOnB = try storeB.record(
            id: CapsuleContentStore.defaultEntryID
        )
        let newDefaultConflicts = Array(
            try capsuleCloudSyncSmokeRegularFiles(
                below: defaultConflictDirectory
            ).dropFirst(defaultConflictsBefore)
        )
        guard customDefaultDownload.downloaded >= 1,
              localTypedDefault.summary.type == .note,
              localTypedDefault.summary.title
                == CapsuleContentStore.defaultEntryTitle,
              localTypedDefault.content
                == CapsuleContentStore.defaultEntryContent,
              customDefaultOnB.summary.title == "Customized remote default",
              customDefaultOnB.content == "custom-default-from-cloud",
              newDefaultConflicts.contains(where: { url in
                  guard let text = try? String(
                    contentsOf: url,
                    encoding: .utf8
                  ) else { return false }
                  return text.contains("capsule: note")
                    && text.contains(CapsuleContentStore.defaultEntryTitle)
                    && text.contains(CapsuleContentStore.defaultEntryContent)
              }) else {
            return capsuleCloudSyncSmokeFail(
                "type-customized default is archived before cloud replacement"
            )
        }

        // Unknown Obsidian front matter is also a real local customization.
        // Even with the canonical type/title/body, it must not be mistaken for
        // the untouched serializer output and silently overwritten.
        try fileManager.removeItem(at: localBRoot)
        _ = try storeB.seedDefaultsIfNeeded()
        let taggedDefaultOnB = try storeB.record(
            id: CapsuleContentStore.defaultEntryID
        )
        var taggedDefaultMarkdown = try String(
            contentsOf: taggedDefaultOnB.summary.fileURL,
            encoding: .utf8
        )
        taggedDefaultMarkdown = taggedDefaultMarkdown.replacingOccurrences(
            of: "updated_at:",
            with: "tags: [custom]\nupdated_at:"
        )
        try Data(taggedDefaultMarkdown.utf8).write(
            to: taggedDefaultOnB.summary.fileURL,
            options: .atomic
        )
        let taggedDefaultRecord = try storeB.record(
            id: CapsuleContentStore.defaultEntryID
        )
        let conflictsBeforeTaggedDefault = Set(
            try capsuleCloudSyncSmokeRegularFiles(
                below: defaultConflictDirectory
            ).map(\.path)
        )
        let taggedDefaultDownload = try engineB.synchronize()
        let conflictsAfterTaggedDefault = try capsuleCloudSyncSmokeRegularFiles(
            below: defaultConflictDirectory
        ).filter {
            !conflictsBeforeTaggedDefault.contains($0.path)
        }
        let cloudDefaultAfterTags = try storeB.record(
            id: CapsuleContentStore.defaultEntryID
        )
        guard taggedDefaultRecord.summary.type == .note,
              taggedDefaultRecord.summary.title
                == CapsuleContentStore.defaultEntryTitle,
              taggedDefaultRecord.content
                == CapsuleContentStore.defaultEntryContent,
              taggedDefaultDownload.downloaded >= 1,
              cloudDefaultAfterTags.summary.title == "Customized remote default",
              cloudDefaultAfterTags.content == "custom-default-from-cloud",
              conflictsAfterTaggedDefault.contains(where: { url in
                  guard let text = try? String(
                    contentsOf: url,
                    encoding: .utf8
                  ) else { return false }
                  return text.contains("capsule: note")
                    && text.contains("tags: [custom]")
                    && text.contains(CapsuleContentStore.defaultEntryTitle)
                    && text.contains(CapsuleContentStore.defaultEntryContent)
              }) else {
            return capsuleCloudSyncSmokeFail(
                "front-matter-customized default is archived before replacement"
            )
        }

        // A remote tombstone must also suppress the synthetic local preset.
        try storeA.remove(id: CapsuleContentStore.defaultEntryID)
        clockA.value = Date(timeIntervalSince1970: 1)
        guard try engineA.synchronize().deleted == 1 else {
            return capsuleCloudSyncSmokeFail("default tombstone upload")
        }
        let defaultCloudEntry = cloudEntriesDirectory.appendingPathComponent(
            "\(CapsuleContentStore.defaultEntryID.uuidString.lowercased()).md"
        )
        let defaultTombstone = cloudTombstonesDirectory.appendingPathComponent(
            "\(CapsuleContentStore.defaultEntryID.uuidString.lowercased()).json"
        )
        try fileManager.removeItem(at: localBRoot)
        _ = try engineB.synchronize()
        guard !fileManager.fileExists(atPath: defaultCloudEntry.path),
              fileManager.fileExists(atPath: defaultTombstone.path),
              capsuleCloudSyncSmokeRecordIsAbsent(
                CapsuleContentStore.defaultEntryID,
                in: storeB
              ) else {
            return capsuleCloudSyncSmokeFail(
                "remote default tombstone suppresses automatic seed"
            )
        }

        // Changing bytes at the same path does not change the Markdown
        // revision. The asset fingerprint must still upload new content.
        let imageOnA = try storeA.record(id: image.id)
        let sameImagePath = URL(fileURLWithPath: imageOnA.content)
        let modifiedImageData = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x53, 0x41, 0x4d, 0x45, 0x2d, 0x50, 0x41, 0x54, 0x48,
            0x2d, 0x4e, 0x45, 0x57, 0x2d, 0x42, 0x59, 0x54, 0x45, 0x53,
        ])
        try modifiedImageData.write(to: sameImagePath, options: .atomic)
        let binaryUpdateUpload = try engineA.synchronize()
        let imageCloudEntry = cloudEntriesDirectory.appendingPathComponent(
            "\(image.id.uuidString.lowercased()).md"
        )
        let modifiedAssetName = try capsuleCloudSyncSmokeAssetName(
            in: imageCloudEntry
        )
        let binaryUpdateDownload = try engineB.synchronize()
        let modifiedImageOnB = try storeB.record(id: image.id)
        guard binaryUpdateUpload.uploaded == 1,
              binaryUpdateDownload.downloaded == 1,
              modifiedAssetName
                == capsuleCloudSyncSmokeHash(modifiedImageData) + ".png",
              capsuleCloudSyncSmokeHash(
                try Data(contentsOf: URL(
                    fileURLWithPath: modifiedImageOnB.content
                ))
              ) == capsuleCloudSyncSmokeHash(modifiedImageData) else {
            return capsuleCloudSyncSmokeFail(
                "same-path media binary update crosses devices"
            )
        }

        // A missing local media cache must not block this item or an unrelated
        // note from accepting newer cloud versions.
        let missingMediaURL = URL(fileURLWithPath: modifiedImageOnB.content)
        try fileManager.removeItem(at: missingMediaURL)
        clockA.value = baseDate.addingTimeInterval(90)
        _ = try storeA.put(CapsuleContentWriteRequest(
            id: image.id,
            type: .image,
            title: "Cross-device image retitled",
            content: sameImagePath.path
        ))
        let alongsideMissingMedia = try storeA.put(
            CapsuleContentWriteRequest(
                type: .note,
                title: "Alongside missing media",
                content: "unrelated-note-still-downloads"
            )
        )
        let missingMediaUpload = try engineA.synchronize()
        let missingMediaDownload = try engineB.synchronize()
        let repairedImageOnB = try storeB.record(id: image.id)
        guard missingMediaUpload.uploaded == 2,
              missingMediaDownload.downloaded == 2,
              repairedImageOnB.summary.title
                == "Cross-device image retitled",
              fileManager.fileExists(atPath: repairedImageOnB.content),
              try storeB.record(id: alongsideMissingMedia.id).content
                == "unrelated-note-still-downloads" else {
            return capsuleCloudSyncSmokeFail(
                "missing media cache does not block library download"
            )
        }

        // A user may edit the Obsidian body to a new media path before that
        // file is mounted or downloaded. Never silently reuse the old cloud
        // blob for the new path, including on later retries whose state cache
        // was written by the first deferred pass.
        let deferredSource = sourceDirectory.appendingPathComponent(
            "deferred-path.png"
        )
        let deferredSourceData = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x44, 0x45, 0x46, 0x45, 0x52, 0x52, 0x45, 0x44,
        ])
        try deferredSourceData.write(to: deferredSource, options: .atomic)
        let deferredMedia = try storeA.put(CapsuleContentWriteRequest(
            type: .image,
            title: "Deferred new media path",
            content: deferredSource.path
        ))
        guard try engineA.synchronize().uploaded == 1,
              try engineB.synchronize().downloaded == 1 else {
            return capsuleCloudSyncSmokeFail("deferred media baseline")
        }
        let deferredLocalRecord = try storeA.record(id: deferredMedia.id)
        let deferredOriginalDocument = try Data(
            contentsOf: deferredLocalRecord.summary.fileURL
        )
        guard var deferredDocumentText = String(
            data: deferredOriginalDocument,
            encoding: .utf8
        ) else {
            return capsuleCloudSyncSmokeFail("deferred media local Markdown")
        }
        let unavailableNewPath = sourceDirectory
            .appendingPathComponent("not-mounted/new-path.png")
            .path
        deferredDocumentText = deferredDocumentText.replacingOccurrences(
            of: deferredSource.path,
            with: unavailableNewPath
        )
        try Data(deferredDocumentText.utf8).write(
            to: deferredLocalRecord.summary.fileURL,
            options: .atomic
        )
        let deferredCloudEntry = cloudEntriesDirectory.appendingPathComponent(
            "\(deferredMedia.id.uuidString.lowercased()).md"
        )
        let deferredCloudBefore = try Data(contentsOf: deferredCloudEntry)
        let deferredAssetBefore = try capsuleCloudSyncSmokeAssetName(
            in: deferredCloudEntry
        )
        let firstDeferred = try engineA.synchronize()
        let secondDeferred = try engineA.synchronize()
        guard firstDeferred.deferred == 1,
              firstDeferred.uploaded == 0,
              secondDeferred.deferred == 1,
              secondDeferred.uploaded == 0,
              try Data(contentsOf: deferredCloudEntry)
                == deferredCloudBefore,
              try capsuleCloudSyncSmokeAssetName(in: deferredCloudEntry)
                == deferredAssetBefore else {
            return capsuleCloudSyncSmokeFail(
                "new unavailable media path remains deferred across retries"
            )
        }
        try deferredOriginalDocument.write(
            to: deferredLocalRecord.summary.fileURL,
            options: .atomic
        )
        guard try engineA.synchronize().deferred == 0 else {
            return capsuleCloudSyncSmokeFail("deferred media recovery")
        }

        // Asset GC is intentionally conservative: deleting an entry converges
        // without racing an in-flight entry upload, and cached/blob bytes may
        // remain until a separately coordinated maintenance pass exists.
        let repairedImageCacheOnB = URL(
            fileURLWithPath: repairedImageOnB.content
        )
        let liveImageCloudAsset = cloudRoot.appendingPathComponent(
            "v1/assets/\(modifiedAssetName)"
        )
        try storeA.remove(id: image.id)
        let imageDeleteOnA = try engineA.synchronize()
        guard imageDeleteOnA.deleted == 1,
              fileManager.fileExists(atPath: liveImageCloudAsset.path),
              fileManager.fileExists(atPath: sameImagePath.path),
              try storeA.record(id: alongsideMissingMedia.id).content
                == "unrelated-note-still-downloads" else {
            return capsuleCloudSyncSmokeFail(
                "media delete converges with conservative asset retention"
            )
        }
        let imageDeleteOnB = try engineB.synchronize()
        guard imageDeleteOnB.deleted == 1,
              capsuleCloudSyncSmokeRecordIsAbsent(image.id, in: storeB),
              fileManager.fileExists(atPath: repairedImageCacheOnB.path),
              try storeB.record(id: alongsideMissingMedia.id).content
                == "unrelated-note-still-downloads" else {
            return capsuleCloudSyncSmokeFail(
                "device-B media delete preserves unrelated live entries"
            )
        }

        // Content-addressed assets may be shared by multiple records. Deleting
        // one reference must retain the blob/cache. Even after the final
        // deletion the current protocol conservatively retains bytes.
        let sharedImageData = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x53, 0x48, 0x41, 0x52, 0x45, 0x44, 0x2d, 0x41, 0x53, 0x53, 0x45,
            0x54,
        ])
        let sharedSource = sourceDirectory.appendingPathComponent("shared.png")
        try sharedImageData.write(to: sharedSource, options: .atomic)
        let sharedOne = try storeA.put(CapsuleContentWriteRequest(
            type: .image,
            title: "Shared media one",
            content: sharedSource.path
        ))
        let sharedTwo = try storeA.put(CapsuleContentWriteRequest(
            type: .image,
            title: "Shared media two",
            content: sharedSource.path
        ))
        guard try engineA.synchronize().uploaded == 2,
              try engineB.synchronize().downloaded == 2 else {
            return capsuleCloudSyncSmokeFail("shared media baseline")
        }
        let sharedAssetName = try capsuleCloudSyncSmokeAssetName(
            in: cloudEntriesDirectory.appendingPathComponent(
                "\(sharedOne.id.uuidString.lowercased()).md"
            )
        )
        let sharedCloudAsset = cloudRoot.appendingPathComponent(
            "v1/assets/\(sharedAssetName)"
        )
        let sharedCacheOnB = URL(
            fileURLWithPath: try storeB.record(id: sharedOne.id).content
        )
        guard try capsuleCloudSyncSmokeAssetName(
            in: cloudEntriesDirectory.appendingPathComponent(
                "\(sharedTwo.id.uuidString.lowercased()).md"
            )
        ) == sharedAssetName else {
            return capsuleCloudSyncSmokeFail("shared media content address")
        }
        try storeA.remove(id: sharedOne.id)
        _ = try engineA.synchronize()
        _ = try engineB.synchronize()
        guard fileManager.fileExists(atPath: sharedCloudAsset.path),
              fileManager.fileExists(atPath: sharedCacheOnB.path),
              capsuleCloudSyncSmokeRecordIsAbsent(sharedOne.id, in: storeB),
              try storeB.record(id: sharedTwo.id).summary.id == sharedTwo.id else {
            return capsuleCloudSyncSmokeFail(
                "shared media survives first-reference deletion"
            )
        }
        try storeA.remove(id: sharedTwo.id)
        _ = try engineA.synchronize()
        _ = try engineB.synchronize()
        guard fileManager.fileExists(atPath: sharedCloudAsset.path),
              fileManager.fileExists(atPath: sharedCacheOnB.path) else {
            return capsuleCloudSyncSmokeFail(
                "conservative retention after final shared reference"
            )
        }

        // A losing concurrent media edit is still an explicit conflict
        // reference. Its unique cloud asset must remain after the winning live
        // record is later deleted.
        let mediaConflictBase = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x4d, 0x45, 0x44, 0x49, 0x41, 0x2d, 0x42, 0x41, 0x53, 0x45,
        ])
        let mediaConflictSource = sourceDirectory.appendingPathComponent(
            "media-conflict.png"
        )
        try mediaConflictBase.write(to: mediaConflictSource, options: .atomic)
        let mediaConflict = try storeA.put(CapsuleContentWriteRequest(
            type: .image,
            title: "Media conflict baseline",
            content: mediaConflictSource.path
        ))
        guard try engineA.synchronize().uploaded == 1,
              try engineB.synchronize().downloaded == 1 else {
            return capsuleCloudSyncSmokeFail("media conflict baseline")
        }
        let mediaWinnerData = Data(mediaConflictBase + Data("-A-WINNER".utf8))
        let mediaLoserData = Data(mediaConflictBase + Data("-B-LOSER".utf8))
        let mediaPathOnA = URL(
            fileURLWithPath: try storeA.record(id: mediaConflict.id).content
        )
        let mediaPathOnB = URL(
            fileURLWithPath: try storeB.record(id: mediaConflict.id).content
        )
        try mediaWinnerData.write(to: mediaPathOnA, options: .atomic)
        try mediaLoserData.write(to: mediaPathOnB, options: .atomic)
        clockA.value = Date(timeIntervalSince1970: 4_102_444_800)
        clockB.value = Date(timeIntervalSince1970: 2)
        guard try engineA.synchronize().uploaded == 1 else {
            return capsuleCloudSyncSmokeFail("media cloud winner upload")
        }
        let mediaConflictResolution = try engineB.synchronize()
        let winningMediaAssetName = try capsuleCloudSyncSmokeAssetName(
            in: cloudEntriesDirectory.appendingPathComponent(
                "\(mediaConflict.id.uuidString.lowercased()).md"
            )
        )
        let losingMediaAssetName = capsuleCloudSyncSmokeHash(mediaLoserData)
            + ".png"
        let losingMediaCloudAsset = cloudRoot.appendingPathComponent(
            "v1/assets/\(losingMediaAssetName)"
        )
        let mediaConflictFiles = try capsuleCloudSyncSmokeRegularFiles(
            below: cloudRoot
                .appendingPathComponent("v1/conflicts", isDirectory: true)
                .appendingPathComponent(
                    mediaConflict.id.uuidString.lowercased(),
                    isDirectory: true
                )
        )
        guard mediaConflictResolution.downloaded == 1,
              fileManager.fileExists(atPath: losingMediaCloudAsset.path),
              try mediaConflictFiles.contains(where: {
                  try Data(contentsOf: $0).range(
                    of: Data(losingMediaAssetName.utf8)
                  ) != nil
              }) else {
            return capsuleCloudSyncSmokeFail(
                "concurrent media loser and conflict asset archive"
            )
        }
        try storeA.remove(id: mediaConflict.id)
        _ = try engineA.synchronize()
        _ = try engineB.synchronize()
        let winningMediaCloudAsset = cloudRoot.appendingPathComponent(
            "v1/assets/\(winningMediaAssetName)"
        )
        guard fileManager.fileExists(atPath: winningMediaCloudAsset.path),
              fileManager.fileExists(atPath: losingMediaCloudAsset.path) else {
            return capsuleCloudSyncSmokeFail(
                "conflict-referenced media survives live deletion"
            )
        }

        // Tombstones are accepted cloud operations. Even an edit from a device
        // whose wall clock is decades ahead loses to a tombstone already in
        // the cloud, while its local text is archived for recovery.
        let tombstoneRace = try storeA.put(CapsuleContentWriteRequest(
            type: .note,
            title: "Tombstone versus edit",
            content: "tombstone-race-baseline"
        ))
        guard try engineA.synchronize().uploaded == 1,
              try engineB.synchronize().downloaded == 1 else {
            return capsuleCloudSyncSmokeFail("tombstone race baseline")
        }
        try storeA.remove(id: tombstoneRace.id)
        clockA.value = Date(timeIntervalSince1970: 3)
        guard try engineA.synchronize().deleted == 1 else {
            return capsuleCloudSyncSmokeFail("tombstone race deletion")
        }
        clockB.value = Date(timeIntervalSince1970: 4_102_444_800)
        _ = try storeB.put(CapsuleContentWriteRequest(
            id: tombstoneRace.id,
            type: .note,
            title: "Future-clock local edit",
            content: "future-clock-edit-must-lose"
        ))
        _ = try engineB.synchronize()
        let tombstoneRaceArchive = try capsuleCloudSyncSmokeRegularFiles(
            below: cloudRoot
                .appendingPathComponent("v1/conflicts", isDirectory: true)
                .appendingPathComponent(
                    tombstoneRace.id.uuidString.lowercased(),
                    isDirectory: true
                )
        )
        guard capsuleCloudSyncSmokeRecordIsAbsent(tombstoneRace.id, in: storeB),
              fileManager.fileExists(atPath: cloudTombstonesDirectory
                .appendingPathComponent(
                    "\(tombstoneRace.id.uuidString.lowercased()).json"
                ).path),
              try tombstoneRaceArchive.contains(where: {
                  try Data(contentsOf: $0).range(
                    of: Data("future-clock-edit-must-lose".utf8)
                  ) != nil
              }) else {
            return capsuleCloudSyncSmokeFail(
                "tombstone wins future-clock local edit"
            )
        }

        // Conversely, a local delete based on an old baseline must not erase a
        // cloud edit that another device already accepted. Restore that cloud
        // winner and archive a machine-readable deletion intent.
        let changedCloudRace = try storeA.put(CapsuleContentWriteRequest(
            type: .note,
            title: "Local delete versus cloud edit",
            content: "delete-cloud-race-baseline"
        ))
        guard try engineA.synchronize().uploaded == 1,
              try engineB.synchronize().downloaded == 1 else {
            return capsuleCloudSyncSmokeFail("delete-cloud race baseline")
        }
        clockB.value = Date(timeIntervalSince1970: 4)
        _ = try storeB.put(CapsuleContentWriteRequest(
            id: changedCloudRace.id,
            type: .note,
            title: "Cloud edit wins deletion",
            content: "accepted-cloud-edit"
        ))
        guard try engineB.synchronize().uploaded == 1 else {
            return capsuleCloudSyncSmokeFail("changed cloud race upload")
        }
        try storeA.remove(id: changedCloudRace.id)
        clockA.value = Date(timeIntervalSince1970: 4_102_444_800)
        let changedCloudResolution = try engineA.synchronize()
        let deletionIntentFiles = try capsuleCloudSyncSmokeRegularFiles(
            below: cloudRoot
                .appendingPathComponent("v1/conflicts", isDirectory: true)
                .appendingPathComponent(
                    changedCloudRace.id.uuidString.lowercased(),
                    isDirectory: true
                )
        ).filter { $0.pathExtension == "json" }
        guard changedCloudResolution.downloaded == 1,
              try storeA.record(id: changedCloudRace.id).content
                == "accepted-cloud-edit",
              !fileManager.fileExists(atPath: cloudTombstonesDirectory
                .appendingPathComponent(
                    "\(changedCloudRace.id.uuidString.lowercased()).json"
                ).path),
              deletionIntentFiles.count == 1,
              try capsuleCloudSyncSmokeDeletionIntent(
                at: deletionIntentFiles[0]
              ) == changedCloudRace.id else {
            return capsuleCloudSyncSmokeFail(
                "changed cloud wins local deletion with JSON intent archive"
            )
        }

        // An unavailable local media loser may contain the only recoverable
        // absolute path. A tombstone must archive those exact Markdown bytes
        // locally before deleting the canonical record, while iCloud receives
        // only path-hash metadata in JSON.
        let offlineDeleteSource = sourceDirectory.appendingPathComponent(
            "offline-delete.png"
        )
        try Data(imageData + Data("-OFFLINE-DELETE".utf8)).write(
            to: offlineDeleteSource,
            options: .atomic
        )
        let offlineDelete = try storeA.put(CapsuleContentWriteRequest(
            type: .image,
            title: "Offline media before tombstone",
            content: offlineDeleteSource.path
        ))
        guard try engineA.synchronize().uploaded == 1,
              try engineB.synchronize().downloaded == 1 else {
            return capsuleCloudSyncSmokeFail("offline tombstone baseline")
        }
        let sensitiveDeletedPath = "/Volumes/Private Offline/tombstone-secret.png"
        let offlineDeleteLoser = try capsuleCloudSyncSmokeRewriteMedia(
            try storeB.record(id: offlineDelete.id),
            title: "Offline local loser before tombstone",
            path: sensitiveDeletedPath
        )
        try storeA.remove(id: offlineDelete.id)
        guard try engineA.synchronize().deleted == 1 else {
            return capsuleCloudSyncSmokeFail("offline media tombstone upload")
        }
        let offlineDeleteLocalDirectory = storeB.conflictDirectoryURL
            .appendingPathComponent(
                offlineDelete.id.uuidString.lowercased(),
                isDirectory: true
            )
        let offlineDeleteTrap = fixtureRoot.appendingPathComponent(
            "offline-delete-conflict-trap",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: offlineDeleteTrap,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: offlineDeleteLocalDirectory,
            withDestinationURL: offlineDeleteTrap
        )
        guard capsuleCloudSyncSmokeFails({
            _ = try engineB.synchronize()
        }),
        try storeB.record(id: offlineDelete.id).content
            == sensitiveDeletedPath else {
            return capsuleCloudSyncSmokeFail(
                "failed local archive prevents tombstone deletion"
            )
        }
        try fileManager.removeItem(at: offlineDeleteLocalDirectory)
        let offlineDeleteResult = try engineB.synchronize()
        let offlineDeleteLocalFiles = try capsuleCloudSyncSmokeRegularFiles(
            below: offlineDeleteLocalDirectory
        )
        let offlineDeleteCloudFiles = try capsuleCloudSyncSmokeRegularFiles(
            below: cloudRoot
                .appendingPathComponent("v1/conflicts", isDirectory: true)
                .appendingPathComponent(
                    offlineDelete.id.uuidString.lowercased(),
                    isDirectory: true
                )
        )
        guard offlineDeleteResult.deleted == 1,
              capsuleCloudSyncSmokeRecordIsAbsent(offlineDelete.id, in: storeB),
              offlineDeleteLocalFiles.count == 1,
              try Data(contentsOf: offlineDeleteLocalFiles[0])
                == offlineDeleteLoser,
              try String(
                contentsOf: offlineDeleteLocalFiles[0],
                encoding: .utf8
              ).contains(sensitiveDeletedPath),
              capsuleCloudSyncSmokePermissions(storeB.conflictDirectoryURL)
                == 0o700,
              capsuleCloudSyncSmokePermissions(offlineDeleteLocalDirectory)
                == 0o700,
              capsuleCloudSyncSmokePermissions(offlineDeleteLocalFiles[0])
                == 0o600,
              !offlineDeleteCloudFiles.isEmpty,
              offlineDeleteCloudFiles.allSatisfy({
                  $0.pathExtension == "json"
              }),
              try capsuleCloudSyncSmokeFilesContainNone(
                capsuleCloudSyncSmokeRegularFiles(below: cloudRoot)
                    + [deviceBRoot.appendingPathComponent("sync/state.json")],
                forbidden: Data(sensitiveDeletedPath.utf8)
              ) else {
            return capsuleCloudSyncSmokeFail(
                "offline tombstone loser local archive and cloud redaction"
            )
        }

        // The same archive-before-overwrite contract applies when a
        // coordinated cloud entry wins a true concurrent edit.
        let offlineConcurrentSource = sourceDirectory.appendingPathComponent(
            "offline-concurrent.png"
        )
        try Data(imageData + Data("-OFFLINE-CONCURRENT".utf8)).write(
            to: offlineConcurrentSource,
            options: .atomic
        )
        let offlineConcurrent = try storeA.put(CapsuleContentWriteRequest(
            type: .image,
            title: "Offline concurrent baseline",
            content: offlineConcurrentSource.path
        ))
        guard try engineA.synchronize().uploaded == 1,
              try engineB.synchronize().downloaded == 1 else {
            return capsuleCloudSyncSmokeFail("offline concurrent baseline")
        }
        let sensitiveConcurrentPath =
            "/Volumes/Private Offline/concurrent-secret.png"
        let offlineConcurrentLoser = try capsuleCloudSyncSmokeRewriteMedia(
            try storeB.record(id: offlineConcurrent.id),
            title: "Offline concurrent local loser",
            path: sensitiveConcurrentPath
        )
        _ = try storeA.put(CapsuleContentWriteRequest(
            id: offlineConcurrent.id,
            type: .image,
            title: "Accepted cloud media winner",
            content: offlineConcurrentSource.path
        ))
        guard try engineA.synchronize().uploaded == 1 else {
            return capsuleCloudSyncSmokeFail("offline concurrent cloud winner")
        }
        let offlineConcurrentLocalDirectory = storeB.conflictDirectoryURL
            .appendingPathComponent(
                offlineConcurrent.id.uuidString.lowercased(),
                isDirectory: true
            )
        let offlineConcurrentTrap = fixtureRoot.appendingPathComponent(
            "offline-concurrent-conflict-trap",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: offlineConcurrentTrap,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: offlineConcurrentLocalDirectory,
            withDestinationURL: offlineConcurrentTrap
        )
        guard capsuleCloudSyncSmokeFails({
            _ = try engineB.synchronize()
        }),
        try storeB.record(id: offlineConcurrent.id).content
            == sensitiveConcurrentPath,
        try storeB.record(id: offlineConcurrent.id).summary.title
            == "Offline concurrent local loser" else {
            return capsuleCloudSyncSmokeFail(
                "failed local archive prevents cloud-winner overwrite"
            )
        }
        try fileManager.removeItem(at: offlineConcurrentLocalDirectory)
        let offlineConcurrentResult = try engineB.synchronize()
        let offlineConcurrentLocalFiles = try capsuleCloudSyncSmokeRegularFiles(
            below: offlineConcurrentLocalDirectory
        )
        let offlineConcurrentCloudFiles = try capsuleCloudSyncSmokeRegularFiles(
            below: cloudRoot
                .appendingPathComponent("v1/conflicts", isDirectory: true)
                .appendingPathComponent(
                    offlineConcurrent.id.uuidString.lowercased(),
                    isDirectory: true
                )
        )
        let offlineConcurrentWinner = try storeB.record(id: offlineConcurrent.id)
        guard offlineConcurrentResult.downloaded == 1,
              offlineConcurrentWinner.summary.title
                == "Accepted cloud media winner",
              offlineConcurrentWinner.content != sensitiveConcurrentPath,
              offlineConcurrentLocalFiles.count == 1,
              try Data(contentsOf: offlineConcurrentLocalFiles[0])
                == offlineConcurrentLoser,
              capsuleCloudSyncSmokePermissions(
                offlineConcurrentLocalDirectory
              ) == 0o700,
              capsuleCloudSyncSmokePermissions(
                offlineConcurrentLocalFiles[0]
              ) == 0o600,
              !offlineConcurrentCloudFiles.isEmpty,
              offlineConcurrentCloudFiles.allSatisfy({
                  $0.pathExtension == "json"
              }),
              try capsuleCloudSyncSmokeFilesContainNone(
                capsuleCloudSyncSmokeRegularFiles(below: cloudRoot)
                    + [deviceBRoot.appendingPathComponent("sync/state.json")],
                forbidden: Data(sensitiveConcurrentPath.utf8)
              ) else {
            return capsuleCloudSyncSmokeFail(
                "offline concurrent loser local archive and cloud redaction"
            )
        }

        // A v1 tombstone is permanent knowledge. If the cloud tombstone file
        // disappears and an offline third device uploads its stale entry, a
        // device that previously consumed the deletion must recreate the
        // tombstone before processing that stale cloud copy.
        let deviceCRoot = fixtureRoot.appendingPathComponent(
            "device-c",
            isDirectory: true
        )
        let localCRoot = deviceCRoot.appendingPathComponent(
            "capsule",
            isDirectory: true
        )
        let clockC = CapsuleCloudSyncSmokeClock(baseDate)
        let storeC = CapsuleContentStore(
            rootURL: localCRoot,
            now: { clockC.value }
        )
        try capsuleCloudSyncSmokeMakeEmpty(storeC)
        let engineC = CapsuleCloudSyncEngine(
            contentStore: storeC,
            localRootURL: localCRoot,
            cloudRootURL: cloudRoot,
            stateURL: deviceCRoot.appendingPathComponent("sync/state.json"),
            libraryID: libraryID,
            now: { clockC.value }
        )
        let permanentDelete = try storeA.put(CapsuleContentWriteRequest(
            type: .note,
            title: "Permanent tombstone across offline device",
            content: "must-never-resurrect"
        ))
        guard try engineA.synchronize().uploaded == 1 else {
            return capsuleCloudSyncSmokeFail("permanent tombstone baseline upload")
        }
        _ = try engineB.synchronize()
        _ = try engineC.synchronize()
        guard try storeB.record(id: permanentDelete.id).content
                == "must-never-resurrect",
              try storeC.record(id: permanentDelete.id).content
                == "must-never-resurrect" else {
            return capsuleCloudSyncSmokeFail("three-device tombstone baseline")
        }
        try storeA.remove(id: permanentDelete.id)
        guard try engineA.synchronize().deleted == 1 else {
            return capsuleCloudSyncSmokeFail("permanent tombstone creation")
        }
        _ = try engineB.synchronize()
        let permanentTombstone = cloudTombstonesDirectory
            .appendingPathComponent(
                "\(permanentDelete.id.uuidString.lowercased()).json"
            )
        let permanentCloudEntry = cloudEntriesDirectory.appendingPathComponent(
            "\(permanentDelete.id.uuidString.lowercased()).md"
        )
        guard capsuleCloudSyncSmokeRecordIsAbsent(permanentDelete.id, in: storeA),
              capsuleCloudSyncSmokeRecordIsAbsent(permanentDelete.id, in: storeB),
              fileManager.fileExists(atPath: permanentTombstone.path),
              try storeC.record(id: permanentDelete.id).content
                == "must-never-resurrect" else {
            return capsuleCloudSyncSmokeFail("offline device retains stale entry")
        }
        try fileManager.removeItem(at: permanentTombstone)
        let staleRetransmit = try engineC.synchronize()
        guard staleRetransmit.uploaded == 1,
              fileManager.fileExists(atPath: permanentCloudEntry.path),
              !fileManager.fileExists(atPath: permanentTombstone.path) else {
            return capsuleCloudSyncSmokeFail("offline stale retransmission fixture")
        }
        _ = try engineA.synchronize()
        _ = try engineB.synchronize()
        _ = try engineC.synchronize()
        guard fileManager.fileExists(atPath: permanentTombstone.path),
              !fileManager.fileExists(atPath: permanentCloudEntry.path),
              capsuleCloudSyncSmokeRecordIsAbsent(permanentDelete.id, in: storeA),
              capsuleCloudSyncSmokeRecordIsAbsent(permanentDelete.id, in: storeB),
              capsuleCloudSyncSmokeRecordIsAbsent(permanentDelete.id, in: storeC) else {
            return capsuleCloudSyncSmokeFail(
                "consumed tombstone is rebuilt and suppresses stale resurrection"
            )
        }

        clockA.value = baseDate.addingTimeInterval(60)
        let linkedEntry = try storeA.put(CapsuleContentWriteRequest(
            type: .note,
            title: "Remote symlink fixture",
            content: "remote-symlink-source"
        ))
        guard try engineA.synchronize().uploaded == 1 else {
            return capsuleCloudSyncSmokeFail("symlink fixture upload")
        }
        let linkedCloudEntry = cloudRoot.appendingPathComponent(
            "v1/entries/\(linkedEntry.id.uuidString.lowercased()).md"
        )
        let linkedTarget = fixtureRoot.appendingPathComponent(
            "remote-symlink-target.md"
        )
        try Data(contentsOf: linkedCloudEntry).write(
            to: linkedTarget,
            options: .atomic
        )
        try fileManager.removeItem(at: linkedCloudEntry)
        try fileManager.createSymbolicLink(
            at: linkedCloudEntry,
            withDestinationURL: linkedTarget
        )
        let sentinelBeforeSymlink = try storeB.record(id: text.id)
        guard capsuleCloudSyncSmokeRejectsUnsafe({
            _ = try engineB.synchronize()
        }),
        capsuleCloudSyncSmokeRecordIsAbsent(linkedEntry.id, in: storeB),
        try storeB.record(id: text.id) == sentinelBeforeSymlink else {
            return capsuleCloudSyncSmokeFail(
                "remote symlink rejection without local overwrite"
            )
        }
        try fileManager.removeItem(at: linkedCloudEntry)
        try Data(contentsOf: linkedTarget).write(
            to: linkedCloudEntry,
            options: .atomic
        )
        guard try engineB.synchronize().downloaded == 1 else {
            return capsuleCloudSyncSmokeFail("recovery after symlink rejection")
        }

        clockA.value = baseDate.addingTimeInterval(70)
        let corruptImageData = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x43, 0x4f, 0x52, 0x52, 0x55, 0x50, 0x54, 0x2d, 0x46, 0x49, 0x58,
        ])
        let corruptSource = sourceDirectory.appendingPathComponent(
            "corrupt-fixture.png"
        )
        try corruptImageData.write(to: corruptSource, options: .atomic)
        let corruptImage = try storeA.put(CapsuleContentWriteRequest(
            type: .image,
            title: "Corrupt remote asset fixture",
            content: corruptSource.path
        ))
        guard try engineA.synchronize().uploaded == 1 else {
            return capsuleCloudSyncSmokeFail("corrupt asset fixture upload")
        }
        let corruptCloudEntry = cloudRoot.appendingPathComponent(
            "v1/entries/\(corruptImage.id.uuidString.lowercased()).md"
        )
        let corruptAssetName = try capsuleCloudSyncSmokeAssetName(
            in: corruptCloudEntry
        )
        let corruptCloudAsset = cloudRoot.appendingPathComponent(
            "v1/assets/\(corruptAssetName)"
        )
        try Data("tampered-cloud-asset".utf8).write(
            to: corruptCloudAsset,
            options: .atomic
        )
        let corruptLocalAsset = localBRoot.appendingPathComponent(
            "assets/\(corruptAssetName)"
        )
        let sentinelBeforeCorruption = try storeB.record(id: text.id)
        guard capsuleCloudSyncSmokeRejectsUnsafe({
            _ = try engineB.synchronize()
        }),
        capsuleCloudSyncSmokeRecordIsAbsent(corruptImage.id, in: storeB),
        !fileManager.fileExists(atPath: corruptLocalAsset.path),
        try storeB.record(id: text.id) == sentinelBeforeCorruption else {
            return capsuleCloudSyncSmokeFail(
                "corrupt asset rejection without local overwrite"
            )
        }
    } catch {
        return capsuleCloudSyncSmokeFail(
            "unexpected error: \(error.localizedDescription)"
        )
    }

    print("Capsule iCloud sync smoke: OK")
    return true
}

private final class CapsuleCloudSyncSmokeClock {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private func capsuleCloudSyncSmokeMakeEmpty(
    _ store: CapsuleContentStore
) throws {
    _ = try store.seedDefaultsIfNeeded()
    try store.remove(id: CapsuleContentStore.defaultEntryID)
}

private func capsuleCloudSyncSmokeIsNoop(
    _ result: CapsuleCloudSyncResult
) -> Bool {
    result.uploaded == 0
        && result.downloaded == 0
        && result.deleted == 0
        && result.conflicts == 0
        && result.deferred == 0
}

private func capsuleCloudSyncSmokeHash(_ data: Data) -> String {
    SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}

private func capsuleCloudSyncSmokeRecordIsAbsent(
    _ id: UUID,
    in store: CapsuleContentStore
) -> Bool {
    do {
        _ = try store.record(id: id)
        return false
    } catch CapsuleContentStoreError.recordNotFound {
        return true
    } catch {
        return false
    }
}

private func capsuleCloudSyncSmokeRejectsUnsafe(
    _ operation: () throws -> Void
) -> Bool {
    do {
        try operation()
        return false
    } catch CapsuleCloudSyncError.unsafeItem {
        return true
    } catch {
        return false
    }
}

private func capsuleCloudSyncSmokeRegularFiles(
    below root: URL
) throws -> [URL] {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: root.path) else { return [] }
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ],
        options: []
    ) else {
        throw CocoaError(.fileReadUnknown)
    }
    var result: [URL] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        if values.isSymbolicLink == true {
            enumerator.skipDescendants()
        } else if values.isRegularFile == true {
            result.append(url)
        }
    }
    return result.sorted { $0.path < $1.path }
}

private func capsuleCloudSyncSmokeUUIDs(
    in directory: URL,
    pathExtension: String
) throws -> Set<UUID> {
    let urls = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ],
        options: [.skipsHiddenFiles]
    )
    var result = Set<UUID>()
    for url in urls where url.pathExtension == pathExtension {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let id = UUID(
                uuidString: url.deletingPathExtension().lastPathComponent
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        result.insert(id)
    }
    return result
}

private func capsuleCloudSyncSmokeDeletionIntent(at url: URL) throws -> UUID {
    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
    )
    guard let dictionary = object as? [String: Any],
          let rawID = (dictionary["id"] ?? dictionary["entryID"]) as? String,
          let id = UUID(uuidString: rawID) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return id
}

private func capsuleCloudSyncSmokeRewriteMedia(
    _ record: CapsuleContentRecord,
    title: String,
    path: String
) throws -> Data {
    guard record.summary.type == .image || record.summary.type == .pdf,
          NSString(string: path).isAbsolutePath,
          var text = String(
            data: try Data(contentsOf: record.summary.fileURL),
            encoding: .utf8
          ) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    var lines = text.split(
        separator: "\n",
        omittingEmptySubsequences: false
    ).map(String.init)
    guard lines.first == "---",
          let end = lines.dropFirst().firstIndex(of: "---"),
          let titleIndex = lines[..<end].firstIndex(where: {
              $0.hasPrefix("title:")
          }),
          let encodedTitle = try? JSONEncoder().encode(title),
          let encodedTitleText = String(
            data: encodedTitle,
            encoding: .utf8
          ) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    lines[titleIndex] = "title: \(encodedTitleText)"
    text = lines[0...end].joined(separator: "\n") + "\n\n" + path
    let data = Data(text.utf8)
    try data.write(to: record.summary.fileURL, options: .atomic)
    return data
}

private func capsuleCloudSyncSmokePermissions(_ url: URL) -> Int? {
    guard let value = try? FileManager.default.attributesOfItem(
        atPath: url.path
    )[.posixPermissions] as? NSNumber else {
        return nil
    }
    return value.intValue & 0o777
}

private func capsuleCloudSyncSmokeFilesContainNone(
    _ urls: [URL],
    forbidden: Data
) throws -> Bool {
    for url in urls {
        if try Data(contentsOf: url).range(of: forbidden) != nil {
            return false
        }
    }
    return true
}

private func capsuleCloudSyncSmokeFails(
    _ operation: () throws -> Void
) -> Bool {
    do {
        try operation()
        return false
    } catch {
        return true
    }
}

private func capsuleCloudSyncSmokeAssetName(in entryURL: URL) throws -> String {
    let text = try String(contentsOf: entryURL, encoding: .utf8)
    guard let line = text.split(separator: "\n").first(where: {
        $0.hasPrefix("sync_asset:")
    }),
    let colon = line.firstIndex(of: ":") else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let encoded = String(line[line.index(after: colon)...])
        .trimmingCharacters(in: .whitespaces)
    guard let data = encoded.data(using: .utf8) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return try JSONDecoder().decode(String.self, from: data)
}

private func capsuleCloudSyncSmokeFail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}
