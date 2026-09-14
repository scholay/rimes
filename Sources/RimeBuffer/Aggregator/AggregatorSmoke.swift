import Foundation

/// Fixtures are transcribed from the live CometAPI catalog (292 models at the
/// time of writing) rather than invented, because every rule here exists to
/// absorb a specific inconsistency that catalog actually contains.
func runAggregatorSmokeTest() -> Bool {
    print("== RIMES aggregator smoke ==")

    // 1. Family names are unreliable identity. The published catalog spells
    //    one endpoint many ways; only (method, path) is stable.
    let chatAliases = ["openai", "openai-chat", "chat"]
    let editAliases = ["image-edit", "image-editing", "image_editing",
                       "openai-image-edit"]
    for family in chatAliases {
        guard AggregatorEndpointRules.pathForFamily[family]?.path
                == "/v1/chat/completions" else {
            return aggregatorFail("chat alias \(family)")
        }
    }
    for family in editAliases {
        guard AggregatorEndpointRules.pathForFamily[family]?.path
                == "/v1/images/edits" else {
            return aggregatorFail("image-edit alias \(family)")
        }
    }
    let shapes: [(String, String, AggregatorAdapter, AggregatorDeliveryMode)] = [
        ("POST", "/v1/chat/completions", .chatCompletions, .streaming),
        ("POST", "/v1/responses", .responses, .streaming),
        ("POST", "/v1/messages", .anthropicMessages, .streaming),
        ("POST", "/v1beta/models/{model}:{operator}", .geminiGenerateContent, .streaming),
        ("POST", "/v1beta/models/{model}:generateContent", .geminiGenerateContent, .streaming),
        ("POST", "/v1/images/generations", .imageGeneration, .immediate),
        ("POST", "/v1/images/edits", .imageEdit, .immediate),
        ("POST", "/v1/videos", .videoSubmit, .asyncJob),
        ("GET", "/v1/videos/{task_id}", .videoResult, .immediate),
        ("GET", "/v1/videos/{task_id}/content", .videoContent, .immediate),
        ("POST", "/bria/text-to-image", .vendorSubmit, .asyncJob),
        ("POST", "/flux/v1/{model}", .vendorSubmit, .asyncJob),
        ("POST", "/mj/submit/imagine", .vendorSubmit, .asyncJob),
        ("POST", "/grok/v1/videos/generations", .vendorSubmit, .asyncJob),
        ("POST", "/replicate/v1/models/{models}/predictions", .vendorSubmit, .asyncJob),
        ("GET", "/v1/realtime", .realtime, .unsupported),
        ("POST", "/some/endpoint/nobody/has/seen", .rawPassthrough, .immediate),
    ]
    for (method, path, adapter, mode) in shapes {
        let resolved = AggregatorEndpointRules.adapter(method: method, path: path)
        guard resolved == adapter, resolved.deliveryMode == mode else {
            return aggregatorFail("shape \(method) \(path) -> \(resolved)")
        }
    }
    // Case and a missing leading slash must not create a second adapter.
    guard AggregatorEndpointRules.adapter(method: "post",
                                          path: "v1/chat/completions/")
            == .chatCompletions else {
        return aggregatorFail("path normalization")
    }

    // 2. The catalog encodes `endpoints` four ways. Three are recoverable and
    //    together account for well over a third of the models; discarding
    //    them would silently halve the usable catalog.
    let objectForm = """
    {"data":[{"id":"gpt-image-2.5-flare","model_type":"image",
      "endpoints":{"image-edit":{"method":"POST","path":"/v1/images/edits"},
                   "image-generation":{"method":"POST","path":"/v1/images/generations"}}}]}
    """
    let arrayForm = """
    {"data":[{"id":"qwen-image","model_type":"",
      "endpoints":["image-generation","openai"]}]}
    """
    let nestedStringForm = """
    {"data":[{"id":"black-forest-labs/flux-2-pro","model_type":"",
      "endpoints":{"replicate":"{ \\"path\\": \\"/replicate/v1/models/{models}/predictions\\", \\"method\\": \\"POST\\" }"}}]}
    """
    let unusableForm = """
    {"data":[{"id":"mystery-model","model_type":"","endpoints":""},
             {"id":"empty-array","model_type":"","endpoints":[]},
             {"id":"null-endpoints","model_type":"","endpoints":null}]}
    """
    guard let object = try? AggregatorCatalogParser.models(
            from: Data(objectForm.utf8)),
          object.count == 1,
          object[0].endpoints.map(\.adapter) == [.imageEdit, .imageGeneration],
          object[0].primaryAdapter == .imageEdit else {
        return aggregatorFail("documented object form")
    }
    guard let array = try? AggregatorCatalogParser.models(
            from: Data(arrayForm.utf8)),
          array[0].isUsable,
          Set(array[0].endpoints.map(\.adapter))
            == Set([.imageGeneration, .chatCompletions]) else {
        return aggregatorFail("bare family-name array must still resolve")
    }
    guard let nested = try? AggregatorCatalogParser.models(
            from: Data(nestedStringForm.utf8)),
          nested[0].endpoints.count == 1,
          nested[0].endpoints[0].path
            == "/replicate/v1/models/{models}/predictions",
          nested[0].primaryAdapter == .vendorSubmit else {
        return aggregatorFail("doubly encoded descriptor must be decoded")
    }
    guard let unusable = try? AggregatorCatalogParser.models(
            from: Data(unusableForm.utf8)),
          unusable.count == 3,
          unusable.allSatisfy({ !$0.isUsable }) else {
        return aggregatorFail("genuinely empty records must report unusable")
    }
    // An unusable record is still listed. It is the request box's job to send
    // it, not the catalog's job to hide it.
    guard unusable.map(\.id).contains("mystery-model") else {
        return aggregatorFail("unusable models must stay selectable")
    }

    // 3. Placeholders are reported, never guessed into the URL.
    guard AggregatorPathTemplate.placeholders(in: "/v1beta/models/{model}:{operator}")
            == ["model", "operator"],
          AggregatorPathTemplate.expand("/v1/videos/{task_id}/content",
                                        values: ["task_id": "abc123"])
            == .expanded("/v1/videos/abc123/content"),
          AggregatorPathTemplate.expand("/v1beta/models/{model}:{operator}",
                                        values: ["model": "gemini-3.8-flash"])
            == .missing(["operator"]),
          AggregatorPathTemplate.expand("/v1/videos/{task_id}",
                                        values: ["task_id": "   "])
            == .missing(["task_id"]) else {
        return aggregatorFail("path templating")
    }

    // 4. Replies are classified by shape alone. The catalog reports no model
    //    type for roughly a third of its models, so nothing may depend on it.
    let chatReply = Data("""
    {"choices":[{"message":{"role":"assistant","content":"Hello there."}}]}
    """.utf8)
    let anthropicReply = Data("""
    {"content":[{"type":"text","text":"# Heading\\n\\n- one\\n- two"}]}
    """.utf8)
    let geminiReply = Data("""
    {"candidates":[{"content":{"parts":[{"text":"From Gemini."}]}}]}
    """.utf8)
    let responsesReply = Data("""
    {"output":[{"content":[{"type":"output_text","text":"From Responses."}]}]}
    """.utf8)
    let imageReply = Data("""
    {"data":[{"url":"https://cdn.example.invalid/a.png"}]}
    """.utf8)
    let jobReceipt = Data("""
    {"task_id":"vid_9f2","status":"queued"}
    """.utf8)
    let notJSON = Data("upstream returned an HTML error page".utf8)

    guard AggregatorResponseReader.read(chatReply, adapter: .chatCompletions)
            == AggregatorRenderedResponse(format: .plain, text: "Hello there.",
                                          artifacts: [], taskID: nil),
          AggregatorResponseReader.read(anthropicReply,
                                        adapter: .anthropicMessages).format
            == .markdown,
          AggregatorResponseReader.read(geminiReply,
                                        adapter: .geminiGenerateContent).text
            == "From Gemini.",
          AggregatorResponseReader.read(responsesReply, adapter: .responses).text
            == "From Responses." else {
        return aggregatorFail("assistant text across four provider shapes")
    }
    let image = AggregatorResponseReader.read(imageReply, adapter: .imageGeneration)
    guard image.format == .artifactURL,
          image.artifacts == ["https://cdn.example.invalid/a.png"] else {
        return aggregatorFail("image artifact extraction")
    }
    let job = AggregatorResponseReader.read(jobReceipt, adapter: .videoSubmit)
    guard job.taskID == "vid_9f2", job.isPendingJob, job.format == .json else {
        return aggregatorFail("job receipt must read as pending, not finished")
    }
    let broken = AggregatorResponseReader.read(notJSON, adapter: .rawPassthrough)
    guard broken.format == .plain,
          broken.text.contains("HTML error page") else {
        return aggregatorFail("non-JSON reply must survive verbatim")
    }

    // 5. Saved raw bodies keep the envelope and drop the payload. One image
    //    reply carrying inline base64 would otherwise put megabytes into a
    //    store designed to hold a text transcript.
    let inlineBase64 = "{\"data\":[{\"b64_json\":\""
        + String(repeating: "A", count: 4096)
        + "\",\"revised_prompt\":\"a cat\"}]}"
    let retained = AggregatorRawBodyRetention.retained(inlineBase64)
    guard retained.contains(AggregatorRawBodyRetention.elidedMarker),
          retained.contains("revised_prompt"),
          !retained.contains(String(repeating: "A", count: 512)),
          retained.utf8.count < 1_024 else {
        return aggregatorFail("base64 elision: kept \(retained.utf8.count) bytes")
    }
    // A short base64-looking value is a real field, not a payload.
    let shortValue = "{\"b64_json\":\"c2hvcnQ=\"}"
    guard AggregatorRawBodyRetention.retained(shortValue) == shortValue else {
        return aggregatorFail("short values must not be elided")
    }
    let oversized = String(repeating: "x", count: 600 * 1024)
    let capped = AggregatorRawBodyRetention.retained(oversized)
    guard capped.utf8.count < 300 * 1024, capped.contains("已截断") else {
        return aggregatorFail("oversized body cap")
    }
    // Truncation must not split a multi-byte character.
    let multibyte = String(repeating: "中", count: 200)
    let cappedCJK = AggregatorRawBodyRetention.retained(multibyte,
                                                        maximumBytes: 101)
    guard cappedCJK.contains("已截断"),
          !cappedCJK.contains("\u{FFFD}") else {
        return aggregatorFail("truncation split a UTF-8 scalar")
    }

    print("aggregator smoke: OK")
    return true
}

private func aggregatorFail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}
