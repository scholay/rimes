import Darwin
import Foundation

func runCapsulePasswordSmokeTest() -> Bool {
    print("== RIMES Capsule smoke ==")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rimes-capsule-smoke-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var instant = Date(timeIntervalSince1970: 1_787_961_600)
    let contentStore = CapsuleContentStore(rootURL: root, now: { instant })
    let passwordStore = CapsulePasswordStore(rootURL: root, now: { instant })

    do {
        guard try contentStore.seedDefaultsIfNeeded(),
              !(try contentStore.seedDefaultsIfNeeded()),
              permissions(root.path) == 0o700,
              permissions(contentStore.entryDirectoryURL.path) == 0o700,
              permissions(contentStore.seedMarkerURL.path) == 0o600 else {
            return fail("one-shot default seed and private permissions")
        }
        let seeded = try contentStore.record(
            id: CapsuleContentStore.defaultEntryID
        )
        guard seeded.summary.type == .note,
              seeded.summary.title == CapsuleContentStore.defaultEntryTitle,
              seeded.content == CapsuleContentStore.defaultEntryContent,
              permissions(seeded.summary.fileURL.path) == 0o600,
              try contentStore.search("rimes", limit: 5).map(\.summary.id)
                == [CapsuleContentStore.defaultEntryID] else {
            return fail("RIMES default Memory seed")
        }
        let seededMarkdown = try String(
            contentsOf: seeded.summary.fileURL,
            encoding: .utf8
        )
        guard seededMarkdown.contains("capsule: note"),
              seededMarkdown.contains("title: \"RIMES 默认词条\""),
              seededMarkdown.contains("\nRIMES") else {
            return fail("Obsidian-readable default Markdown")
        }
        try contentStore.remove(id: CapsuleContentStore.defaultEntryID)
        guard !(try contentStore.seedDefaultsIfNeeded()) else {
            return fail("deleted default was recreated after seed marker")
        }
        do {
            _ = try contentStore.record(id: CapsuleContentStore.defaultEntryID)
            return fail("removed default still readable")
        } catch CapsuleContentStoreError.recordNotFound {
            // Expected: the seed marker preserves the user's deletion.
        }

        // Files written when Prompt/Memory/URL still existed stay on disk.
        // Listing must step over them: one retired record cannot be allowed to
        // hide every current entry, which is what an aborted listing would do.
        for retired in ["prompt", "memory", "url"] {
            let retiredID = UUID()
            let retiredURL = contentStore.entryDirectoryURL
                .appendingPathComponent("\(retiredID.uuidString.lowercased()).md")
            try Data("""
            ---
            capsule: \(retired)
            version: 1
            id: "\(retiredID.uuidString.lowercased())"
            title: "退役条目 \(retired)"
            updated_at: "2026-01-01T00:00:00Z"
            ---

            retired body
            """.utf8).write(to: retiredURL)
        }
        let survivors = try contentStore.listRecords()
        guard survivors.allSatisfy({
            !$0.summary.title.hasPrefix("退役条目")
        }) else {
            return fail("retired kinds must not be listed")
        }
        let retiredFiles = try FileManager.default.contentsOfDirectory(
            atPath: contentStore.entryDirectoryURL.path
        ).filter { $0.hasSuffix(".md") }
        guard retiredFiles.count >= 3 else {
            return fail("retired files must stay on disk untouched")
        }

        instant.addTimeInterval(1)
        let imageFixture = root.appendingPathComponent("example.png")
        let pdfFixture = root.appendingPathComponent("example.pdf")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageFixture)
        try Data("%PDF-1.4\n".utf8).write(to: pdfFixture)
        let prompt = try contentStore.put(CapsuleContentWriteRequest(
            type: .note,
            title: "总结论文",
            content: "请总结这篇论文的核心贡献。"
        ))
        let memory = try contentStore.put(CapsuleContentWriteRequest(
            type: .note,
            title: "项目事实",
            content: "Capsule 条目使用 Markdown 管理。"
        ))
        let skill = try contentStore.put(CapsuleContentWriteRequest(
            type: .skill,
            title: "示例技能",
            content: "/tmp/example-skill"
        ))
        let note = try contentStore.put(CapsuleContentWriteRequest(
            type: .note,
            title: "会议笔记",
            content: "# 决策\n\n每个 Capsule 文件保存一条记录。"
        ))
        let image = try contentStore.put(CapsuleContentWriteRequest(
            type: .image,
            title: "示例图片",
            content: imageFixture.path
        ))
        let pdf = try contentStore.put(CapsuleContentWriteRequest(
            type: .pdf,
            title: "示例文档",
            content: pdfFixture.path
        ))
        guard try contentStore.record(id: prompt.id).content
                == "请总结这篇论文的核心贡献。",
              try contentStore.search("核心贡献", kind: .skill, limit: 5)
                .isEmpty,
              try contentStore.search("核心贡献", limit: 5)
                .map(\.summary.id) == [prompt.id],
              try contentStore.search("Markdown", limit: 5)
                .map(\.summary.id) == [memory.id],
              try contentStore.record(id: skill.id).content
                == "/tmp/example-skill",
              try contentStore.record(id: note.id).content.contains("# 决策"),
              try contentStore.record(id: image.id).snippet
                == "Image · example.png",
              try contentStore.record(id: pdf.id).snippet
                == "PDF · example.pdf",
              Set(try contentStore.listRecords().map(\.summary.type))
                == Set([.skill, .note, .image, .pdf]) else {
            return fail("all ordinary Capsule kinds Markdown round trip")
        }
        instant.addTimeInterval(1)
        let updatedPrompt = try contentStore.put(CapsuleContentWriteRequest(
            id: prompt.id,
            type: .note,
            title: "总结论文（精简）",
            content: "用三点总结论文。"
        ))
        guard updatedPrompt.id == prompt.id,
              updatedPrompt.updatedAt == instant,
              try contentStore.record(id: prompt.id).content
                == "用三点总结论文。" else {
            return fail("ordinary Capsule entry update")
        }
        do {
            _ = try contentStore.put(CapsuleContentWriteRequest(
                type: .skill,
                title: "相对路径",
                content: "relative/example-skill"
            ))
            return fail("relative Skill path accepted")
        } catch CapsuleContentStoreError.invalidRequest {
            // Expected.
        }
        for invalid in [
            CapsuleContentWriteRequest(
                type: .image,
                title: "错误图片类型",
                content: pdfFixture.path
            ),
            CapsuleContentWriteRequest(
                type: .pdf,
                title: "错误 PDF 类型",
                content: imageFixture.path
            ),
        ] {
            do {
                _ = try contentStore.put(invalid)
                return fail("invalid URL/media entry accepted")
            } catch CapsuleContentStoreError.invalidRequest {
                // Expected.
            }
        }

        let firstRequest = CapsulePasswordWriteRequest(
            title: "示例站点",
            body: """
            - 网址：https://example.invalid/login
            - 用户名：fixture-user
            - 密码：fixture-current-password
            """
        )
        let first = try passwordStore.put(firstRequest)
        guard permissions(passwordStore.passwordDirectoryURL.path) == 0o700,
              permissions(passwordStore.masterKeyURL.path) == 0o600,
              permissions(first.fileURL.path) == 0o600 else {
            return fail("password private filesystem permissions")
        }

        let markdown = try String(contentsOf: first.fileURL, encoding: .utf8)
        guard markdown.contains("capsule: password"),
              markdown.contains("title: \"示例站点\""),
              markdown.contains("```capsule-password"),
              !markdown.contains("fixture-user"),
              !markdown.contains("fixture-current-password"),
              !markdown.contains("fixture-old-password"),
              !markdown.contains("example.invalid") else {
            return fail("password Markdown plaintext boundary")
        }

        let summaries = try passwordStore.listSummaries()
        guard summaries.count == 1,
              summaries[0].id == first.id,
              summaries[0].title == "示例站点",
              summaries[0].maskedPassword == "••••••••",
              try passwordStore.search("示例", limit: 5).map(\.id) == [first.id],
              try passwordStore.search("fixture-user", limit: 5).isEmpty else {
            return fail("password title-only local search")
        }

        let copiedPasswordURL = passwordStore.passwordDirectoryURL
            .appendingPathComponent("copied-in-obsidian.md")
        try FileManager.default.copyItem(
            at: first.fileURL,
            to: copiedPasswordURL
        )
        guard chmod(copiedPasswordURL.path, 0o600) == 0 else {
            return fail("copied password fixture permissions")
        }
        do {
            _ = try passwordStore.listSummaries()
            return fail("password filename and authenticated UUID diverged")
        } catch CapsulePasswordStoreError.malformedDocument {
            // Expected: an Obsidian copy must never alias the canonical UUID.
        }
        try FileManager.default.removeItem(at: copiedPasswordURL)

        let decrypted = try passwordStore.record(id: first.id)
        guard decrypted.secret.body == firstRequest.body else {
            return fail("encrypted password round trip")
        }

        // Records written before the body replaced the fixed field set must
        // still open. Their values fold into the same Markdown rather than
        // failing to decode and stranding the user's only copy.
        let legacyRequest = try? JSONDecoder().decode(
            CapsulePasswordWriteRequest.self,
            from: Data("""
            {"title":"旧结构条目",
             "url":"https://legacy.invalid",
             "username":"legacy-user",
             "password":"legacy-secret",
             "previousPasswords":["legacy-old"]}
            """.utf8)
        )
        guard let legacyRequest,
              legacyRequest.title == "旧结构条目",
              legacyRequest.body.contains("- 网址：https://legacy.invalid"),
              legacyRequest.body.contains("- 用户名：legacy-user"),
              legacyRequest.body.contains("- 密码：legacy-secret"),
              legacyRequest.body.contains("- 曾用密码 1：legacy-old") else {
            return fail("retired password field set must fold into a body")
        }
        let legacySummary = try passwordStore.put(legacyRequest)
        guard try passwordStore.record(id: legacySummary.id).secret.body
                == legacyRequest.body else {
            return fail("migrated legacy password round trip")
        }
        // Leave the fixture store as it was for the assertions that follow.
        try passwordStore.remove(id: legacySummary.id)

        instant.addTimeInterval(10)
        let updated = try passwordStore.put(CapsulePasswordWriteRequest(
            id: first.id,
            title: "示例站点（工作）",
            body: "- 密码：fixture-rotated-password"
        ))
        let updatedRecord = try passwordStore.record(id: first.id)
        guard updated.id == first.id,
              updated.title == "示例站点（工作）",
              updated.updatedAt == instant,
              updatedRecord.secret.body == "- 密码：fixture-rotated-password" else {
            return fail("password update and previous password")
        }

        var tampered = try String(contentsOf: updated.fileURL, encoding: .utf8)
        tampered = tampered.replacingOccurrences(
            of: "title: \"示例站点（工作）\"",
            with: "title: \"被修改标题\""
        )
        try Data(tampered.utf8).write(to: updated.fileURL, options: .atomic)
        guard chmod(updated.fileURL.path, 0o600) == 0 else {
            return fail("tamper fixture permissions")
        }
        do {
            _ = try passwordStore.record(id: first.id)
            return fail("authenticated password title tamper was accepted")
        } catch CapsulePasswordStoreError.decryptionFailed {
            // Expected.
        }

        try passwordStore.remove(id: first.id)
        guard try passwordStore.listSummaries().isEmpty else {
            return fail("password record removal")
        }
    } catch {
        return fail("unexpected error: \(error.localizedDescription)")
    }

    print("Capsule smoke: OK")
    return true
}

private func permissions(_ path: String) -> mode_t? {
    var metadata = stat()
    guard path.withCString({ stat($0, &metadata) }) == 0 else { return nil }
    return metadata.st_mode & mode_t(0o777)
}

private func fail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}
