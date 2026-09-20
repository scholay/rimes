import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import AVFoundation

enum CaptureSmoke {
    static func media(_ file: String) async -> Bool {
        do {
            let url = URL(fileURLWithPath: file)
            let mixed = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in CaptureAudioMix.finish(url) { c.resume(with: $0) } }
            let asset = AVURLAsset(url: mixed)
            let audio = try await asset.loadTracks(withMediaType: .audio), video = try await asset.loadTracks(withMediaType: .video)
            guard audio.count == 1, video.count == 1 else { throw CaptureError.message("mixed recording must contain one video and one audio track") }
            let descriptions = try await video[0].load(.formatDescriptions)
            guard descriptions.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264 else { throw CaptureError.message("MP4 output is not H.264") }
            let gif = try CaptureGIF.convert(mixed, fps: 10)
            guard let imageSource = CGImageSourceCreateWithURL(gif as CFURL, nil), CGImageSourceGetCount(imageSource) > 1 else { throw CaptureError.message("animated GIF invalid") }
            print("capture-media-smoke: OK (dual audio flattened, H.264, animated GIF)")
            return true
        } catch { print("capture-media-smoke: FAILED \(error.localizedDescription)"); return false }
    }
    static func fixture(width:Int = 480,height:Int = 900) throws -> CGImage {
        let ctx = try CaptureRenderer.context(CGSize(width:width,height:height))
        ctx.setFillColor(CGColor(gray:0.96,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:width,height:height))
        var seed:UInt64 = 398491
        for y in stride(from:0,to:height,by:11) {
            for x in stride(from:18,to:width-18,by:17) {
                seed = seed &* 6364136223846793005 &+ 1
                ctx.setFillColor(CGColor(gray:CGFloat(seed % 200)/255,alpha:1))
                ctx.fill(CGRect(x:x,y:y,width:11,height:7))
            }
        }
        return ctx.makeImage()!
    }
    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-capture-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        func require(_ condition:Bool,_ message:String) throws { if !condition { throw CaptureError.message(message) } }
        do {
            let store = try CaptureStore(root:root.appendingPathComponent("captures"))
            let image = try fixture()
            let record = try store.importImage(image)
            try require(try store.records().count == 1,"metadata publication")
            let original = try Data(contentsOf:store.url(record))
            store.acquire(record.id)
            try require(try store.prune(capacity:0) == 0,"active lease must survive capacity cleanup")
            store.release(record.id)
            let saved = try store.collect(record.id)
            let again = try store.collect(record.id)
            try require(saved.collectionID == again.collectionID,"collection must be idempotent")
            try require(try store.prune(now:Date.distantFuture,capacity:0) == 0,"collected media must survive cleanup")
            let temp = try store.importImage(image)
            try require(try store.prune(capacity:0) == 1,"only temporary capture pruned")
            try require(!FileManager.default.fileExists(atPath:store.directory(temp.id).path),"prune removes asset directory")
            var document = CaptureDocument(image:image,file:record.original)
            document.annotations = [CaptureAnnotation(tool:.redact,points:[CGPoint(x:20,y:20),CGPoint(x:150,y:120)],color:"000000")]
            let result = try CaptureRenderer.render(document,directory:store.directory(record.id))
            let sample = result.cropping(to:CGRect(x:40,y:40,width:1,height:1))!
            let pixel = try CaptureRenderer.context(CGSize(width:1,height:1)); CaptureRenderer.drawImage(sample,in:CGRect(x:0,y:0,width:1,height:1),context:pixel)
            let values = pixel.data!.assumingMemoryBound(to:UInt8.self)
            try require(values[0] == 0 && values[1] == 0 && values[2] == 0,"export must contain actual redaction pixels")
            try require(try Data(contentsOf:store.url(record)) == original,"render must not mutate original")
            let archive = root.appendingPathComponent("example.rimesproject")
            try CaptureProjectPackage.write(document:document,directory:store.directory(record.id),output:archive)
            let restored = root.appendingPathComponent("restored"); try CaptureStore.ensureDirectory(restored)
            try require(try CaptureProjectPackage.restore(archive,directory:restored) == document,"project round trip")
            let imported = try store.importProject(archive)
            try require(imported.project != nil && imported.output != imported.original, "project import publishes rendered output separately")
            try require(try CaptureImageIO.read(restored.appendingPathComponent(record.original)).width == image.width,"project dependencies restored")
            let decoder = JSONDecoder(); let encoded = try JSONEncoder().encode(document)
            try require(try decoder.decode(CaptureDocument.self,from:encoded) == document,"document round trip")
            let smallPreview = try CaptureRenderer.render(document, directory: store.directory(record.id), preview: true)
            try require(max(smallPreview.width, smallPreview.height) <= 1600, "preview pixel ceiling")
            for tool in CaptureTool.allCases where tool != .select && tool != .crop {
                var sample = document
                sample.annotations = [CaptureAnnotation(tool: tool, points: [CGPoint(x: 30, y: 30), CGPoint(x: 200, y: 140)], color: "e34b3f", text: "标注 1")]
                let rendered = try CaptureRenderer.render(sample, directory: store.directory(record.id))
                try require(rendered.width == image.width && rendered.height == image.height, "annotation render dimensions: \(tool.rawValue)")
            }
            var large = document; large.size = CGSize(width: 3000, height: 24000); large.layers[0].frame.size = large.size
            let longPreview = try CaptureRenderer.render(large, directory: store.directory(record.id), preview: true)
            try require(max(longPreview.width, longPreview.height) <= 1600, "long preview must be downsampled before allocation")
            try require(CaptureKind.gif.capsuleKind == .video, "GIF recordings are local video collections")
            var malicious = document; malicious.layers[0].file = "../escape.png"
            do { try malicious.validate(); throw CaptureError.message("unsafe project path accepted") } catch CaptureError.message(let message) { try require(message != "unsafe project path accepted",message) }
            let a = image.cropping(to:CGRect(x:0,y:0,width:480,height:500))!
            let b = image.cropping(to:CGRect(x:0,y:120,width:480,height:500))!
            try require(CaptureScrollMatcher.match(a,a,axis:.vertical) == .stationary,"stationary scroll")
            if case .advance(let shift) = CaptureScrollMatcher.match(a,b,axis:.vertical) { try require(abs(shift-120) <= 3,"vertical overlap offset") }
            else { throw CaptureError.message("vertical scroll overlap rejected") }
            let wide = try fixture(width:900,height:480)
            let left = wide.cropping(to:CGRect(x:0,y:0,width:500,height:480))!, right = wide.cropping(to:CGRect(x:120,y:0,width:500,height:480))!
            if case .advance(let shift) = CaptureScrollMatcher.match(left,right,axis:.horizontal) { try require(abs(shift-120) <= 3,"horizontal overlap offset") }
            else { throw CaptureError.message("horizontal scroll overlap rejected") }
            document.background.enabled = true; document.background.padding = 24
            let framed = try CaptureRenderer.render(document,directory:store.directory(record.id))
            try require(framed.width == image.width+48 && framed.height == image.height+48,"background output geometry")
            document.turns = 1; document.background.enabled = false
            let rotated = try CaptureRenderer.render(document,directory:store.directory(record.id))
            try require(rotated.width == image.height && rotated.height == image.width,"rotation output geometry")
            let content = CapsuleContentStore(rootURL:root)
            let videoURL = root.appendingPathComponent("sample.mp4"); try Data([0,1,2]).write(to:videoURL)
            _ = try content.put(CapsuleContentWriteRequest(type:.video,title:"Local video",content:videoURL.path))
            try require(try content.synchronizationDocuments().allSatisfy { $0.record.summary.type != .video },"videos excluded from cloud")
            // The capture shortcuts deliberately claim the two macOS
            // screenshot combinations: ⌘⇧5 opens the strip, ⌘⇧4 goes
            // straight to a region. macOS keeps them until the user turns
            // the matching rows off in System Settings, so registration can
            // fail — CaptureHotKey records that rather than going quiet.
            let fresh = UserDefaults(suiteName: UUID().uuidString)!
            let panelShortcut = RimeShortcutPreferences.shortcut(for: .captureScreen, defaults: fresh)
            let areaShortcut = RimeShortcutPreferences.shortcut(for: .captureArea, defaults: fresh)
            try require(panelShortcut.keyCode == UInt16(kVK_ANSI_5)
                && panelShortcut.modifiers == [.command, .shift],
                "capture panel shortcut defaults to ⌘⇧5")
            try require(areaShortcut.keyCode == UInt16(kVK_ANSI_4)
                && areaShortcut.modifiers == [.command, .shift],
                "capture area shortcut defaults to ⌘⇧4")
            try cloudProjectRoundTrip(root: root.appendingPathComponent("project-sync"))
            print("capture-smoke: OK (lifecycle, redaction, immutable source, projects, scroll, layout, local video)")
            return true
        } catch { print("capture-smoke: FAILED \(error.localizedDescription)"); return false }
    }

    private static func cloudProjectRoundTrip(root: URL) throws {
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), cloud = root.appendingPathComponent("cloud")
        try CaptureStore.ensureDirectory(cloud)
        let store = try CaptureStore(root: a.appendingPathComponent("captures"))
        var record = try store.importImage(fixture(width: 100, height: 100))
        let document = CaptureDocument(image: try CaptureImageIO.read(store.url(record)), file: record.original)
        record.output = "render-smoke.png"; record.project = "project-smoke.json"
        try CaptureImageIO.write(CaptureRenderer.render(document, directory: store.directory(record.id)), to: store.url(record))
        try JSONEncoder().encode(document).write(to: store.directory(record.id).appendingPathComponent(record.project!))
        try CaptureProjectPackage.write(document: document, directory: store.directory(record.id), output: store.url(record).appendingPathExtension("rimesproject"))
        try store.update(record); record = try store.collect(record.id)
        let contentA = CapsuleContentStore(rootURL: a), contentB = CapsuleContentStore(rootURL: b)
        let library = try CapsuleCloudSyncEngine.prepareLibrary(at: cloud)
        let engineA = CapsuleCloudSyncEngine(contentStore: contentA, localRootURL: a, cloudRootURL: cloud, stateURL: root.appendingPathComponent("state-a.json"), libraryID: library)
        let engineB = CapsuleCloudSyncEngine(contentStore: contentB, localRootURL: b, cloudRootURL: cloud, stateURL: root.appendingPathComponent("state-b.json"), libraryID: library)
        _ = try engineA.synchronize(); _ = try engineB.synchronize()
        let entry = try contentB.record(id: record.collectionID!)
        let sidecar = URL(fileURLWithPath: entry.content).appendingPathExtension("rimesproject")
        let data = try Data(contentsOf: sidecar); try CaptureProjectPackage.validate(data)
        let archive = try JSONDecoder().decode(CaptureProjectPackage.Archive.self, from: data)
        guard archive.document == document else { throw CaptureError.message("cross-device editable project differs") }
        // A missing dependency must not be reported as a successful sync.
        let assets = cloud.appendingPathComponent("v1/assets")
        let remote = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil).first { $0.pathExtension == "rimesproject" }!
        try FileManager.default.removeItem(at: remote); try FileManager.default.removeItem(at: sidecar)
        var refused = false
        do { refused = try engineB.synchronize().deferred > 0 } catch { refused = true }
        guard refused else { throw CaptureError.message("missing project dependency reported sync success") }
        try data.write(to: remote)
        _ = try engineB.synchronize()
        guard FileManager.default.fileExists(atPath: sidecar.path) else { throw CaptureError.message("project dependency recovery failed") }
    }

    @MainActor static func preview(_ output:String) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-capture-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        do {
            let store = try CaptureStore(root:root.appendingPathComponent("captures"))
            let ctx = try CaptureRenderer.context(CGSize(width:1000,height:620))
            ctx.setFillColor(CGColor(gray:0.96,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:1000,height:620))
            CaptureRenderer.draw(CaptureAnnotation(tool:.text,points:[CGPoint(x:60,y:80)],color:"17202b",width:8,text:"把看到的内容，变成可用的信息。"),context:ctx,canvas:CGSize(width:1000,height:620))
            for i in 0..<3 { ctx.setFillColor(CaptureRenderer.color(["dbe7df","dce5f4","efe4d8"][i])); ctx.fill(CGRect(x:60+i*300,y:240,width:270,height:260)) }
            let record = try store.importImage(ctx.makeImage()!)
            let editor = try CaptureEditor(record:record,store:store)
            editor.show()
            RunLoop.current.run(until:Date().addingTimeInterval(2))
            guard let view = editor.panel.contentView else { return false }
            view.layoutSubtreeIfNeeded()
            if let actual = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(editor.panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                try CaptureImageIO.write(actual, to: URL(fileURLWithPath: output))
                editor.panel.close()
                print("capture preview rendered native window \(actual.width)x\(actual.height)")
                return true
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return false }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            guard let data = bitmap.representation(using:.png,properties:[:]) else { return false }
            try data.write(to:URL(fileURLWithPath:output)); editor.panel.close()
            print("capture preview rendered \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"); return true
        } catch { print(error.localizedDescription); return false }
    }

    @MainActor static func live(seconds:Int) async -> Bool {
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        guard CGPreflightScreenCaptureAccess() else { print("capture-live-smoke: NEEDS_SCREEN_PERMISSION"); return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-capture-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let panel = CapturePanel(size:NSSize(width:640,height:420))
        let label = CaptureUI.label("Capsule 录制验证 · 仅捕获此测试窗口",size:20)
        let input = NSTextField(string:"中文组字验证区域")
        CaptureUI.fill(CaptureUI.column([label,input]),in:panel.contentView!)
        panel.present(); defer { panel.close() }
        do {
            try CaptureStore.ensureDirectory(folder)
            try await Task.sleep(nanoseconds:500_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == UInt32(panel.windowNumber) }), let display = content.displays.first else { throw CaptureError.message("test window unavailable id=\(panel.windowNumber) own=\(content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }.map(\.windowID))") }
            let recorder = CaptureRecorder(); var options = CaptureRecordingOptions(); options.systemAudio = true; options.keys = true
            var streamFailure: Error?
            recorder.failed = { error in streamFailure = error; print("capture-live-smoke: stream error \(error.localizedDescription)"); fflush(stdout) }
            recorder.status = { elapsed, _ in if Int(elapsed) % 60 == 0 { print("capture-live-smoke: encoded=\(Int(elapsed))s"); fflush(stdout) } }
            let url = folder.appendingPathComponent("test.mp4")
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in recorder.start(target:CaptureTarget(display:display,window:window,rect:nil),content:content,options:options,output:url) { c.resume(with:$0) } }
            var maxDelay = 0.0
            for tick in 0..<max(3,seconds) {
                let start = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(nanoseconds:1_000_000_000)
                maxDelay = max(maxDelay,ProcessInfo.processInfo.systemUptime-start-1)
                if let streamFailure {
                    _ = try? await withCheckedThrowingContinuation { (c: CheckedContinuation<(URL, Double), Error>) in recorder.stop { c.resume(with: $0) } }
                    throw streamFailure
                }
                label.stringValue = "录制验证 · \(tick+1) / \(seconds) 秒"
                if tick % 60 == 0 { print("capture-live-smoke: wall=\(tick+1)s windowVisible=\(panel.isVisible)"); fflush(stdout) }
                if seconds > 10, tick == 3 { recorder.pause(true) }
                if seconds > 10, tick == 5 { recorder.pause(false) }
                if tick == 7 { recorder.key("⌘⇧V") }
            }
            let (_,duration) = try await withCheckedThrowingContinuation { (c:CheckedContinuation<(URL,Double),Error>) in recorder.stop { c.resume(with:$0) } }
            let asset = AVURLAsset(url:url)
            let tracks = try await asset.loadTracks(withMediaType:.video)
            guard !tracks.isEmpty, duration > 1 else { throw CaptureError.message("recorded video invalid") }
            print("capture-live-smoke: OK seconds=\(Int(duration)) maxMainTimerDelay=\(maxDelay) bytes=\(CaptureStore.bytes(in:folder))")
            return true
        } catch { print("capture-live-smoke: FAILED \(error.localizedDescription)"); return false }
    }
}
