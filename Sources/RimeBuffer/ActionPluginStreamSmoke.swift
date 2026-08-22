import Foundation

private func streamSmokeFail(_ message: String) -> Bool {
    print("FAILED: action plugin stream \(message)")
    return false
}

private func streamSmokeRunLoopUntil(timeout: TimeInterval = 1,
                                     _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        _ = RunLoop.main.run(mode: .default,
                             before: min(deadline, Date().addingTimeInterval(0.01)))
    } while Date() < deadline
    return predicate()
}

private func streamSmokeDrainMainQueue(for duration: TimeInterval = 0.05) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default,
                             before: min(deadline, Date().addingTimeInterval(0.01)))
    }
}

private func streamSmokeFrame(identity: ActionPluginStreamIdentity,
                              sequence: Int,
                              type: String,
                              fields: [String: Any] = [:],
                              newline: Bool = true) throws -> Data {
    var object: [String: Any] = [
        "protocolVersion": ActionPluginStreamParser.protocolVersion,
        "type": type,
        "seq": sequence,
        "pluginId": identity.pluginId,
        "runtimeInstanceId": identity.runtimeInstanceId,
        "requestId": identity.requestId,
        "actionId": identity.actionId,
        "contextId": identity.contextId,
    ]
    fields.forEach { object[$0.key] = $0.value }
    var data = try JSONSerialization.data(withJSONObject: object,
                                          options: [.sortedKeys])
    if newline { data.append(0x0A) }
    return data
}

/// Produces an exact UTF-8 byte length while ensuring the fixture contains
/// multi-byte Chinese scalars. This catches accidental use of `String.count`.
private func streamSmokeUTF8Text(byteCount: Int) -> String {
    precondition(byteCount >= 0)
    let chineseCount = byteCount / 3
    let asciiCount = byteCount % 3
    let value = String(repeating: "你", count: chineseCount)
        + String(repeating: "a", count: asciiCount)
    precondition(value.utf8.count == byteCount)
    return value
}

private func runActionPluginStreamParserSmokeTest() -> Bool {
    let identity = ActionPluginStreamIdentity(pluginId: "marine",
                                              runtimeInstanceId: "runtime-1",
                                              requestId: "request-1",
                                              actionId: "marine.generate",
                                              contextId: "comment-1")
    do {
        var wire = Data()
        wire.append(try streamSmokeFrame(identity: identity,
                                         sequence: 1,
                                         type: "heartbeat"))
        wire.append(try streamSmokeFrame(identity: identity,
                                         sequence: 2,
                                         type: "block",
                                         fields: [
                                             "index": 0,
                                             "text": "草稿",
                                             "title": "回复",
                                         ]))
        wire.append(try streamSmokeFrame(identity: identity,
                                         sequence: 3,
                                         type: "block",
                                         fields: [
                                             "index": 0,
                                             "text": "草稿完成",
                                             "title": "回复",
                                         ]))
        wire.append(try streamSmokeFrame(identity: identity,
                                         sequence: 4,
                                         type: "complete",
                                         fields: [
                                             "blocks": [[
                                                 "text": "最终回复",
                                                 "title": "回复",
                                             ]],
                                             "targetSummary": "目标评论",
                                         ],
                                         newline: false))

        var parser = ActionPluginStreamParser(expectedIdentity: identity)
        var events: [ActionPluginStreamEvent] = []
        let cuts = [7, 41, wire.count]
        var start = 0
        for end in cuts {
            events.append(contentsOf: try parser.append(wire.subdata(in: start..<end)))
            start = end
        }
        let finished = try parser.finish()
        events.append(contentsOf: finished.events)
        guard events.count == 3,
              events[0] == .heartbeat(identity: identity, sequence: 1),
              events[1] == .block(.init(identity: identity,
                                        sequence: 2,
                                        index: 0,
                                        text: "草稿",
                                        title: "回复")),
              events[2] == .block(.init(identity: identity,
                                        sequence: 3,
                                        index: 0,
                                        text: "草稿完成",
                                        title: "回复")),
              finished.response == ActionPluginInvokeResponse(
                  requestId: identity.requestId,
                  actionId: identity.actionId,
                  contextId: identity.contextId,
                  blocks: [ActionPluginResultBlock(text: "最终回复", title: "回复")],
                  targetSummary: "目标评论"
              ) else {
            return streamSmokeFail("parser did not preserve split frames and terminal result")
        }

        var earlyTerminalParser = ActionPluginStreamParser(expectedIdentity: identity)
        _ = try earlyTerminalParser.append(streamSmokeFrame(
            identity: identity,
            sequence: 1,
            type: "complete",
            fields: ["blocks": [["text": "无需等待 EOF"]]]
        ))
        guard earlyTerminalParser.completedResponse?.blocks.map(\.text)
                == ["无需等待 EOF"] else {
            return streamSmokeFail("parser did not expose a delimited terminal frame early")
        }

        func rejects(_ body: (inout ActionPluginStreamParser) throws -> Void) -> Bool {
            var candidate = ActionPluginStreamParser(expectedIdentity: identity)
            do {
                try body(&candidate)
                return false
            } catch {
                return true
            }
        }

        var zeroBasedParser = ActionPluginStreamParser(expectedIdentity: identity)
        do {
            _ = try zeroBasedParser.append(
                streamSmokeFrame(identity: identity,
                                 sequence: 0,
                                 type: "heartbeat")
            )
            return streamSmokeFail("parser accepted seq=0 as the first frame")
        } catch ActionPluginStreamError.invalidSequence {
            // Required cross-repository contract: Marine begins at seq=1.
        } catch {
            return streamSmokeFail("seq=0 failed for the wrong reason: \(error)")
        }

        var oneBasedParser = ActionPluginStreamParser(expectedIdentity: identity)
        let oneBasedEvents = try oneBasedParser.append(
            streamSmokeFrame(identity: identity,
                             sequence: 1,
                             type: "heartbeat")
        )
        guard oneBasedEvents == [.heartbeat(identity: identity, sequence: 1)] else {
            return streamSmokeFail("parser rejected seq=1 as the first frame")
        }

        let maximumIdentity = ActionPluginStreamIdentity(
            pluginId: identity.pluginId,
            runtimeInstanceId: identity.runtimeInstanceId,
            requestId: identity.requestId,
            actionId: identity.actionId,
            contextId: String(repeating: "~", count: 128)
        )
        var maximumIdentityParser = ActionPluginStreamParser(
            expectedIdentity: maximumIdentity
        )
        let maximumIdentityEvents = try maximumIdentityParser.append(
            streamSmokeFrame(identity: maximumIdentity,
                             sequence: 1,
                             type: "heartbeat")
        )
        let oversizedIdentity = ActionPluginStreamIdentity(
            pluginId: identity.pluginId,
            runtimeInstanceId: identity.runtimeInstanceId,
            requestId: identity.requestId,
            actionId: identity.actionId,
            contextId: String(repeating: "a", count: 129)
        )
        let nonASCIIIdentity = ActionPluginStreamIdentity(
            pluginId: identity.pluginId,
            runtimeInstanceId: identity.runtimeInstanceId,
            requestId: identity.requestId,
            actionId: identity.actionId,
            contextId: "评论-1"
        )
        let delIdentity = ActionPluginStreamIdentity(
            pluginId: identity.pluginId,
            runtimeInstanceId: identity.runtimeInstanceId,
            requestId: identity.requestId,
            actionId: identity.actionId,
            contextId: "comment\u{7F}"
        )
        guard maximumIdentityEvents == [
            .heartbeat(identity: maximumIdentity, sequence: 1),
        ],
        ActionPluginStreamParser.validIdentity(maximumIdentity),
        !ActionPluginStreamParser.validIdentity(oversizedIdentity),
        !ActionPluginStreamParser.validIdentity(nonASCIIIdentity),
        !ActionPluginStreamParser.validIdentity(delIdentity) else {
            return streamSmokeFail("printable ASCII identity byte contract drifted")
        }

        let blockAtLimit = streamSmokeUTF8Text(
            byteCount: ActionPluginStreamParser.maximumBlockBytes
        )
        let blockOverLimit = blockAtLimit + "a"
        var blockBoundaryParser = ActionPluginStreamParser(expectedIdentity: identity)
        let blockBoundaryEvents = try blockBoundaryParser.append(
            streamSmokeFrame(identity: identity,
                             sequence: 1,
                             type: "block",
                             fields: ["index": 0, "text": blockAtLimit])
        )
        guard blockBoundaryEvents == [
            .block(.init(identity: identity,
                         sequence: 1,
                         index: 0,
                         text: blockAtLimit,
                         title: nil)),
        ], rejects({ parser in
            _ = try parser.append(streamSmokeFrame(
                identity: identity,
                sequence: 1,
                type: "block",
                fields: ["index": 0, "text": blockOverLimit]
            ))
        }) else {
            return streamSmokeFail("Chinese block text did not honor the 20,000-byte boundary")
        }

        let titleAtLimit = streamSmokeUTF8Text(
            byteCount: ActionPluginStreamParser.maximumTitleBytes
        )
        let titleOverLimit = titleAtLimit + "a"
        var titleBoundaryParser = ActionPluginStreamParser(expectedIdentity: identity)
        let titleBoundaryEvents = try titleBoundaryParser.append(
            streamSmokeFrame(identity: identity,
                             sequence: 1,
                             type: "block",
                             fields: [
                                 "index": 0,
                                 "text": "正文",
                                 "title": titleAtLimit,
                             ])
        )
        guard titleBoundaryEvents == [
            .block(.init(identity: identity,
                         sequence: 1,
                         index: 0,
                         text: "正文",
                         title: titleAtLimit)),
        ], rejects({ parser in
            _ = try parser.append(streamSmokeFrame(
                identity: identity,
                sequence: 1,
                type: "block",
                fields: [
                    "index": 0,
                    "text": "正文",
                    "title": titleOverLimit,
                ]
            ))
        }) else {
            return streamSmokeFail("Chinese title did not honor the 200-byte boundary")
        }

        let summaryAtLimit = streamSmokeUTF8Text(
            byteCount: ActionPluginStreamParser.maximumSummaryBytes
        )
        let summaryOverLimit = summaryAtLimit + "a"
        var summaryBoundaryParser = ActionPluginStreamParser(expectedIdentity: identity)
        _ = try summaryBoundaryParser.append(streamSmokeFrame(
            identity: identity,
            sequence: 1,
            type: "complete",
            fields: [
                "blocks": [["text": "完成"]],
                "targetSummary": summaryAtLimit,
            ]
        ))
        let summaryBoundaryResult = try summaryBoundaryParser.finish()
        guard summaryBoundaryResult.response.targetSummary == summaryAtLimit,
              rejects({ parser in
                  _ = try parser.append(streamSmokeFrame(
                      identity: identity,
                      sequence: 1,
                      type: "complete",
                      fields: [
                          "blocks": [["text": "完成"]],
                          "targetSummary": summaryOverLimit,
                      ]
                  ))
              }) else {
            return streamSmokeFail("Chinese summary did not honor the 1,000-byte boundary")
        }

        // The authoritative terminal frame repeats every final block. Verify
        // the line budget can carry the full protocol aggregate rather than
        // accepting the incremental snapshots and then failing at completion.
        let aggregateBlocks = (0..<ActionPluginStreamParser.maximumBlocks).map { _ in
            ["text": blockAtLimit]
        }
        let aggregateCompleteFrame = try streamSmokeFrame(
            identity: identity,
            sequence: 1,
            type: "complete",
            fields: ["blocks": aggregateBlocks]
        )
        guard aggregateCompleteFrame.count > 128 * 1_024,
              aggregateCompleteFrame.count <= ActionPluginStreamParser.maximumLineBytes else {
            return streamSmokeFail("full aggregate complete frame exceeded the line budget")
        }
        var aggregateParser = ActionPluginStreamParser(expectedIdentity: identity)
        _ = try aggregateParser.append(aggregateCompleteFrame)
        let aggregateResult = try aggregateParser.finish()
        guard aggregateResult.response.blocks.count
                == ActionPluginStreamParser.maximumBlocks,
              aggregateResult.response.blocks.allSatisfy({ $0.text == blockAtLimit }) else {
            return streamSmokeFail("parser did not accept the full aggregate complete frame")
        }

        let errorAtLimit = streamSmokeUTF8Text(
            byteCount: ActionPluginStreamParser.maximumErrorBytes
        )
        let errorOverLimit = errorAtLimit + "a"
        var errorBoundaryParser = ActionPluginStreamParser(expectedIdentity: identity)
        do {
            _ = try errorBoundaryParser.append(streamSmokeFrame(
                identity: identity,
                sequence: 1,
                type: "error",
                fields: ["message": errorAtLimit]
            ))
            return streamSmokeFail("parser accepted an error frame without terminating")
        } catch ActionPluginStreamError.remote(let message) {
            guard message == errorAtLimit else {
                return streamSmokeFail("parser changed the boundary error message")
            }
        } catch {
            return streamSmokeFail("500-byte Chinese error was rejected: \(error)")
        }
        var oversizedErrorParser = ActionPluginStreamParser(expectedIdentity: identity)
        do {
            _ = try oversizedErrorParser.append(streamSmokeFrame(
                identity: identity,
                sequence: 1,
                type: "error",
                fields: ["message": errorOverLimit]
            ))
            return streamSmokeFail("parser accepted a 501-byte error message")
        } catch ActionPluginStreamError.invalidFrame {
            // Expected: byte bound is checked before surfacing a remote error.
        } catch {
            return streamSmokeFail("501-byte error failed for the wrong reason: \(error)")
        }

        guard rejects({ parser in
            _ = try parser.append(streamSmokeFrame(identity: identity,
                                                   sequence: 2,
                                                   type: "heartbeat"))
        }) else { return streamSmokeFail("parser accepted a sequence gap") }

        let wrongIdentity = ActionPluginStreamIdentity(pluginId: "marine",
                                                       runtimeInstanceId: "runtime-2",
                                                       requestId: "request-1",
                                                       actionId: "marine.generate",
                                                       contextId: "comment-1")
        guard rejects({ parser in
            _ = try parser.append(streamSmokeFrame(identity: wrongIdentity,
                                                   sequence: 1,
                                                   type: "heartbeat"))
        }) else { return streamSmokeFail("parser accepted a mismatched runtime identity") }

        guard rejects({ parser in
            _ = try parser.append(streamSmokeFrame(identity: identity,
                                                   sequence: 1,
                                                   type: "heartbeat"))
            _ = try parser.finish()
        }) else { return streamSmokeFail("parser accepted EOF before a terminal frame") }

        guard rejects({ parser in
            _ = try parser.append(streamSmokeFrame(
                identity: identity,
                sequence: 1,
                type: "complete",
                fields: ["blocks": [["text": "完成"]]]
            ))
            _ = try parser.append(streamSmokeFrame(identity: identity,
                                                   sequence: 2,
                                                   type: "heartbeat"))
        }) else { return streamSmokeFail("parser accepted data after the terminal frame") }

        guard rejects({ parser in
            _ = try parser.append(Data(repeating: 0x61,
                                       count: ActionPluginStreamParser.maximumLineBytes + 1))
        }) else { return streamSmokeFail("parser accepted an oversized line") }

        guard rejects({ parser in
            _ = try parser.append(Data(repeating: 0x61,
                                       count: ActionPluginStreamParser.maximumWireBytes + 1))
        }) else { return streamSmokeFail("parser accepted an oversized response") }

        guard rejects({ parser in
            for sequence in 1...(ActionPluginStreamParser.maximumEvents + 1) {
                _ = try parser.append(streamSmokeFrame(identity: identity,
                                                       sequence: sequence,
                                                       type: "heartbeat"))
            }
        }) else { return streamSmokeFail("parser accepted too many events") }

        guard rejects({ parser in
            _ = try parser.append(streamSmokeFrame(
                identity: identity,
                sequence: 1,
                type: "block",
                fields: [
                    "index": ActionPluginStreamParser.maximumBlocks,
                    "text": "越界",
                ]
            ))
        }) else { return streamSmokeFail("parser accepted an out-of-range block index") }
    } catch {
        return streamSmokeFail("parser threw \(error)")
    }
    return true
}

