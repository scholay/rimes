import XCTest
@testable import RimesCore

final class CoreTests: XCTestCase {
    func testEveryBundledMappingIsReachableAndResolvesIdentically() throws {
        let p = try ChordProfile.builtIn.validated()
        XCTAssertEqual(p.mappings.count, 426)
        for entry in p.mappings {
            let keys = Set(entry.keys)
            let expected = try XCTUnwrap(p.resolve(keys), entry.keys)
            XCTAssertEqual(expected.preview,entry.output)
            let separator = p.boundaryPolicy == .legacyBatches || entry.kind == .syllable ? "'" : ""
            XCTAssertEqual(expected.input, entry.output + separator, entry.keys)
            for reverse in [false,true] {
                var g = ChordGesture(); var strokes: [(Int,[Character])] = []
                for (i,hand) in Hand.allCases.enumerated() {
                    let chars = Array(keys.filter { p.hand(for:$0) == hand }).sorted()
                    if !chars.isEmpty { strokes.append((i,chars)); g.begin(id:i,key:chars[0],profile:p); g.move(id:i,key:chars.last,profile:p) }
                }
                XCTAssertEqual(g.keys,keys)
                let ordered = reverse ? strokes.reversed().map { $0 } : strokes
                var outcomes = [ChordResolution]()
                for (id,chars) in ordered { if let result = g.end(id:id,key:chars.last,profile:p) { outcomes.append(result) } }
                XCTAssertEqual(outcomes,[expected],entry.keys)
                XCTAssertNil(g.end(id:0,key:"a",profile:p))
            }
        }
        var z = p.copy(); z.outputEncoding = .ziranma
        _ = try z.validated()
        for m in z.mappings { XCTAssertEqual(z.resolve(Set(m.keys))?.input,z.encoded(m)) }
    }
    func testStartAndEndOnly() {
        let p = ChordProfile.builtIn; var g = ChordGesture()
        g.begin(id:1,key:"a",profile:p); g.move(id:1,key:"s",profile:p); g.move(id:1,key:"d",profile:p)
        XCTAssertEqual(g.keys,Set("ad"))
        g.move(id:1,key:"a",profile:p); XCTAssertEqual(g.keys,Set("a"))
        XCTAssertEqual(g.end(id:1,key:"a",profile:p)?.input,"a")
    }
    func testWholeMappingWinsBeforeLegalLeftRightComposition() throws {
        var p = ChordProfile.builtIn.copy(); p.boundaryPolicy = .explicitSyllables
        p.mappings = [.init(keys:"sd",output:"sh",kind:.fragment), .init(keys:"jk",output:"ang",kind:.fragment), .init(keys:"sdjk",output:"chang",kind:.syllable)]
        _ = try p.validated()
        XCTAssertEqual(p.resolve(Set("sdjk"))?.input,"chang'")
        p.mappings.removeLast()
        XCTAssertEqual(p.resolve(Set("sdjk"))?.input,"shang'")
        XCTAssertEqual(p.resolve(Set("sd"))?.input,"sh")
        XCTAssertEqual(p.resolve(Set("bi"))?.input,"bi'")
        XCTAssertNil(p.resolve(Set("qjk"))) // q + ang is not a legal syllable.
        p.outputEncoding = .ziranma
        XCTAssertEqual(p.resolve(Set("sdjk"))?.input,"uh")
        XCTAssertEqual(p.resolve(Set("sd"))?.input,"u")
        XCTAssertEqual(p.resolve(Set("j"))?.input,"j")
    }
    func testCrossingCanRecoverButInvalidReleaseCancelsWholeGroup() {
        let p = ChordProfile.builtIn; var g = ChordGesture()
        g.begin(id:1,key:"a",profile:p); g.begin(id:2,key:"j",profile:p)
        g.move(id:1,key:"k",profile:p); XCTAssertNil(g.keys)
        g.move(id:1,key:"s",profile:p); XCTAssertEqual(g.keys,Set("asj"))
        XCTAssertNil(g.end(id:1,key:nil,profile:p)); XCTAssertNil(g.end(id:2,key:"j",profile:p))
    }
    func testExtraFingerQuarantinesUntilAllLift() {
        let p = ChordProfile.builtIn; var g = ChordGesture()
        g.begin(id:1,key:"a",profile:p); g.begin(id:2,key:"j",profile:p); g.begin(id:3,key:"s",profile:p)
        XCTAssertTrue(g.cancelled)
        for id in [1,2,3] { XCTAssertNil(g.end(id:id,key:"a",profile:p)) }
        g.begin(id:4,key:"a",profile:p); XCTAssertEqual(g.end(id:4,key:"a",profile:p)?.input,"a")
    }
    func testReleasedHandCannotRestartSameGroup() {
        let p = ChordProfile.builtIn; var g = ChordGesture()
        g.begin(id:1,key:"a",profile:p); g.begin(id:2,key:"j",profile:p)
        XCTAssertNil(g.end(id:1,key:"a",profile:p)); g.begin(id:3,key:"s",profile:p)
        XCTAssertNil(g.end(id:2,key:"j",profile:p)); XCTAssertNil(g.end(id:3,key:"s",profile:p))
    }
    func testCancelledGestureNeverCommits() {
        let p = ChordProfile.builtIn; var g = ChordGesture()
        g.begin(id:1,key:"a",profile:p); g.cancel(); XCTAssertNil(g.end(id:1,key:"a",profile:p))
    }
    func testProfileRejectsNativeAndUnreachableAndDuplicate() throws {
        var p = ChordProfile.builtIn.copy(); p.nativeSchemeID = "yoyo"; XCTAssertThrowsError(try p.validated())
        p.nativeSchemeID = nil; p.mappings.append(.init(keys:"asd",output:"hao",kind:.syllable)); XCTAssertThrowsError(try p.validated())
        p.mappings.removeLast(); p.mappings.append(p.mappings[0]); XCTAssertThrowsError(try p.validated())
        let imported = try ChordProfile.imported(JSONEncoder().encode(ChordProfile.builtIn)); XCTAssertNotEqual(imported.id,ChordProfile.builtIn.id)
    }
    func testBufferEditingInvalidatesLateResponseAndNeverLosesSource() {
        var b = BufferSession(); b.edit("hello")
        let id = b.begin(); b.receive("Bonjour",id:id); XCTAssertTrue(b.generating)
        b.insert(" world"); b.finish("Bonjour",id:id)
        XCTAssertEqual(b.source,"hello world"); XCTAssertNil(b.result); XCTAssertFalse(b.generating)
        b.moveCursor(-6); b.insert("!"); XCTAssertEqual(b.source,"hello! world")
        b.backspace(); XCTAssertEqual(b.source,"hello world")
    }
    func testOrderedDeliveryPreservesAllCharactersAndPartialRemainder() {
        let text = "你好。 下一句！\nThird 👩🏽‍💻"
        XCTAssertEqual(TextBlocks.split(text).joined(),text)
        var b = BufferSession(); b.edit(text); b.consumed(all:false)
        XCTAssertEqual(b.source," 下一句！\nThird 👩🏽‍💻")
        let id = b.begin(); b.finish("One! Two?",id:id); b.consumed(all:false)
        XCTAssertEqual(b.pending,[" Two?"])
        b.cancel() // A same-session target change cancels requests, not pending text.
        XCTAssertEqual(b.pending,[" Two?"]); b.consumed(all:true); XCTAssertEqual(b.source,"")
    }
    func testEndpointConsentAndBody() throws {
        let p = ProviderConfiguration(name:"Test",baseURL:"https://example.test/v1",model:"test")
        XCTAssertThrowsError(try AIRequest.make(provider:p,key:"secret",source:"only me",action:.polish,language:"English",consent:""))
        let req = try AIRequest.make(provider:p,key:"secret",source:"only me",action:.polish,language:"English",consent:p.consentIdentity)
        XCTAssertEqual(req.url?.path,"/v1/chat/completions")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(req.httpBody)) as? [String:Any])
        XCTAssertEqual((json["messages"] as? [[String:String]])?.last?["content"],"only me")
        XCTAssertFalse(String(data:try JSONEncoder().encode(p),encoding:.utf8)!.contains("secret"))
        for url in ["http://a.test", "https://user:password@a.test", "https://a.test?q=key", "https://a.test/#key"] {
            XCTAssertThrowsError(try ProviderConfiguration(baseURL:url).endpoint("models"))
        }
    }
    func testSSEEveryByteBoundaryAndTruncation() throws {
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"你好👩🏽‍💻\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        var d = SSETextDecoder()
        for byte in stream.utf8 { try d.append(Data([byte])) }
        XCTAssertEqual(try d.complete(),"你好👩🏽‍💻")
        var partial = SSETextDecoder(); try partial.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8)); XCTAssertThrowsError(try partial.complete())
        var length = SSETextDecoder(); XCTAssertThrowsError(try length.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n".utf8)))
    }
    func testRedirectNeverCarriesCredentials() {
        let delegate = NoRedirectSessionDelegate()
        let session = URLSession(configuration:.ephemeral), request = URLRequest(url:URL(string:"https://elsewhere.test")!)
        let task = session.dataTask(with:request)
        let response = HTTPURLResponse(url:URL(string:"https://original.test")!,statusCode:302,httpVersion:nil,headerFields:nil)!
        var called = false
        delegate.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:request) { redirect in called = true; XCTAssertNil(redirect) }
        XCTAssertTrue(called); session.invalidateAndCancel()
    }
    func testSSEBoundsMultilineEventsWithoutBlankSeparator() throws {
        var decoder = SSETextDecoder()
        let line = Data(("data: " + String(repeating: "x", count: 4096) + "\n").utf8)
        for _ in 0..<255 { try decoder.append(line) }
        XCTAssertThrowsError(try decoder.append(line)) { error in
            guard case CoreError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}

private final class MockAIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let failing = request.url!.path.contains("error")
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:failing ? 429 : 200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream"])!,cacheStoragePolicy:.notAllowed)
        let body = failing ? "sensitive upstream details must not appear" : "data: {\"choices\":[{\"delta\":{\"content\":\"Success\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self,didLoad:Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension CoreTests {
    func testActualStreamingTransportAndHTTPFailureAreBoundedAndRedacted() async throws {
        let client = AIClient { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockAIProtocol.self]; return c }
        let success = URLRequest(url:URL(string:"https://fixture.invalid/success")!)
        let text = try await client.generate(success) { _ in }
        XCTAssertEqual(text,"Success")
        do { _ = try await client.generate(URLRequest(url:URL(string:"https://fixture.invalid/error")!)) { _ in }; XCTFail("Expected HTTP failure") }
        catch let CoreError.response(code) { XCTAssertEqual(code,429) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