private func runActionPluginStreamModelSmokeTest() -> Bool {
    var epochs = FocusEpochState()
    let focus = epochs.activate()
    let model = BufferModel()
    let requestID = "model-request"
    let origin = Origin.plugin(id: "marine")
    let firstID = UUID()
    let secondID = UUID()

    func metadata(index: Int,
                  contextID: String = "comment-1",
                  incomplete: Bool) -> BufferModel.PluginMetadata {
        BufferModel.PluginMetadata(pluginId: "marine",
                                   actionId: "marine.generate",
                                   requestId: requestID,
                                   contextId: contextID,
                                   focusToken: focus,
                                   runtimeIdentity: "instance:runtime-1",
                                   title: "回复 \(index + 1)",
                                   targetSummary: "目标评论",
                                   incomplete: incomplete,
                                   streamProtocolVersion: 1,
                                   streamIndex: index)
    }

    let initial = [
        BufferModel.PluginStreamUpdate(id: firstID,
                                       index: 0,
                                       text: "第一段",
                                       origin: origin,
                                       metadata: metadata(index: 0, incomplete: true)),
        BufferModel.PluginStreamUpdate(id: secondID,
                                       index: 1,
                                       text: "第二段",
                                       origin: origin,
                                       metadata: metadata(index: 1, incomplete: true)),
    ]
    guard model.applyPluginStreamUpdates(requestId: requestID, updates: initial),
          model.blocks.map(\.id) == [firstID, secondID],
          model.blocks.map(\.text) == ["第一段", "第二段"],
          model.pendingDeliveryBlocks.isEmpty,
          model.hasIncompletePluginBlocks,
          model.blocks.allSatisfy({ $0.pluginMetadata?.incomplete == true }) else {
        return streamSmokeFail("model did not stage fail-closed provisional blocks")
    }

    let beforeRejectedUpdate = model.blocks.map { ($0.id, $0.text, $0.pluginMetadata) }
    let rejectedUpdate = [
        BufferModel.PluginStreamUpdate(id: firstID,
                                       index: 0,
                                       text: "不应部分写入",
                                       origin: origin,
                                       metadata: metadata(index: 0, incomplete: true)),
        BufferModel.PluginStreamUpdate(id: secondID,
                                       index: 1,
                                       text: "错误租约",
                                       origin: origin,
                                       metadata: metadata(index: 1,
                                                          contextID: "other-comment",
                                                          incomplete: true)),
    ]
    guard !model.applyPluginStreamUpdates(requestId: requestID, updates: rejectedUpdate),
          model.blocks.elementsEqual(beforeRejectedUpdate, by: { block, snapshot in
              block.id == snapshot.0
                  && block.text == snapshot.1
                  && block.pluginMetadata == snapshot.2
          }) else {
        return streamSmokeFail("model applied part of a rejected coalesced update")
    }

    let badFinals = [
        BufferModel.PluginStreamFinalBlock(id: firstID,
                                           index: 0,
                                           text: "最终第一段",
                                           origin: origin,
                                           metadata: metadata(index: 0, incomplete: false)),
        BufferModel.PluginStreamFinalBlock(id: secondID,
                                           index: 1,
                                           text: "错误最终租约",
                                           origin: origin,
                                           metadata: metadata(index: 1,
                                                              contextID: "other-comment",
                                                              incomplete: false)),
    ]
    let beforeRejectedFinal = model.blocks.map { ($0.id, $0.text, $0.pluginMetadata) }
    guard !model.finalizePluginStream(requestId: requestID,
                                      partialBlockIDs: [firstID, secondID],
                                      blocks: badFinals),
          model.blocks.elementsEqual(beforeRejectedFinal, by: { block, snapshot in
              block.id == snapshot.0
                  && block.text == snapshot.1
                  && block.pluginMetadata == snapshot.2
          }) else {
        return streamSmokeFail("model mutated before rejecting terminal promotion")
    }

    let finals = [
        BufferModel.PluginStreamFinalBlock(id: firstID,
                                           index: 0,
                                           text: "最终第一段",
                                           origin: origin,
                                           metadata: metadata(index: 0, incomplete: false)),
        BufferModel.PluginStreamFinalBlock(id: secondID,
                                           index: 1,
                                           text: "最终第二段",
                                           origin: origin,
                                           metadata: metadata(index: 1, incomplete: false)),
    ]
    let changeCount = model.changeCount
    guard model.finalizePluginStream(requestId: requestID,
                                     partialBlockIDs: [firstID, secondID],
                                     blocks: finals),
          model.changeCount == changeCount + 1,
          model.blocks.map(\.id) == [firstID, secondID],
          model.blocks.map(\.text) == ["最终第一段", "最终第二段"],
          model.pendingDeliveryCount == 2,
          !model.hasIncompletePluginBlocks else {
        return streamSmokeFail("model did not atomically promote the terminal snapshot")
    }

    // An external Action Plugin can return several logical blocks in one
    // blocks-v1 response. A primary send action (Return or paper plane) must
    // validate and consume exactly one block per activation, preserving the
    // remainder in order.
    var insertedTexts: [String] = []
    var completedResults: [BufferDeliveryCoordinator.SendResult] = []
    let coordinator = BufferDeliveryCoordinator(
        model: model,
        dependencies: .init(
            resolveTarget: { expected in
                guard expected == nil || expected == focus else { return nil }
                return .init(
                    token: focus,
                    compositionActive: false,
                    resolveComposition: {},
                    deliver: { block in
                        insertedTexts.append(block.text)
                        return true
                    }
                )
            },
            secureInputEnabled: { false },
            validatePlugin: { _, _, completion in completion(.allowed) },
            refreshUI: {}
        )
    )
    let firstSend = coordinator.sendNext(
        expectedToken: focus,
        completion: { completedResults.append($0) }
    )
    guard firstSend.deferred,
          completedResults == [.init(sentCount: 1, blockedReason: nil)],
          insertedTexts == ["最终第一段"],
          model.blocks.map(\.id) == [secondID],
          model.blocks.map(\.text) == ["最终第二段"] else {
        return streamSmokeFail("primary send did not preserve the next action block")
    }
    let secondSend = coordinator.sendNext(
        expectedToken: focus,
        completion: { completedResults.append($0) }
    )
    guard secondSend.deferred,
          completedResults.count == 2,
          completedResults[0].sentCount == 1,
          completedResults[0].blockedReason == nil,
          completedResults[0].terminalDrain == nil,
          completedResults[1].sentCount == 1,
          completedResults[1].blockedReason == nil,
          completedResults[1].terminalDrain != nil,
          insertedTexts == ["最终第一段", "最终第二段"],
          model.blocks.isEmpty else {
        return streamSmokeFail("repeated primary sends did not advance one action block at a time")
    }
    return true
}

private final class ActionPluginStreamURLProtocolSmoke: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, Data))?
    static var holdsConnectionOpen = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler,
                  let url = request.url else {
                throw ActionPluginHTTPError.invalidResponse
            }
            let (status, contentType, data) = try handler(request)
            let response = HTTPURLResponse(url: url,
                                           statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            if !Self.holdsConnectionOpen {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func streamSmokeRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count == 0 { return body }
        guard count > 0 else { return nil }
        body.append(buffer, count: count)
    }
}

private func runActionPluginStreamHTTPFallbackSmokeTest() -> Bool {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ActionPluginStreamURLProtocolSmoke.self]
    let session = URLSession(configuration: configuration)
    defer {
        ActionPluginStreamURLProtocolSmoke.handler = nil
        ActionPluginStreamURLProtocolSmoke.holdsConnectionOpen = false
        session.invalidateAndCancel()
    }
    let client = ActionPluginHTTPClient(session: session)
    let action = ActionPluginDefinition(id: "marine.generate",
                                        title: "生成回复",
                                        symbol: "sparkles",
                                        statusPath: "/status",
                                        invokePath: "/invoke",
                                        streamPath: "/invoke-stream",
                                        modes: ["reply"])
    let plugin = InstalledActionPlugin(
        manifest: ActionPluginManifest(schemaVersion: 1,
                                       id: "marine",
                                       name: "Marine",
                                       version: "1.0.0",
                                       runtimeConfigPaths: ["runtime.json"],
                                       actions: [action]),
        directory: URL(fileURLWithPath: "/tmp/marine.etplugin")
    )
    let binding = ActionPluginRuntimeBinding(config: .init(
        pluginId: "marine",
        apiBase: "http://127.0.0.1:48777/v1/plugin",
        token: "stream-smoke-token",
        updatedAt: 1,
        instanceId: "runtime-1",
        processId: 10
    ))
    let request = ActionPluginInvokeRequest(requestId: "http-request",
                                            actionId: action.id,
                                            contextId: "comment-1",
                                            pluginId: "marine",
                                            runtimeInstanceId: "runtime-1")
    let jsonResponse = ActionPluginInvokeResponse(
        requestId: request.requestId,
        actionId: request.actionId,
        contextId: request.contextId,
        blocks: [ActionPluginResultBlock(text: "JSON 回退", title: "回复")],
        targetSummary: "目标评论"
    )
    var observedRequest = false
    ActionPluginStreamURLProtocolSmoke.handler = { urlRequest in
        let decodedPayload = streamSmokeRequestBody(urlRequest).flatMap {
            try? JSONDecoder().decode(ActionPluginInvokeRequest.self, from: $0)
        }
        observedRequest = urlRequest.url?.path == "/v1/plugin/invoke-stream"
            && urlRequest.timeoutInterval == ActionPluginHTTPClient.streamRequestTimeout
            && urlRequest.value(forHTTPHeaderField: "Accept")
                == "application/x-ndjson, application/json;q=0.8"
            && urlRequest.value(forHTTPHeaderField: "Authorization")
                == "Bearer stream-smoke-token"
            && decodedPayload == request
        let data = try JSONSerialization.data(withJSONObject: [
            "requestId": jsonResponse.requestId,
            "actionId": jsonResponse.actionId,
            "contextId": jsonResponse.contextId,
            "blocks": [["text": "JSON 回退", "title": "回复"]],
            "targetSummary": "目标评论",
        ], options: [.sortedKeys])
        return (200, "application/json; charset=utf-8", data)
    }
    let jsonSemaphore = DispatchSemaphore(value: 0)
    var decodedJSON: ActionPluginInvokeResponse?
    var unexpectedJSONEvents = 0
    _ = client.invoke(plugin: plugin,
                      action: action,
                      binding: binding,
                      request: request,
                      onStreamEvent: { _ in unexpectedJSONEvents += 1 },
                      completion: { result in
                          decodedJSON = try? result.get()
                          jsonSemaphore.signal()
                      })
    guard jsonSemaphore.wait(timeout: .now() + 2) == .success,
          observedRequest,
          unexpectedJSONEvents == 0,
          decodedJSON == jsonResponse else {
        return streamSmokeFail(
            "HTTP stream endpoint JSON fallback failed request=\(observedRequest) "
                + "events=\(unexpectedJSONEvents) decoded=\(decodedJSON != nil)"
        )
    }

    let identity = ActionPluginStreamIdentity(pluginId: "marine",
                                              runtimeInstanceId: "runtime-1",
                                              requestId: request.requestId,
                                              actionId: request.actionId,
                                              contextId: request.contextId)
    ActionPluginStreamURLProtocolSmoke.handler = { _ in
        var data = Data()
        data.append(try streamSmokeFrame(identity: identity,
                                         sequence: 1,
                                         type: "block",
                                         fields: ["index": 0, "text": "增量"]))
        data.append(try streamSmokeFrame(identity: identity,
                                         sequence: 2,
                                         type: "complete",
                                         fields: ["blocks": [["text": "最终"]]]))
        return (200, "application/x-ndjson", data)
    }
    let ndjsonSemaphore = DispatchSemaphore(value: 0)
    var streamEvents: [ActionPluginStreamEvent] = []
    var streamResponse: ActionPluginInvokeResponse?
    _ = client.invoke(plugin: plugin,
                      action: action,
                      binding: binding,
                      request: request,
                      onStreamEvent: { streamEvents.append($0) },
                      completion: { result in
                          streamResponse = try? result.get()
                          ndjsonSemaphore.signal()
                      })
    guard ndjsonSemaphore.wait(timeout: .now() + 2) == .success,
          streamEvents.count == 1,
          streamResponse?.blocks.map(\.text) == ["最终"] else {
        return streamSmokeFail("HTTP NDJSON response was not decoded")
    }

    // Production uses the incremental delegate. A provider is allowed to keep
    // its HTTP response alive after the authoritative complete frame; the host
    // must receive the result immediately instead of waiting 270 seconds for
    // EOF. Using a configuration (rather than an injected session) exercises
    // that exact delegate path with URLProtocol.
    let delegateConfiguration = URLSessionConfiguration.ephemeral
    delegateConfiguration.protocolClasses = [ActionPluginStreamURLProtocolSmoke.self]
    let delegateClient = ActionPluginHTTPClient(configuration: delegateConfiguration)
    ActionPluginStreamURLProtocolSmoke.holdsConnectionOpen = true
    ActionPluginStreamURLProtocolSmoke.handler = { _ in
        let terminal = try streamSmokeFrame(
            identity: identity,
            sequence: 1,
            type: "complete",
            fields: ["blocks": [["text": "保持连接也完成"]]]
        )
        return (200, "application/x-ndjson", terminal)
    }
    let heldOpenSemaphore = DispatchSemaphore(value: 0)
    var heldOpenResponse: ActionPluginInvokeResponse?
    let heldOpenCompletionLock = NSLock()
    var heldOpenCompletionCount = 0
    _ = delegateClient.invoke(plugin: plugin,
                              action: action,
                              binding: binding,
                              request: request,
                              onStreamEvent: { _ in },
                              completion: { result in
                                  heldOpenCompletionLock.lock()
                                  heldOpenCompletionCount += 1
                                  heldOpenCompletionLock.unlock()
                                  heldOpenResponse = try? result.get()
                                  heldOpenSemaphore.signal()
                              })
    guard heldOpenSemaphore.wait(timeout: .now() + 2) == .success,
          heldOpenResponse?.blocks.map(\.text) == ["保持连接也完成"] else {
        return streamSmokeFail("incremental transport waited for EOF after complete")
    }
    Thread.sleep(forTimeInterval: 0.05)
    heldOpenCompletionLock.lock()
    let observedHeldOpenCompletionCount = heldOpenCompletionCount
    heldOpenCompletionLock.unlock()
    guard observedHeldOpenCompletionCount == 1 else {
        return streamSmokeFail("incremental transport completed more than once")
    }
    ActionPluginStreamURLProtocolSmoke.holdsConnectionOpen = false

    ActionPluginStreamURLProtocolSmoke.handler = { _ in
        (503, "application/x-ndjson", Data())
    }
    let statusSemaphore = DispatchSemaphore(value: 0)
    var rejectedHTTPStatus = false
    _ = client.invoke(plugin: plugin,
                      action: action,
                      binding: binding,
                      request: request,
                      onStreamEvent: { _ in },
                      completion: { result in
                          if case let .failure(error) = result,
                             case ActionPluginHTTPError.status(503) = error {
                              rejectedHTTPStatus = true
                          }
                          statusSemaphore.signal()
                      })
    guard statusSemaphore.wait(timeout: .now() + 2) == .success,
          rejectedHTTPStatus else {
        return streamSmokeFail("HTTP NDJSON path accepted a failing status")
    }
    return true
}

private final class ActionPluginStreamSmokeCancellation: ActionPluginInvocationCancellable {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

private final class ActionPluginStreamSmokeTransport: ActionPluginTransport {
    struct Invocation {
        let payload: ActionPluginInvokeRequest
        let onEvent: (ActionPluginStreamEvent) -> Void
        let completion: (Result<ActionPluginInvokeResponse, Error>) -> Void
        let task: ActionPluginStreamSmokeCancellation
    }

    let binding: ActionPluginRuntimeBinding
    var status: ActionPluginStatus
    private(set) var invocations: [Invocation] = []

    init(binding: ActionPluginRuntimeBinding, status: ActionPluginStatus) {
        self.binding = binding
        self.status = status
    }

    func fetchStatus(plugin: InstalledActionPlugin,
                     action: ActionPluginDefinition,
                     binding: ActionPluginRuntimeBinding?,
                     completion: @escaping (Result<ActionPluginStatusSnapshot, Error>) -> Void) {
        completion(.success(.init(value: status, binding: binding ?? self.binding)))
    }

    func invoke(plugin: InstalledActionPlugin,
                action: ActionPluginDefinition,
                binding: ActionPluginRuntimeBinding,
                request payload: ActionPluginInvokeRequest,
                onStreamEvent: @escaping (ActionPluginStreamEvent) -> Void,
                completion: @escaping (Result<ActionPluginInvokeResponse, Error>) -> Void)
        -> ActionPluginInvocationCancellable? {
        let task = ActionPluginStreamSmokeCancellation()
        invocations.append(.init(payload: payload,
                                 onEvent: onStreamEvent,
                                 completion: completion,
                                 task: task))
        return task
    }
}

/// A deterministic two-plugin transport used only by the scoped management
/// regression below. Invokes stay open until the fixture completes them, and
/// selected status requests can be held so an old callback can race a newer
/// plugin generation.
private final class ActionPluginScopedStreamSmokeTransport: ActionPluginTransport {
    struct Invocation {
        let pluginID: String
        let payload: ActionPluginInvokeRequest
        let onEvent: (ActionPluginStreamEvent) -> Void
        let completion: (Result<ActionPluginInvokeResponse, Error>) -> Void
        let task: ActionPluginStreamSmokeCancellation
    }

    private struct PendingStatus {
        let pluginID: String
        let completion: (Result<ActionPluginStatusSnapshot, Error>) -> Void
        let result: Result<ActionPluginStatusSnapshot, Error>
    }

    let bindings: [String: ActionPluginRuntimeBinding]
    let statuses: [String: ActionPluginStatus]
    var heldStatusPluginIDs: Set<String> = []
    private(set) var invocations: [Invocation] = []
    private var pendingStatuses: [PendingStatus] = []

    init(bindings: [String: ActionPluginRuntimeBinding],
         statuses: [String: ActionPluginStatus]) {
        self.bindings = bindings
        self.statuses = statuses
    }

    var pendingStatusCount: Int { pendingStatuses.count }

    func fetchStatus(plugin: InstalledActionPlugin,
                     action: ActionPluginDefinition,
                     binding: ActionPluginRuntimeBinding?,
                     completion: @escaping (Result<ActionPluginStatusSnapshot, Error>) -> Void) {
        let pluginID = plugin.manifest.id
        let result: Result<ActionPluginStatusSnapshot, Error>
        if let status = statuses[pluginID],
           let resolvedBinding = binding ?? bindings[pluginID] {
            result = .success(.init(value: status, binding: resolvedBinding))
        } else {
            result = .failure(ActionPluginHTTPError.invalidResponse)
        }
        if heldStatusPluginIDs.contains(pluginID) {
            pendingStatuses.append(.init(pluginID: pluginID,
                                         completion: completion,
                                         result: result))
        } else {
            completion(result)
        }
    }

    func invoke(plugin: InstalledActionPlugin,
                action: ActionPluginDefinition,
                binding: ActionPluginRuntimeBinding,
                request payload: ActionPluginInvokeRequest,
                onStreamEvent: @escaping (ActionPluginStreamEvent) -> Void,
                completion: @escaping (Result<ActionPluginInvokeResponse, Error>) -> Void)
        -> ActionPluginInvocationCancellable? {
        let task = ActionPluginStreamSmokeCancellation()
        invocations.append(.init(pluginID: plugin.manifest.id,
                                 payload: payload,
                                 onEvent: onStreamEvent,
                                 completion: completion,
                                 task: task))
        return task
    }

    @discardableResult
    func completeNextHeldStatus(pluginID: String) -> Bool {
        guard let index = pendingStatuses.firstIndex(where: {
            $0.pluginID == pluginID
        }) else { return false }
        let pending = pendingStatuses.remove(at: index)
        pending.completion(pending.result)
        return true
    }
}

private final class ActionPluginStreamSmokeFocus {
    var token: FocusToken?
    var secureInput = false

    var access: ActionPluginFocusAccess {
        ActionPluginFocusAccess(currentToken: { [weak self] in self?.token },
                                isValid: { [weak self] in self?.token == $0 },
                                secureInputEnabled: { [weak self] in
                                    self?.secureInput ?? true
                                })
    }
}

private final class ActionPluginStreamSmokeLoader {
    var plugins: [InstalledActionPlugin]
    init(_ plugins: [InstalledActionPlugin]) { self.plugins = plugins }
    func load(_: URL) -> [InstalledActionPlugin] { plugins }
}

private final class ActionPluginStreamSmokeRuntimeAuthority {
    var current = true
}

private func runActionPluginScopedInvalidationSmokeTest() -> Bool {
    let pluginAID = "scoped-a"
    let pluginBID = "scoped-b"
    let actionA = ActionPluginDefinition(id: "\(pluginAID).generate",
                                         title: "A 生成",
                                         symbol: "a.circle",
                                         statusPath: "/status",
                                         invokePath: "/invoke",
                                         streamPath: "/invoke-stream",
                                         modes: ["reply"])
    let actionB = ActionPluginDefinition(id: "\(pluginBID).generate",
                                         title: "B 生成",
                                         symbol: "b.circle",
                                         statusPath: "/status",
                                         invokePath: "/invoke",
                                         streamPath: "/invoke-stream",
                                         modes: ["reply"])
    let root = URL(fileURLWithPath: "/tmp/rimebuffer-scoped-host-\(UUID().uuidString)",
                   isDirectory: true)

    func makePlugin(id: String,
                    name: String,
                    action: ActionPluginDefinition) -> InstalledActionPlugin {
        InstalledActionPlugin(
            manifest: ActionPluginManifest(schemaVersion: 1,
                                           id: id,
                                           name: name,
                                           version: "1.0.0",
                                           runtimeConfigPaths: ["runtime.json"],
                                           actions: [action]),
            directory: root.appendingPathComponent("\(id).etplugin",
                                                    isDirectory: true)
        )
    }

    func makeBinding(pluginID: String) -> ActionPluginRuntimeBinding {
        ActionPluginRuntimeBinding(config: .init(
            pluginId: pluginID,
            apiBase: "http://127.0.0.1:48777/v1/plugin",
            token: "\(pluginID)-token",
            updatedAt: 1,
            instanceId: "\(pluginID)-runtime",
            processId: 10
        ))
    }

    func makeStatus(pluginID: String,
                    action: ActionPluginDefinition) -> ActionPluginStatus {
        ActionPluginStatus(available: true,
                           contextId: "\(pluginID)-context",
                           mode: "reply",
                           actionId: action.id,
                           label: "\(pluginID) ready",
                           targetSummary: "\(pluginID) target",
                           updatedAt: 1)
    }

    let pluginA = makePlugin(id: pluginAID, name: "Scoped A", action: actionA)
    let pluginB = makePlugin(id: pluginBID, name: "Scoped B", action: actionB)
    let bindings = [
        pluginAID: makeBinding(pluginID: pluginAID),
        pluginBID: makeBinding(pluginID: pluginBID),
    ]
    let statuses = [
        pluginAID: makeStatus(pluginID: pluginAID, action: actionA),
        pluginBID: makeStatus(pluginID: pluginBID, action: actionB),
    ]
    let transport = ActionPluginScopedStreamSmokeTransport(bindings: bindings,
                                                            statuses: statuses)
    let loader = ActionPluginStreamSmokeLoader([pluginA, pluginB])
    let model = BufferModel()
    let inbound = InboundBus()
    let focus = ActionPluginStreamSmokeFocus()
    var epochs = FocusEpochState()
    let focusA = epochs.activate()
    focus.token = focusA
    let host = ActionPluginHost(
        rootURL: root,
        client: transport,
        focus: focus.access,
        bufferModel: model,
        inboundBus: inbound,
        pluginLoader: loader.load,
        pluginIsSelected: { $0 == pluginAID || $0 == pluginBID },
        runtimeBindingIsCurrent: { plugin, candidate in
            bindings[plugin.manifest.id] == candidate
        },
        runtimeAuthorityRecheckInterval: 0
    )

    func presentation(pluginID: String) -> ActionPluginPresentation? {
        host.presentations.first { $0.key.pluginId == pluginID }
    }

    func identity(_ invocation: ActionPluginScopedStreamSmokeTransport.Invocation)
        -> ActionPluginStreamIdentity {
        ActionPluginStreamIdentity(
            pluginId: invocation.pluginID,
            runtimeInstanceId: bindings[invocation.pluginID]!.config.instanceId!,
            requestId: invocation.payload.requestId,
            actionId: invocation.payload.actionId,
            contextId: invocation.payload.contextId
        )
    }

    func response(_ invocation: ActionPluginScopedStreamSmokeTransport.Invocation,
                  text: String) -> ActionPluginInvokeResponse {
        ActionPluginInvokeResponse(requestId: invocation.payload.requestId,
                                   actionId: invocation.payload.actionId,
                                   contextId: invocation.payload.contextId,
                                   blocks: [.init(text: text, title: nil)],
                                   targetSummary: "\(invocation.pluginID) target")
    }

    host.refreshStatuses(force: true)
    guard streamSmokeRunLoopUntil({
        host.presentations.count == 2
            && host.presentations.allSatisfy(\.canInvoke)
    }), let keyA = presentation(pluginID: pluginAID)?.key,
       let keyB = presentation(pluginID: pluginBID)?.key else {
        return streamSmokeFail("scoped two-plugin host never became ready")
    }

    // First prove that a real loaded B mutation leaves A's active stream and
    // provisional UUID untouched.
    host.invoke(keyA)
    guard transport.invocations.count == 1 else {
        return streamSmokeFail("scoped A foreground invocation did not start")
    }
    let aAuthorityInvocation = transport.invocations[0]
    let aAuthorityIdentity = identity(aAuthorityInvocation)
    aAuthorityInvocation.onEvent(.block(.init(identity: aAuthorityIdentity,
                                               sequence: 1,
                                               index: 0,
                                               text: "A 草稿",
                                               title: nil)))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 1 }) else {
        return streamSmokeFail("scoped A provisional block never appeared")
    }
    host.pluginConfigurationDidChange(changedPluginID: pluginBID)
    guard !aAuthorityInvocation.task.cancelled,
          model.blocks.count == 1,
          model.blocks[0].text == "A 草稿",
          presentation(pluginID: pluginAID)?.running == true else {
        return streamSmokeFail("scoped B mutation interrupted active A")
    }
    aAuthorityInvocation.completion(.success(
        response(aAuthorityInvocation, text: "A 最终")
    ))
    guard streamSmokeRunLoopUntil({
        model.blocks.count == 1
            && model.blocks[0].pluginMetadata?.incomplete == false
            && presentation(pluginID: pluginAID)?.running == false
    }), let metadataA = model.blocks[0].pluginMetadata else {
        return streamSmokeFail("scoped A authority result did not finalize")
    }

    // Mint a B delivery grant that the later named boundary must revoke.
    guard streamSmokeRunLoopUntil({
        presentation(pluginID: pluginBID)?.canInvoke == true
    }) else {
        return streamSmokeFail("scoped B did not recover after its fresh status")
    }
    host.invoke(keyB)
    guard transport.invocations.count == 2 else {
        return streamSmokeFail("scoped B authority invocation did not start")
    }
    let bAuthorityInvocation = transport.invocations[1]
    let bAuthorityIdentity = identity(bAuthorityInvocation)
    bAuthorityInvocation.onEvent(.block(.init(identity: bAuthorityIdentity,
                                               sequence: 1,
                                               index: 0,
                                               text: "B 草稿",
                                               title: nil)))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 2 }) else {
        return streamSmokeFail("scoped B provisional authority block never appeared")
    }
    bAuthorityInvocation.completion(.success(
        response(bAuthorityInvocation, text: "B 最终")
    ))
    guard streamSmokeRunLoopUntil({
        model.blocks.count == 2
            && model.blocks.last?.pluginMetadata?.incomplete == false
    }), let metadataB = model.blocks.first(where: {
        $0.pluginMetadata?.pluginId == pluginBID
    })?.pluginMetadata else {
        return streamSmokeFail("scoped B authority result did not finalize")
    }

    // Park B, then A, and finally start a second foreground B. The named B
    // boundary must cancel both B tasks while retaining A's parked task.
    host.invoke(keyB)
    guard transport.invocations.count == 3 else {
        return streamSmokeFail("scoped B background invocation did not start")
    }
    let bBackgroundInvocation = transport.invocations[2]
    let bBackgroundIdentity = identity(bBackgroundInvocation)
    bBackgroundInvocation.onEvent(.block(.init(identity: bBackgroundIdentity,
                                                sequence: 1,
                                                index: 0,
                                                text: "B 后台草稿",
                                                title: nil)))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 3 }) else {
        return streamSmokeFail("scoped B background partial never appeared")
    }
    let focusB = epochs.activate()
    focus.token = focusB
    host.focusDidChange()
    guard model.blocks.count == 2,
          !bBackgroundInvocation.task.cancelled else {
        return streamSmokeFail("scoped B did not park before invalidation")
    }

    host.refreshStatuses(force: true)
    guard streamSmokeRunLoopUntil({
        presentation(pluginID: pluginAID)?.canInvoke == true
    }) else {
        return streamSmokeFail("scoped A did not refresh after B parked")
    }
    host.invoke(keyA)
    guard transport.invocations.count == 4 else {
        return streamSmokeFail("scoped A background invocation did not start")
    }
    let aBackgroundInvocation = transport.invocations[3]
    let aBackgroundIdentity = identity(aBackgroundInvocation)
    aBackgroundInvocation.onEvent(.block(.init(identity: aBackgroundIdentity,
                                                sequence: 1,
                                                index: 0,
                                                text: "A 后台草稿",
                                                title: nil)))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 3 }) else {
        return streamSmokeFail("scoped A background partial never appeared")
    }
    let focusC = epochs.activate()
    focus.token = focusC
    host.focusDidChange()
    guard model.blocks.count == 2,
          !aBackgroundInvocation.task.cancelled else {
        return streamSmokeFail("scoped A did not park before B invalidation")
    }

    host.refreshStatuses(force: true)
    guard streamSmokeRunLoopUntil({
        presentation(pluginID: pluginBID)?.canInvoke == true
    }) else {
        return streamSmokeFail("scoped B did not refresh for active revocation")
    }
    host.invoke(keyB)
    guard transport.invocations.count == 5 else {
        return streamSmokeFail("scoped B active revocation invocation did not start")
    }
    let bActiveInvocation = transport.invocations[4]
    let bActiveIdentity = identity(bActiveInvocation)
    bActiveInvocation.onEvent(.block(.init(identity: bActiveIdentity,
                                            sequence: 1,
                                            index: 0,
                                            text: "B 活动草稿",
                                            title: nil)))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 3 }) else {
        return streamSmokeFail("scoped B active partial never appeared")
    }

    // Keep one old B status callback in flight. The configuration callback
    // starts a fresh B request, allowing the fixture to distinguish them.
    transport.heldStatusPluginIDs.insert(pluginBID)
    host.refreshStatuses(force: true, onlyPluginID: pluginBID)
    guard transport.pendingStatusCount == 1,
          presentation(pluginID: pluginAID)?.available == true else {
        return streamSmokeFail("scoped old B status fixture was not held")
    }
    host.pluginConfigurationDidChange(changedPluginID: pluginBID)
    guard transport.pendingStatusCount == 2,
          !aBackgroundInvocation.task.cancelled,
          bBackgroundInvocation.task.cancelled,
          bActiveInvocation.task.cancelled,
          model.blocks.count == 2,
          model.loadingMessage == nil,
          presentation(pluginID: pluginAID)?.available == true,
          presentation(pluginID: pluginAID)?.canInvoke == true,
          presentation(pluginID: pluginBID)?.available == false,
          presentation(pluginID: pluginBID)?.running == false else {
        return streamSmokeFail("scoped B boundary did not preserve A and revoke B tasks")
    }

    guard transport.completeNextHeldStatus(pluginID: pluginBID) else {
        return streamSmokeFail("scoped old B status callback was missing")
    }
    streamSmokeDrainMainQueue()
    guard presentation(pluginID: pluginBID)?.available == false,
          transport.pendingStatusCount == 1 else {
        return streamSmokeFail("scoped old B status callback crossed the boundary")
    }
    guard transport.completeNextHeldStatus(pluginID: pluginBID),
          streamSmokeRunLoopUntil({
              presentation(pluginID: pluginBID)?.canInvoke == true
          }) else {
        return streamSmokeFail("scoped fresh B status did not restore B")
    }

    // Neither the parked nor foreground B task may revive rail/inbox state.
    let retainedBlockIDs = model.blocks.map(\.id)
    bBackgroundInvocation.onEvent(.block(.init(identity: bBackgroundIdentity,
                                                sequence: 2,
                                                index: 0,
                                                text: "B 后台迟到",
                                                title: nil)))
    bActiveInvocation.onEvent(.block(.init(identity: bActiveIdentity,
                                            sequence: 2,
                                            index: 0,
                                            text: "B 活动迟到",
                                            title: nil)))
    bBackgroundInvocation.completion(.success(
        response(bBackgroundInvocation, text: "B 后台迟到最终")
    ))
    bActiveInvocation.completion(.success(
        response(bActiveInvocation, text: "B 活动迟到最终")
    ))
    streamSmokeDrainMainQueue()
    guard model.blocks.map(\.id) == retainedBlockIDs,
          inbound.pendingCount == 0,
          !model.blocks.contains(where: { $0.text.contains("迟到") }) else {
        return streamSmokeFail("scoped late B stream/terminal callback revived state")
    }

    // Completed A authority survives; completed B authority is tombstoned.
    focus.token = focusA
    var aDelivery: ActionPluginDeliveryDecision?
    var bDelivery: ActionPluginDeliveryDecision?
    host.validateForDelivery(metadata: metadataA, expectedFocusToken: focusA) {
        aDelivery = $0
    }
    host.validateForDelivery(metadata: metadataB, expectedFocusToken: focusA) {
        bDelivery = $0
    }
    guard streamSmokeRunLoopUntil({ aDelivery != nil && bDelivery != nil }),
          aDelivery == .allowed,
          bDelivery == .rejected(.stale) else {
        return streamSmokeFail("scoped delivery grants did not preserve A/revoke B")
    }

    // A's parked stream remains live and may still settle into the review
    // inbox; its late partial stays hidden, as required for any background task.
    aBackgroundInvocation.onEvent(.block(.init(identity: aBackgroundIdentity,
                                                sequence: 2,
                                                index: 0,
                                                text: "A 后台迟到草稿",
                                                title: nil)))
    aBackgroundInvocation.completion(.success(
        response(aBackgroundInvocation, text: "A 后台保留结果")
    ))
    guard streamSmokeRunLoopUntil({ inbound.pendingCount == 1 }),
          !aBackgroundInvocation.task.cancelled,
          inbound.pending[0].pluginMetadata?.pluginId == pluginAID,
          inbound.pending[0].text == "A 后台保留结果",
          model.blocks.map(\.id) == retainedBlockIDs else {
        return streamSmokeFail("scoped B boundary discarded retained A background work")
    }
    return true
}

private func runActionPluginStreamHostSmokeTest() -> Bool {
    guard ActionPluginHost.defaultInvocationTimeout == 270 else {
        return streamSmokeFail("host default invocation timeout drifted from 270 seconds")
    }
    let action = ActionPluginDefinition(id: "marine.generate",
                                        title: "生成回复",
                                        symbol: "sparkles",
                                        statusPath: "/status",
                                        invokePath: "/invoke",
                                        streamPath: "/invoke-stream",
                                        modes: ["reply"])
    let root = URL(fileURLWithPath: "/tmp/rimebuffer-stream-host-\(UUID().uuidString)",
                   isDirectory: true)
    let plugin = InstalledActionPlugin(
        manifest: ActionPluginManifest(schemaVersion: 1,
                                       id: "marine",
                                       name: "Marine",
                                       version: "1.0.0",
                                       runtimeConfigPaths: ["runtime.json"],
                                       actions: [action]),
        directory: root.appendingPathComponent("marine.etplugin", isDirectory: true)
    )
    let binding = ActionPluginRuntimeBinding(config: .init(
        pluginId: "marine",
        apiBase: "http://127.0.0.1:48777/v1/plugin",
        token: "host-smoke-token",
        updatedAt: 1,
        instanceId: "runtime-1",
        processId: 10
    ))
    let status = ActionPluginStatus(available: true,
                                    contextId: "comment-1",
                                    mode: "reply",
                                    actionId: action.id,
                                    label: "生成回复",
                                    targetSummary: "目标评论",
                                    updatedAt: 1)
    let transport = ActionPluginStreamSmokeTransport(binding: binding, status: status)
    let model = BufferModel()
    let inbound = InboundBus()
    let focus = ActionPluginStreamSmokeFocus()
    var epochs = FocusEpochState()
    let focusA = epochs.activate()
    focus.token = focusA
    let loader = ActionPluginStreamSmokeLoader([plugin])
    let runtimeAuthority = ActionPluginStreamSmokeRuntimeAuthority()
    var mailboxDrainCount = 0
    let host = ActionPluginHost(rootURL: root,
                                client: transport,
                                focus: focus.access,
                                bufferModel: model,
                                inboundBus: inbound,
                                pluginLoader: loader.load,
                                runtimeBindingIsCurrent: { _, _ in
                                    runtimeAuthority.current
                                },
                                runtimeAuthorityRecheckInterval: 0,
                                streamDrainDidRun: { mailboxDrainCount += 1 })
    host.refreshStatuses(force: true)
    guard streamSmokeRunLoopUntil({ host.presentations.first?.canInvoke == true }),
          let key = host.presentations.first?.key else {
        return streamSmokeFail("host never became invokable")
    }

    host.invoke(key)
    guard transport.invocations.count == 1,
          model.loadingMessage != nil,
          model.transientLoadingActive,
          host.presentations.first?.waitingForFirstContent == true,
          inbound.pendingCount == 0 else {
        return streamSmokeFail("host did not expose pre-content loading state")
    }
    let first = transport.invocations[0]
    let identity = ActionPluginStreamIdentity(pluginId: "marine",
                                              runtimeInstanceId: "runtime-1",
                                              requestId: first.payload.requestId,
                                              actionId: action.id,
                                              contextId: "comment-1")
    first.onEvent(.heartbeat(identity: identity, sequence: 1))
    guard streamSmokeRunLoopUntil({ model.loadingMessage != nil }),
          model.blocks.isEmpty else {
        return streamSmokeFail("heartbeat altered the loading rail")
    }
    first.onEvent(.block(.init(identity: identity,
                               sequence: 2,
                               index: 0,
                               text: "草稿",
                               title: "回复")))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 1 }),
          let provisionalID = model.blocks.first?.id,
          model.blocks.first?.pluginMetadata?.incomplete == true,
          model.loadingMessage == nil,
          !model.transientLoadingActive,
          model.pendingDeliveryBlocks.isEmpty,
          inbound.pendingCount == 0,
          host.presentations.first?.waitingForFirstContent == false else {
        return streamSmokeFail("first streamed block was not staged as incomplete")
    }

    let coordinator = BufferDeliveryCoordinator(
        model: model,
        dependencies: .init(
            resolveTarget: { expected in
                guard expected == nil || expected == focusA else { return nil }
                return .init(token: focusA,
                             compositionActive: false,
                             resolveComposition: {},
                             deliver: { _ in true })
            },
            secureInputEnabled: { false },
            validatePlugin: { _, _, completion in completion(.allowed) },
            refreshUI: {}
        )
    )
    guard coordinator.availability() == .blocked(.pluginResultIncomplete),
          coordinator.sendAll().blockedReason == .pluginResultIncomplete,
          model.blocks.count == 1 else {
        return streamSmokeFail("delivery coordinator exposed an incomplete result")
    }

    let beforeBurstChange = model.changeCount
    let beforeBurstDrains = mailboxDrainCount
    for sequence in 3...130 {
        first.onEvent(.block(.init(
            identity: identity,
            sequence: sequence,
            index: 0,
            text: sequence == 130 ? "草稿完成" : "草稿快照 \(sequence)",
            title: "回复"
        )))
    }
    guard streamSmokeRunLoopUntil(timeout: 1, {
        model.blocks.first?.text == "草稿完成"
    }), model.blocks.first?.id == provisionalID,
       model.changeCount <= beforeBurstChange + 2,
       mailboxDrainCount == beforeBurstDrains + 1 else {
        return streamSmokeFail(
            "burst snapshots were not coalesced onto one logical block/main drain"
        )
    }

    let coarseStreamText = "This streamed answer contains one useful phrase and then another useful phrase."
    first.onEvent(.block(.init(
        identity: identity,
        sequence: 131,
        index: 0,
        text: coarseStreamText,
        title: "回复"
    )))
    guard streamSmokeRunLoopUntil(timeout: 1, {
        model.blocks.count > 1
            && model.blocks.map(\.text).joined() == coarseStreamText
    }), model.blocks.first?.id == provisionalID,
       model.blocks.allSatisfy({ $0.pluginMetadata?.incomplete == true }),
       model.pendingDeliveryBlocks.isEmpty else {
        return streamSmokeFail("coarse SSE block was not force-segmented with stable prefix ID")
    }

    let beforeFinalChange = model.changeCount
    let response = ActionPluginInvokeResponse(
        requestId: first.payload.requestId,
        actionId: action.id,
        contextId: "comment-1",
        blocks: [ActionPluginResultBlock(text: "最终回复", title: "回复")],
        targetSummary: "最终目标"
    )
    first.completion(.success(response))
    guard streamSmokeRunLoopUntil({
        model.blocks.first?.pluginMetadata?.incomplete == false
            && host.presentations.first?.running == false
    }), model.changeCount == beforeFinalChange + 1,
       model.blocks.first?.id == provisionalID,
       model.blocks.first?.text == "最终回复",
       model.blocks.first?.pluginMetadata?.targetSummary == "最终目标",
       model.pendingDeliveryCount == 1,
       inbound.pendingCount == 0 else {
        return streamSmokeFail("terminal response was not promoted once without auto-delivery")
    }

    // A -> B -> A-looking field is really a new focus epoch. Provisional text
    // must disappear immediately, while an otherwise valid complete response
    // is retained in the review inbox instead of being silently lost.
    host.invoke(key)
    guard transport.invocations.count == 2 else {
        return streamSmokeFail("host did not start focus-revocation invocation")
    }
    let focusInvocation = transport.invocations[1]
    let focusIdentity = ActionPluginStreamIdentity(
        pluginId: "marine",
        runtimeInstanceId: "runtime-1",
        requestId: focusInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1"
    )
    focusInvocation.onEvent(.block(.init(identity: focusIdentity,
                                         sequence: 1,
                                         index: 0,
                                         text: "即将撤销",
                                         title: nil)))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 2 }) else {
        return streamSmokeFail("focus-revocation partial never appeared")
    }
    let focusB = epochs.activate()
    focus.token = focusB
    host.focusDidChange()
    let focusC = epochs.activate()
    focus.token = focusC

    // Parking A must free the foreground slot immediately. Start B before A's
    // terminal callback so the test catches ownership bugs where A clears B's
    // loading state, running state, or fresh status cache.
    host.refreshStatuses(force: true)
    guard streamSmokeRunLoopUntil({ host.presentations.first?.canInvoke == true }) else {
        return streamSmokeFail("host did not refresh for the new focus epoch")
    }
    host.invoke(key)
    guard transport.invocations.count == 3 else {
        return streamSmokeFail("parked stream still blocked a new foreground invocation")
    }
    let runtimeInvocation = transport.invocations[2]
    let runtimeIdentity = ActionPluginStreamIdentity(
        pluginId: "marine",
        runtimeInstanceId: "runtime-1",
        requestId: runtimeInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1"
    )

    focusInvocation.onEvent(.block(.init(identity: focusIdentity,
                                         sequence: 2,
                                         index: 0,
                                         text: "迟到更新",
                                         title: nil)))
    focusInvocation.completion(.success(.init(
        requestId: focusInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1",
        blocks: [.init(text: "迟到最终结果", title: nil)],
        targetSummary: nil
    )))
    streamSmokeDrainMainQueue()
    guard streamSmokeRunLoopUntil({ inbound.pendingCount == 1 }),
          !focusInvocation.task.cancelled,
          model.blocks.count == 1,
          model.blocks.first?.id == provisionalID,
          !model.blocks.contains(where: { $0.text.contains("迟到") }),
          inbound.pending[0].text == "迟到最终结果",
          inbound.pending[0].pluginMetadata?.stale == true,
          host.presentations.first?.running == true,
          model.loadingMessage != nil,
          model.transientLoadingActive else {
        return streamSmokeFail(
            "background terminal did not retain A while preserving foreground B"
        )
    }

    // Runtime rotation revokes the captured binding before any later frame is
    // allowed to update its provisional UUID.
    runtimeInvocation.onEvent(.block(.init(identity: runtimeIdentity,
                                           sequence: 1,
                                           index: 0,
                                           text: "旧实例草稿",
                                           title: nil)))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 2 }) else {
        return streamSmokeFail("runtime-revocation partial never appeared")
    }
    host.pluginConfigurationDidChange(changedPluginID: "inactive-plugin")
    guard !runtimeInvocation.task.cancelled,
          model.blocks.count == 2,
          model.blocks.contains(where: { $0.text == "旧实例草稿" }),
          host.presentations.first?.running == true else {
        return streamSmokeFail(
            "inactive plugin mutation cancelled selected stream or removed its partial"
        )
    }
    runtimeAuthority.current = false
    runtimeInvocation.onEvent(.heartbeat(identity: runtimeIdentity, sequence: 2))
    guard streamSmokeRunLoopUntil({ runtimeInvocation.task.cancelled }),
          model.blocks.count == 1,
          model.blocks.first?.id == provisionalID else {
        return streamSmokeFail("runtime rotation did not remove only its partial blocks")
    }
    runtimeAuthority.current = true
    runtimeInvocation.completion(.success(.init(
        requestId: runtimeInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1",
        blocks: [.init(text: "旧实例迟到最终结果", title: nil)],
        targetSummary: nil
    )))
    streamSmokeDrainMainQueue()
    guard !model.blocks.contains(where: { $0.text.contains("旧实例迟到") }) else {
        return streamSmokeFail("runtime-revoked terminal callback revived blocks")
    }

    // Disable/uninstall/upgrade notifications are generation boundaries. They
    // clear the loader and loading rail and tombstone all callbacks.
    host.invoke(key)
    guard transport.invocations.count == 4 else {
        return streamSmokeFail("host did not start management-revocation invocation")
    }
    let managementInvocation = transport.invocations[3]
    let managementIdentity = ActionPluginStreamIdentity(
        pluginId: "marine",
        runtimeInstanceId: "runtime-1",
        requestId: managementInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1"
    )
    managementInvocation.onEvent(.block(.init(identity: managementIdentity,
                                              sequence: 1,
                                              index: 0,
                                              text: "卸载前草稿",
                                              title: nil)))
    guard streamSmokeRunLoopUntil({ model.blocks.count == 2 }) else {
        return streamSmokeFail("management-revocation partial never appeared")
    }
    loader.plugins = []
    host.pluginConfigurationDidChange()
    managementInvocation.onEvent(.block(.init(identity: managementIdentity,
                                              sequence: 2,
                                              index: 0,
                                              text: "卸载后迟到更新",
                                              title: nil)))
    managementInvocation.completion(.success(.init(
        requestId: managementInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1",
        blocks: [.init(text: "卸载后迟到最终结果", title: nil)],
        targetSummary: nil
    )))
    streamSmokeDrainMainQueue()
    guard streamSmokeRunLoopUntil({ managementInvocation.task.cancelled }),
          model.loadingMessage == nil,
          model.blocks.count == 1,
          model.blocks.first?.id == provisionalID,
          !model.blocks.contains(where: { $0.text.contains("卸载后") }) else {
        return streamSmokeFail("management generation accepted a late event")
    }

    // The host timeout uses the same scoped cancellation path: only this
    // request's provisional UUID disappears and its task is cancelled.
    let timeoutTransport = ActionPluginStreamSmokeTransport(binding: binding, status: status)
    let timeoutModel = BufferModel()
    let timeoutFocus = ActionPluginStreamSmokeFocus()
    timeoutFocus.token = focusC
    let timeoutLoader = ActionPluginStreamSmokeLoader([plugin])
    let timeoutInbound = InboundBus()
    let timeoutHost = ActionPluginHost(
        rootURL: root.appendingPathComponent("timeout", isDirectory: true),
        client: timeoutTransport,
        focus: timeoutFocus.access,
        bufferModel: timeoutModel,
        inboundBus: timeoutInbound,
        pluginLoader: timeoutLoader.load,
        runtimeBindingIsCurrent: { _, _ in true },
        invocationTimeout: 0.15
    )
    timeoutHost.refreshStatuses(force: true)
    guard streamSmokeRunLoopUntil({ timeoutHost.presentations.first?.canInvoke == true }),
          let timeoutKey = timeoutHost.presentations.first?.key else {
        return streamSmokeFail("timeout host never became invokable")
    }
    timeoutHost.invoke(timeoutKey)
    guard timeoutTransport.invocations.count == 1 else {
        return streamSmokeFail("timeout invocation did not start")
    }
    let timeoutInvocation = timeoutTransport.invocations[0]
    let timeoutIdentity = ActionPluginStreamIdentity(
        pluginId: "marine",
        runtimeInstanceId: "runtime-1",
        requestId: timeoutInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1"
    )
    timeoutInvocation.onEvent(.block(.init(identity: timeoutIdentity,
                                           sequence: 1,
                                           index: 0,
                                           text: "超时前草稿",
                                           title: nil)))
    guard streamSmokeRunLoopUntil({ timeoutModel.blocks.count == 1 }),
          streamSmokeRunLoopUntil(timeout: 1, { timeoutInvocation.task.cancelled }),
          timeoutModel.blocks.isEmpty,
          timeoutModel.loadingMessage == nil,
          timeoutHost.workbenchFailureMessage == "生成超时",
          !timeoutModel.transientLoadingActive else {
        return streamSmokeFail("timeout did not cancel and remove its provisional block")
    }

    timeoutHost.invoke(timeoutKey)
    guard timeoutTransport.invocations.count == 2 else {
        return streamSmokeFail("deletion-cancellation invocation did not start")
    }
    let deletionInvocation = timeoutTransport.invocations[1]
    let deletionIdentity = ActionPluginStreamIdentity(
        pluginId: "marine",
        runtimeInstanceId: "runtime-1",
        requestId: deletionInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1"
    )
    deletionInvocation.onEvent(.block(.init(identity: deletionIdentity,
                                            sequence: 1,
                                            index: 0,
                                            text: "待删除草稿",
                                            title: nil)))
    guard streamSmokeRunLoopUntil({ timeoutModel.blocks.count == 1 }),
          timeoutModel.removeLastBlock() else {
        return streamSmokeFail("deletion-cancellation partial never appeared")
    }
    deletionInvocation.onEvent(.block(.init(identity: deletionIdentity,
                                            sequence: 2,
                                            index: 0,
                                            text: "删除后迟到更新",
                                            title: nil)))
    deletionInvocation.completion(.success(.init(
        requestId: deletionInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1",
        blocks: [.init(text: "删除后迟到最终结果", title: nil)],
        targetSummary: nil
    )))
    streamSmokeDrainMainQueue()
    guard deletionInvocation.task.cancelled,
          timeoutModel.blocks.isEmpty,
          timeoutModel.loadingMessage == nil,
          timeoutHost.workbenchFailureMessage == "生成已取消" else {
        return streamSmokeFail("user deletion did not tombstone late stream callbacks")
    }

    let blockAtLimit = streamSmokeUTF8Text(
        byteCount: ActionPluginStreamParser.maximumBlockBytes
    )
    let titleAtLimit = streamSmokeUTF8Text(
        byteCount: ActionPluginStreamParser.maximumTitleBytes
    )
    let summaryAtLimit = streamSmokeUTF8Text(
        byteCount: ActionPluginStreamParser.maximumSummaryBytes
    )
    let invalidBoundaryFixtures: [(String, String, String?, String?)] = [
        ("block text", blockAtLimit + "a", nil, nil),
        ("title", "正文", titleAtLimit + "a", nil),
        ("summary", "正文", nil, summaryAtLimit + "a"),
    ]
    for (offset, fixture) in invalidBoundaryFixtures.enumerated() {
        timeoutHost.invoke(timeoutKey)
        guard timeoutTransport.invocations.count == 3 + offset else {
            return streamSmokeFail("host \(fixture.0) boundary invocation did not start")
        }
        let invocation = timeoutTransport.invocations[2 + offset]
        invocation.completion(.success(.init(
            requestId: invocation.payload.requestId,
            actionId: action.id,
            contextId: "comment-1",
            blocks: [.init(text: fixture.1, title: fixture.2)],
            targetSummary: fixture.3
        )))
        guard streamSmokeRunLoopUntil(timeout: 1, {
            invocation.task.cancelled
                && timeoutModel.loadingMessage == nil
                && timeoutHost.workbenchFailureMessage == "生成失败"
        }), timeoutModel.blocks.isEmpty else {
            return streamSmokeFail(
                "host accepted an over-limit Chinese \(fixture.0) by Character count"
            )
        }
    }

    timeoutHost.invoke(timeoutKey)
    guard timeoutTransport.invocations.count == 6 else {
        return streamSmokeFail("host exact UTF-8 boundary invocation did not start")
    }
    let exactBoundaryInvocation = timeoutTransport.invocations[5]
    exactBoundaryInvocation.completion(.success(.init(
        requestId: exactBoundaryInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1",
        blocks: [.init(text: blockAtLimit, title: titleAtLimit)],
        targetSummary: summaryAtLimit
    )))
    guard streamSmokeRunLoopUntil(timeout: 1, {
        timeoutModel.blocks.first?.pluginMetadata?.incomplete == false
    }), timeoutModel.blocks.count > 1,
       timeoutModel.blocks.map(\.text).joined().utf8.count
        == ActionPluginStreamParser.maximumBlockBytes,
       timeoutModel.blocks[0].pluginMetadata?.title?.utf8.count
        == ActionPluginStreamParser.maximumTitleBytes,
       timeoutModel.blocks[0].pluginMetadata?.targetSummary?.utf8.count
        == ActionPluginStreamParser.maximumSummaryBytes else {
        return streamSmokeFail("host rejected exact Chinese UTF-8 byte boundaries")
    }

    // A provider can fail after sending provisional text. Its raw diagnostic
    // must never become rail text or a sendable block; only the scoped partial
    // is removed, while pre-existing user/result content stays intact.
    let preservedBlockIDs = Set(timeoutModel.blocks.map(\.id))
    let preservedBlockCount = timeoutModel.blocks.count
    timeoutHost.invoke(timeoutKey)
    guard timeoutTransport.invocations.count == 7 else {
        return streamSmokeFail("provider-failure invocation did not start")
    }
    let providerFailureInvocation = timeoutTransport.invocations[6]
    let providerFailureIdentity = ActionPluginStreamIdentity(
        pluginId: "marine",
        runtimeInstanceId: "runtime-1",
        requestId: providerFailureInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1"
    )
    providerFailureInvocation.onEvent(.block(.init(
        identity: providerFailureIdentity,
        sequence: 1,
        index: 0,
        text: "失败前的临时候选",
        title: nil
    )))
    guard streamSmokeRunLoopUntil({
        timeoutModel.blocks.count == preservedBlockCount + 1
    }) else {
        return streamSmokeFail("provider-failure provisional block never appeared")
    }
    let rawProviderError = "generation provider failed before producing a valid result"
    providerFailureInvocation.completion(.failure(
        ActionPluginStreamError.remote(rawProviderError)
    ))
    guard streamSmokeRunLoopUntil({ providerFailureInvocation.task.cancelled }),
          timeoutModel.blocks.count == preservedBlockCount,
          Set(timeoutModel.blocks.map(\.id)) == preservedBlockIDs,
          timeoutModel.pendingDeliveryCount == preservedBlockCount,
          timeoutModel.loadingMessage == nil,
          !timeoutModel.transientLoadingActive,
          !timeoutModel.blocks.contains(where: {
              $0.text.contains(rawProviderError) || $0.text.contains("失败前的临时候选")
          }),
          timeoutHost.workbenchFailureMessage == "生成失败",
          BufferWorkbenchStatusText.text(
              for: .ready,
              secureInput: false,
              pluginFailure: timeoutHost.workbenchFailureMessage
          ) == "生成失败" else {
        return streamSmokeFail("provider error leaked into the buffer rail")
    }
    timeoutHost.cancelActiveInvocationForWorkbench()
    guard timeoutHost.workbenchFailureMessage == nil,
          timeoutModel.blocks.count == preservedBlockCount,
          Set(timeoutModel.blocks.map(\.id)) == preservedBlockIDs else {
        return streamSmokeFail("closing the workbench did not clear only the failure status")
    }

    // Session protection must revoke parked continuations too. Otherwise a
    // stream moved to the background just before lock/secure-input could write
    // into the inbox after the protected transition.
    timeoutHost.invoke(timeoutKey)
    guard timeoutTransport.invocations.count == 8 else {
        return streamSmokeFail("protected-background invocation did not start")
    }
    let protectedInvocation = timeoutTransport.invocations[7]
    var protectedEpochs = FocusEpochState()
    timeoutFocus.token = protectedEpochs.activate()
    timeoutHost.focusDidChange()
    guard !protectedInvocation.task.cancelled,
          timeoutHost.presentations.first?.running == false else {
        return streamSmokeFail("target change did not park protected-background invocation")
    }
    timeoutHost.cancelActiveInvocationForWorkbench()
    protectedInvocation.completion(.success(.init(
        requestId: protectedInvocation.payload.requestId,
        actionId: action.id,
        contextId: "comment-1",
        blocks: [.init(text: "锁屏后不得保留", title: nil)],
        targetSummary: nil
    )))
    streamSmokeDrainMainQueue()
    guard protectedInvocation.task.cancelled,
          timeoutInbound.pendingCount == 0,
          !timeoutModel.blocks.contains(where: { $0.text == "锁屏后不得保留" }) else {
        return streamSmokeFail("workbench protection did not tombstone a parked result")
    }
    return true
}

func runActionPluginStreamSmokeTest() -> Bool {
    guard runActionPluginStreamParserSmokeTest(),
          runActionPluginStreamModelSmokeTest(),
          runActionPluginStreamHTTPFallbackSmokeTest(),
          runActionPluginScopedInvalidationSmokeTest(),
          runActionPluginStreamHostSmokeTest() else { return false }
    print("action plugin stream smoke OK")
    return true
}
