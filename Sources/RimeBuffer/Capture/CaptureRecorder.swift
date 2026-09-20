import AppKit
import AVFoundation
import ScreenCaptureKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices

struct CaptureRecordingOptions: Codable {
    var format = "MP4"
    var resolution = 1080
    var fps = 30
    var quality = 0.75
    var systemAudio = false
    var microphone = false
    var camera = false
    var cursor = true
    var clicks = false
    var keys = false
    var commandKeysOnly = true
    var cleanDesktop = false
    var countdown = 3
    var cameraSize = 0.22
    var cameraShape = "圆角"
    var cameraPosition = "右下"
    var cameraFullscreen = false
    var clickColor = "22c55e"
    var clickSize = 28.0
    var clickFilled = false
    var keyLight = false
    var keySize = 28.0
    var keyTop = false
    var focusStart = ""
    var focusStop = ""
    var mode = "区域"
    static func load() -> Self {
        UserDefaults.standard.data(forKey:"capture.recording.options").flatMap { try? JSONDecoder().decode(Self.self,from:$0) } ?? Self()
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data,forKey:"capture.recording.options") } }
}

/// Both capture delegates use one serial queue. No encoder, media read, or
/// compositing runs on the input-method event queue.
final class CaptureRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label:"RIMES.Capture.recorder",qos:.userInitiated)
    private var stream: SCStream?
    private var devices: AVCaptureSession?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var systemAudio: AVAssetWriterInput?
    private var microphone: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let ci = CIContext(options:[.cacheIntermediates:false])
    private var cameraFrame: CVPixelBuffer?
    private var screenFrame: CVPixelBuffer?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var offset = CMTime.zero
    private var paused = false
    private var pauseStarted: CMTime?
    private var lastRenderedFrame: CVPixelBuffer?
    private var lastWrittenPTS: CMTime?
    private var statusTimer: DispatchSourceTimer?
    private var finishing = false
    private var recordingError: Error?
    private var size = CGSize.zero
    private var options = CaptureRecordingOptions()
    private var target: CaptureTarget?
    private var latestClick: (CGPoint,TimeInterval)?
    private var latestKey: (String,TimeInterval)?
    private var startedAt = Date()
    private var output: URL?
    var failed: ((Error)->Void)?
    var status: ((Double,Float)->Void)?
    private var audioLevel: Float = 0
    private var lastStatusTime = 0.0
    private var deviceObservers: [NSObjectProtocol] = []

    func start(target:CaptureTarget, content:SCShareableContent, options:CaptureRecordingOptions, output:URL, completion:@escaping(Result<Void,Error>)->Void) {
        queue.async {
            do {
                self.options = options; self.target = target; self.output = output
                let config = CaptureEngine.configuration(target,scale:CaptureEngine.nativeScale(target))
                let factor = min(1,CGFloat(options.resolution)/CGFloat(config.height))
                config.width = max(2,Int(CGFloat(config.width)*factor)/2*2)
                config.height = max(2,Int(CGFloat(config.height)*factor)/2*2)
                config.minimumFrameInterval = CMTime(value:1,timescale:CMTimeScale(options.fps))
                config.showsCursor = options.cursor
                config.capturesAudio = options.systemAudio && options.format != "GIF"
                config.sampleRate = 48000; config.channelCount = 2
                if #available(macOS 14.2, *) { config.includeChildWindows = true }
                self.size = CGSize(width:config.width,height:config.height)
                var filter = CaptureEngine.filter(target,content:content)
                if options.cleanDesktop, target.window == nil {
                    let excluded = content.windows.filter {
                        $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                            || $0.windowLayer < 0 || $0.owningApplication?.bundleIdentifier == "com.apple.notificationcenterui"
                    }
                    filter = SCContentFilter(display:target.display,excludingWindows:excluded)
                    // Excluded desktop surfaces are replaced in the capture,
                    // without changing Finder or system preferences.
                    config.backgroundColor = CaptureRenderer.color("20252a")
                }
                let writer = try AVAssetWriter(outputURL:output,fileType:.mp4)
                let input = AVAssetWriterInput(mediaType:.video,outputSettings:[
                    AVVideoCodecKey:AVVideoCodecType.h264, AVVideoWidthKey:config.width, AVVideoHeightKey:config.height,
                    AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:Int(Double(config.width*config.height)*Double(options.fps)*(0.04+options.quality*0.12)),AVVideoMaxKeyFrameIntervalKey:options.fps*2]
                ])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw CaptureError.message("当前编码设置不可用") }; writer.add(input)
                self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:config.width,kCVPixelBufferHeightKey as String:config.height,kCVPixelBufferIOSurfacePropertiesKey as String:[:] as [String:Any]])
                self.writer = writer; self.video = input
                func audioInput(channels:Int) throws -> AVAssetWriterInput {
                    let input = AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:channels,AVEncoderBitRateKey:128000])
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else { throw CaptureError.message("音频编码配置不可用") }; writer.add(input); return input
                }
                if config.capturesAudio { self.systemAudio = try audioInput(channels:2) }
                if options.microphone, options.format != "GIF" { self.microphone = try audioInput(channels:1) }
                guard writer.startWriting() else { throw writer.error ?? CaptureError.message("无法开始写入视频") }
                try self.prepareDevices(options)
                let stream = SCStream(filter:filter,configuration:config,delegate:self)
                self.stream = stream
                try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:self.queue)
                if config.capturesAudio { try stream.addStreamOutput(self,type:.audio,sampleHandlerQueue:self.queue) }
                self.startedAt = Date()
                stream.startCapture { error in
                    self.queue.async {
                        if let error { self.releaseStream(); self.writer?.cancelWriting(); self.devices?.stopRunning(); completion(.failure(error)) }
                        else if self.finishing { stream.stopCapture { _ in }; completion(.failure(CaptureError.message("录制已取消"))) }
                        else { self.startClock(); completion(.success(())) }
                    }
                }
            } catch { self.writer?.cancelWriting(); self.devices?.stopRunning(); completion(.failure(error)) }
        }
    }
    private func startClock() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let needsAnimation = options.camera || options.clicks || options.keys
        timer.schedule(deadline: .now(), repeating: needsAnimation ? 1 / Double(options.fps) : 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finishing else { return }
            if IsSecureEventInputEnabled() { self.setPaused(true) }
            guard let first = self.firstPTS else {
                if !self.paused, Date().timeIntervalSince(self.startedAt) > 10 { self.fail(CaptureError.message("10 秒内没有可录制的画面，请确认窗口仍然可见")) }
                return
            }
            let now = self.pauseStarted ?? CMClockGetTime(CMClockGetHostTimeClock())
            // ScreenCaptureKit may only send idle frames for a static desktop.
            // Camera and event effects still advance on the recording clock.
            if needsAnimation, !self.paused, let frame = self.screenFrame {
                self.appendFrame(frame, time: CMTimeSubtract(now, self.offset))
            }
            let uptime = ProcessInfo.processInfo.systemUptime
            guard uptime-self.lastStatusTime >= 0.25 else { return }
            self.lastStatusTime = uptime
            let elapsed = max(0, CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(now, self.offset), first)))
            let level = self.paused ? Float(0) : self.audioLevel
            DispatchQueue.main.async { self.status?(elapsed, level) }
        }
        statusTimer = timer; timer.resume()
    }
    private func setPaused(_ value: Bool) {
        guard paused != value else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if value { pauseStarted = now }
        else if let start = pauseStarted { offset = CMTimeAdd(offset, CMTimeSubtract(now, start)); pauseStarted = nil }
        paused = value; latestKey = nil
    }
    private func prepareDevices(_ options:CaptureRecordingOptions) throws {
        guard options.camera || (options.microphone && options.format != "GIF") else { return }
        let session = AVCaptureSession(); session.beginConfiguration(); session.sessionPreset = .medium
        if options.camera {
            guard let device = AVCaptureDevice.default(for:.video) else { throw CaptureError.message("未找到摄像头") }
            let input = try AVCaptureDeviceInput(device:device)
            guard session.canAddInput(input) else { throw CaptureError.message("摄像头不可用") }; session.addInput(input)
            let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self,queue:queue)
            guard session.canAddOutput(output) else { throw CaptureError.message("摄像头输出不可用") }; session.addOutput(output); cameraOutput = output
        }
        if options.microphone, options.format != "GIF" {
            guard let device = AVCaptureDevice.default(for:.audio) else { throw CaptureError.message("未找到麦克风") }
            let input = try AVCaptureDeviceInput(device:device)
            guard session.canAddInput(input) else { throw CaptureError.message("麦克风不可用") }; session.addInput(input)
            let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(self,queue:queue)
            guard session.canAddOutput(output) else { throw CaptureError.message("麦克风输出不可用") }; session.addOutput(output)
        }
        session.commitConfiguration(); session.startRunning(); devices = session
        deviceObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in self?.queue.async { self?.fail(CaptureError.message("采集设备中断，正在保留已录制内容")) } })
        let ids = Set(session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID })
        deviceObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice, ids.contains(device.uniqueID) else { return }
            self?.queue.async { self?.fail(CaptureError.message("摄像头或麦克风已断开，正在保留录制")) }
        })
    }
    func pause(_ value:Bool) {
        queue.async { self.setPaused(value) }
    }
    func click(at point:CGPoint) { queue.async { self.latestClick = (point,ProcessInfo.processInfo.systemUptime) } }
    func key(_ text:String) { queue.async { self.latestKey = (String(text.prefix(40)),ProcessInfo.processInfo.systemUptime) } }
    func stream(_ stream:SCStream,didStopWithError error:Error) {
        queue.async { guard !self.finishing else { return }; self.recordingError = error; DispatchQueue.main.async { self.failed?(error) } }
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType) {
        if IsSecureEventInputEnabled() { setPaused(true) }
        guard !finishing, !paused else { return }
        if type == .screen { appendScreen(sampleBuffer) }
        else if type == .audio { appendAudio(sampleBuffer,input:systemAudio) }
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        if IsSecureEventInputEnabled() { setPaused(true) }
        if output === cameraOutput { cameraFrame = sampleBuffer.imageBuffer }
        else if !paused, !finishing { appendAudio(sampleBuffer,input:microphone) }
    }
    private func appendScreen(_ sample:CMSampleBuffer) {
        guard let buffer = sample.imageBuffer, sample.isValid, let writer, writer.status == .writing else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
           let raw = attachments.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        let pts = sample.presentationTimeStamp
        if firstPTS == nil { writer.startSession(atSourceTime:pts); firstPTS = pts }
        lastPTS = pts
        screenFrame = buffer
        let time = CMTimeSubtract(pts,offset)
        appendFrame(buffer, time: time)
    }
    private func appendFrame(_ buffer: CVPixelBuffer, time: CMTime) {
        guard let writer, let video, writer.status == .writing, video.isReadyForMoreMediaData else { return }
        if let last = lastWrittenPTS, CMTimeGetSeconds(CMTimeSubtract(time, last)) < 0.9 / Double(options.fps) { return }
        guard let pool = adaptor?.pixelBufferPool else { return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&output) == kCVReturnSuccess, let output else { return }
        let image = CIImage(cvPixelBuffer:buffer)
        let scaled = image.transformed(by:CGAffineTransform(scaleX:size.width/image.extent.width,y:size.height/image.extent.height))
        ci.render(scaled,to:output)
        composite(output)
        if adaptor?.append(output,withPresentationTime:time) != true { fail(writer.error ?? CaptureError.message("视频写入失败，可能磁盘空间不足")); return }
        lastRenderedFrame = output; lastWrittenPTS = time
    }
    private func appendAudio(_ sample:CMSampleBuffer,input:AVAssetWriterInput?) {
        guard let input, firstPTS != nil, input.isReadyForMoreMediaData, writer?.status == .writing,
              CMTimeCompare(sample.presentationTimeStamp,firstPTS!) >= 0 else { return }
        // Shift every sample timing, preserving duration and any decode time.
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample,entryCount:0,arrayToFill:nil,entriesNeededOut:&count) == noErr else { return }
        var timing = [CMSampleTimingInfo](repeating:CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.invalid,decodeTimeStamp:.invalid),count:count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample,entryCount:count,arrayToFill:&timing,entriesNeededOut:nil) == noErr else { return }
        for i in timing.indices { timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp,offset); if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp,offset) } }
        var adjusted:CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator:kCFAllocatorDefault,sampleBuffer:sample,sampleTimingEntryCount:count,sampleTimingArray:&timing,sampleBufferOut:&adjusted) == noErr, let adjusted else { return }
        if !input.append(adjusted) { fail(writer?.error ?? CaptureError.message("音轨写入失败")) }
        if let block = sample.dataBuffer {
            var length = 0; var bytes:UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block,atOffset:0,lengthAtOffsetOut:nil,totalLengthOut:&length,dataPointerOut:&bytes) == noErr, let bytes {
                if let description = sample.formatDescription,
                   let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                   format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
                    let count = min(length / 4, 8192)
                    let values = UnsafeRawPointer(bytes).assumingMemoryBound(to: Float.self)
                    var sum: Float = 0
                    for i in 0..<count where values[i].isFinite { sum += values[i] * values[i] }
                    audioLevel = min(1, sqrt(sum / Float(max(1, count))))
                } else { audioLevel = 0 }
            }
        }
    }
    private func composite(_ buffer:CVPixelBuffer) {
        guard options.camera || options.clicks || options.keys else { return }
        CVPixelBufferLockBaseAddress(buffer,[]); defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        guard let ctx = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.translateBy(x:0,y:size.height); ctx.scaleBy(x:1,y:-1)
        if options.camera, let cameraFrame, let image = ci.createCGImage(CIImage(cvPixelBuffer:cameraFrame),from:CIImage(cvPixelBuffer:cameraFrame).extent) {
            var rect = CGRect(x:size.width*(1-options.cameraSize)-20,y:size.height*(1-options.cameraSize)-20,width:size.width*options.cameraSize,height:size.height*options.cameraSize)
            if options.cameraPosition.contains("左") { rect.origin.x = 20 }
            if options.cameraPosition.contains("上") { rect.origin.y = 20 }
            if options.cameraFullscreen { rect = CGRect(origin:.zero,size:size) }
            ctx.saveGState()
            if options.cameraShape == "圆形", !options.cameraFullscreen { rect.size.width = rect.height; ctx.addEllipse(in:rect); ctx.clip() }
            else if options.cameraShape == "圆角", !options.cameraFullscreen { ctx.addPath(CGPath(roundedRect:rect,cornerWidth:18,cornerHeight:18,transform:nil)); ctx.clip() }
            ctx.clip(to: rect)
            let scale = max(rect.width/CGFloat(image.width), rect.height/CGFloat(image.height))
            let fitted = CGRect(x: rect.midX-CGFloat(image.width)*scale/2, y: rect.midY-CGFloat(image.height)*scale/2, width: CGFloat(image.width)*scale, height: CGFloat(image.height)*scale)
            CaptureRenderer.drawImage(image,in:fitted,context:ctx); ctx.restoreGState()
        }
        let now = ProcessInfo.processInfo.systemUptime
        if options.clicks, let (point,time) = latestClick, now-time < 0.6, let target {
                    let source = target.window?.frame ?? CGRect(x:target.display.frame.minX+(target.rect?.minX ?? 0),y:target.display.frame.minY+(target.rect?.minY ?? 0),width:target.rect?.width ?? target.display.frame.width,height:target.rect?.height ?? target.display.frame.height)
            let p = CGPoint(x:(point.x-source.minX)/source.width*size.width,y:(point.y-source.minY)/source.height*size.height)
            let radius = options.clickSize*(1+(now-time)*0.7)
            ctx.setStrokeColor(CaptureRenderer.color(options.clickColor,alpha:1-(now-time)/0.6)); ctx.setFillColor(CaptureRenderer.color(options.clickColor,alpha:0.4)); ctx.setLineWidth(3)
            let rect = CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2)
            if options.clickFilled { ctx.fillEllipse(in:rect) } else { ctx.strokeEllipse(in:rect) }
        }
        if options.keys, let (text,time) = latestKey, now-time < 1.4, !IsSecureEventInputEnabled() {
            let width = min(size.width-40,CGFloat(text.count)*options.keySize*0.7+32)
            let rect = CGRect(x:(size.width-width)/2,y:options.keyTop ? 20 : size.height-70,width:width,height:50)
            ctx.setFillColor(CGColor(gray:options.keyLight ? 1 : 0,alpha:0.82)); ctx.addPath(CGPath(roundedRect:rect,cornerWidth:10,cornerHeight:10,transform:nil)); ctx.fillPath()
            let text = NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:options.keySize,weight:.medium),.foregroundColor:options.keyLight ? NSColor.black : NSColor.white])
            ctx.saveGState(); ctx.translateBy(x:rect.minX+16,y:rect.minY+36); ctx.scaleBy(x:1,y:-1); ctx.textPosition = .zero
            CTLineDraw(CTLineCreateWithAttributedString(text),ctx); ctx.restoreGState()
        }
    }
    private func fail(_ error:Error) { guard recordingError == nil else { return }; recordingError = error; DispatchQueue.main.async { self.failed?(error) } }
    private func releaseStream() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in
            try? stream.removeStreamOutput(self, type: .screen)
            try? stream.removeStreamOutput(self, type: .audio)
        }
    }
    func stop(completion:@escaping(Result<(URL,Double),Error>)->Void) {
        queue.async {
            guard !self.finishing else { return }; self.finishing = true
            self.statusTimer?.cancel(); self.statusTimer = nil
            self.releaseStream()
            self.devices?.stopRunning(); self.latestKey = nil; self.cameraFrame = nil; self.screenFrame = nil
            self.deviceObservers.forEach(NotificationCenter.default.removeObserver); self.deviceObservers.removeAll()
            guard let writer = self.writer, let output = self.output, let first = self.firstPTS else {
                self.writer?.cancelWriting(); completion(.failure(CaptureError.message("没有录到有效画面"))); return
            }
            let end = CMTimeSubtract(self.pauseStarted ?? CMClockGetTime(CMClockGetHostTimeClock()), self.offset)
            let duration = max(0,CMTimeGetSeconds(CMTimeSubtract(end,first)))
            if let frame = self.lastRenderedFrame, let last = self.lastWrittenPTS,
               self.video?.isReadyForMoreMediaData == true {
                let finalFrameTime = CMTimeSubtract(end, CMTime(value: 1, timescale: CMTimeScale(self.options.fps)))
                if CMTimeCompare(finalFrameTime, last) > 0 { _ = self.adaptor?.append(frame, withPresentationTime: finalFrameTime) }
            }
            if writer.status == .writing { writer.endSession(atSourceTime: end) }
            self.lastRenderedFrame = nil
            self.video?.markAsFinished(); self.systemAudio?.markAsFinished(); self.microphone?.markAsFinished()
            writer.finishWriting {
                if writer.status == .completed {
                    if self.options.systemAudio && self.options.microphone && self.options.format != "GIF" {
                        CaptureAudioMix.finish(output) { result in completion(result.map { ($0, duration) }) }
                    } else { completion(.success((output,duration))) }
                }
                else { completion(.failure(writer.error ?? CaptureError.message("视频封装未完成，原始文件已保留"))) }
            }
        }
    }
}

@MainActor
final class CaptureRecorderController {
    private var options = CaptureRecordingOptions.load()
    private var settings:CapturePanel?
    private var controls:CapturePanel?
    private let requestTarget:()->Void
    private let completed:(CaptureRecord)->Void
    private var recorder:CaptureRecorder?
    private var monitors:[Any] = []
    private var paused = false
    private var stopping = false
    private var recordingFailed = false
    private var token = UUID()
    private let label = CaptureUI.label("准备录制",size:15)
    private let pauseButton = CaptureButton("暂停") {}
    private var menuItem: NSStatusItem?
    private(set) var isRecording = false

    init(requestTarget:@escaping()->Void,completed:@escaping(CaptureRecord)->Void) { self.requestTarget = requestTarget; self.completed = completed }
    func showSettings() {
        let panel = CapturePanel(size:NSSize(width:560,height:710)); settings = panel
        panel.closed = { [weak self, weak panel] in self?.settings = nil; panel?.contentView = nil }
        let mode = NSPopUpButton(); mode.addItems(withTitles:["区域","窗口","全屏"]); mode.selectItem(withTitle:options.mode)
        let format = NSPopUpButton(); format.addItems(withTitles:["MP4","GIF"]); format.selectItem(withTitle:options.format)
        let resolution = NSPopUpButton(); resolution.addItems(withTitles:["720","1080","1440","2160"]); resolution.selectItem(withTitle:String(options.resolution))
        let fps = NSPopUpButton(); fps.addItems(withTitles:["15","24","30","60"]); fps.selectItem(withTitle:String(options.fps))
        func toggle(_ title:String,_ value:Bool)->NSButton { let button = NSButton(checkboxWithTitle:title,target:nil,action:nil); button.state = value ? .on : .off; return button }
        let audio = toggle("系统声音",options.systemAudio), mic = toggle("麦克风",options.microphone), camera = toggle("摄像头",options.camera)
        let clicks = toggle("点击效果",options.clicks), keys = toggle("显示按键",options.keys), cursor = toggle("显示光标",options.cursor)
        let onlyCommands = toggle("仅显示组合快捷键",options.commandKeysOnly), clean = toggle("隐藏桌面图标及小组件",options.cleanDesktop)
        let camFull = toggle("摄像头全屏",options.cameraFullscreen), keyLight = toggle("浅色按键",options.keyLight), keyTop = toggle("按键显示在顶部",options.keyTop)
        let quality = NSSlider(value:options.quality,minValue:0.2,maxValue:1,target:nil,action:nil)
        let countdown = NSTextField(string:String(options.countdown))
        let cameraSize = NSTextField(string:String(Int(options.cameraSize*100)))
        let cameraShape = NSPopUpButton(); cameraShape.addItems(withTitles:["圆角","圆形","矩形"]); cameraShape.selectItem(withTitle:options.cameraShape)
        let cameraPosition = NSPopUpButton(); cameraPosition.addItems(withTitles:["右下","左下","右上","左上"]); cameraPosition.selectItem(withTitle:options.cameraPosition)
        let clickColor = NSTextField(string:options.clickColor), clickSize = NSTextField(string:String(Int(options.clickSize))), keySize = NSTextField(string:String(Int(options.keySize)))
        let filled = toggle("实心点击效果",options.clickFilled)
        let focusStart = NSTextField(string:options.focusStart), focusStop = NSTextField(string:options.focusStop)
        focusStart.placeholderString = "开启勿扰的快捷指令名称（可选）"; focusStop.placeholderString = "恢复专注状态的快捷指令名称（可选）"
        let start = CaptureButton("开始录制") {
            self.options.mode = mode.titleOfSelectedItem ?? "区域"; self.options.format = format.titleOfSelectedItem ?? "MP4"
            self.options.resolution = Int(resolution.titleOfSelectedItem ?? "1080") ?? 1080; self.options.fps = Int(fps.titleOfSelectedItem ?? "30") ?? 30
            self.options.systemAudio = audio.state == .on; self.options.microphone = mic.state == .on; self.options.camera = camera.state == .on
            self.options.clicks = clicks.state == .on; self.options.keys = keys.state == .on; self.options.cursor = cursor.state == .on
            self.options.commandKeysOnly = onlyCommands.state == .on; self.options.cleanDesktop = clean.state == .on
            self.options.cameraFullscreen = camFull.state == .on; self.options.keyLight = keyLight.state == .on; self.options.keyTop = keyTop.state == .on
            self.options.quality = quality.doubleValue; self.options.countdown = min(30,max(0,countdown.integerValue))
            self.options.cameraSize = min(0.8,max(0.1,cameraSize.doubleValue/100)); self.options.cameraShape = cameraShape.titleOfSelectedItem ?? "圆角"; self.options.cameraPosition = cameraPosition.titleOfSelectedItem ?? "右下"
            self.options.clickColor = clickColor.stringValue; self.options.clickSize = min(100,max(8,clickSize.doubleValue)); self.options.clickFilled = filled.state == .on; self.options.keySize = min(64,max(12,keySize.doubleValue))
            self.options.focusStart = focusStart.stringValue; self.options.focusStop = focusStop.stringValue
            self.options.save(); self.authorize()
        }
        CaptureUI.fill(CaptureUI.column([
            CaptureUI.row([CaptureUI.label("录制屏幕",size:16),CaptureButton("关闭") { panel.close() }]),
            CaptureUI.row([mode,format,resolution,fps]),CaptureUI.label("GIF 无声音 · 本机收藏，不同步视频"),
            CaptureUI.row([audio,mic,camera]),CaptureUI.row([clicks,keys,cursor]),onlyCommands,clean,
            CaptureUI.row([CaptureUI.label("画质"),quality,CaptureUI.label("倒计时"),countdown]),
            CaptureUI.row([cameraShape,cameraPosition,CaptureUI.label("大小 %"),cameraSize]),camFull,
            CaptureUI.row([CaptureUI.label("点击颜色 / 大小"),clickColor,clickSize]),filled,
            CaptureUI.row([keyLight,keyTop,keySize]),focusStart,focusStop,
            CaptureUI.row([CaptureUI.label("勿扰联动使用系统快捷指令"), CaptureButton("设置") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }]),start
        ],spacing:12),in:panel.contentView!)
        panel.present()
    }
    private func authorize() {
        Task {
            // Each optional input asks through the shared audit, so a refusal
            // is reported by the same page that lists the grant.
            if options.camera, !SystemPermissionAudit.ensure(.camera) {
                CaptureUI.error(CaptureError.message("摄像头权限未开启；关闭摄像头选项可继续录屏")); return
            }
            if options.microphone, options.format != "GIF",
               !SystemPermissionAudit.ensure(.microphone) {
                CaptureUI.error(CaptureError.message("麦克风权限未开启；关闭麦克风选项可继续录屏")); return
            }
            if options.keys, !SystemPermissionAudit.ensure(.inputMonitoring) {
                CaptureUI.error(CaptureError.message("显示全局按键需要输入监控授权；关闭按键选项可继续录屏")); return
            }
            if options.keys, !SystemPermissionAudit.ensure(.accessibility) {
                CaptureUI.error(CaptureError.message("按键显示还需要辅助功能授权；关闭按键选项可继续录屏")); return
            }
            settings?.close()
            if options.mode == "区域" { requestTarget() }
            else { CaptureCoordinator.shared.begin(options.mode == "窗口" ? "recordWindow" : "recordScreen",freeze:false) }
        }
    }
    func start(target:CaptureTarget,content:SCShareableContent) {
        token = UUID(); let current = token
        showControls(); isRecording = true
        Task {
            do {
                if options.countdown > 0 { for second in (1...options.countdown).reversed() { guard current == token else { return }; label.stringValue = "\(second) 秒后开始"; try await Task.sleep(nanoseconds:1_000_000_000) } }
                guard current == token, !IsSecureEventInputEnabled() else { isRecording = false; controls?.close(); return }
                let store = try CaptureStore.shared.get(), pending = store.root.appendingPathComponent("recording-\(UUID().uuidString).mp4")
                let engine = CaptureRecorder(); recorder = engine
                engine.status = { [weak self] seconds, level in
                    guard let self, !self.paused else { return }
                    let time = String(format:"%02d:%02d",Int(seconds)/60,Int(seconds)%60)
                    self.label.stringValue = "● \(time)  \(level > 0 ? "音频 ●" : "")"; self.menuItem?.button?.title = "● " + time
                }
                engine.failed = { [weak self] error in self?.recordingFailed = true; self?.label.stringValue = error.localizedDescription; self?.stop() }
                engine.start(target:target,content:content,options:options,output:pending) { result in
                    DispatchQueue.main.async {
                        guard self.token == current, !self.stopping else { return }
                        switch result {
                        case .success: self.monitorEvents(); self.shortcut(self.options.focusStart); self.label.stringValue = "● 00:00"
                        case .failure(let error): self.recorder = nil; self.isRecording = false; self.controls?.close(); self.removeMonitors(); CaptureUI.error(error)
                        }
                    }
                }
            } catch { isRecording = false; controls?.close(); CaptureUI.error(error) }
        }
    }
    func showControls() {
        if let controls { controls.present(center:false); return }
        let panel = CapturePanel(size:NSSize(width:350,height:65),key:false); controls = panel
        panel.closed = { [weak self, weak panel] in self?.controls = nil; panel?.contentView = nil }
        pauseButton.perform = { [weak self] in
            guard let self, self.recorder != nil, !IsSecureEventInputEnabled() else { return }
            self.paused.toggle(); self.pauseButton.title = self.paused ? "继续" : "暂停"; self.label.stringValue = self.paused ? "已暂停" : "继续录制"; self.recorder?.pause(self.paused)
        }
        CaptureUI.fill(CaptureUI.row([label,pauseButton,CaptureButton("停止",symbol:"stop.fill") { self.stop() }]),in:panel.contentView!)
        panel.present()
        menuItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength); menuItem?.button?.title = "● 准备"
    }
    func pauseForProtection() { guard isRecording else { return }; paused = true; recorder?.pause(true); pauseButton.title = "继续"; label.stringValue = "保护输入 · 已暂停" }
    private func monitorEvents() {
        if options.keys {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching:.keyDown,handler:{ [weak self] event in
                self?.observeKey(event)
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in self?.observeKey(event); return event }) { monitors.append(monitor) }
        }
        if options.clicks {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown],handler:{ [weak self] _ in
                guard let p = CGEvent(source:nil)?.location else { return }; self?.recorder?.click(at:p)
            }) { monitors.append(monitor) }
        }
    }
    private func observeKey(_ event: NSEvent) {
        guard !IsSecureEventInputEnabled(), !paused else { return }
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.delegate is NSSecureTextField { pauseForProtection(); return }
        let mods = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if options.commandKeysOnly, mods.intersection([.command,.control,.option]).isEmpty { return }
        let prefix = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "")
        recorder?.key(prefix + (event.charactersIgnoringModifiers ?? ""))
    }
    private func removeMonitors() { monitors.forEach(NSEvent.removeMonitor); monitors.removeAll(); if let item = menuItem { NSStatusBar.system.removeStatusItem(item) }; menuItem = nil }
    func stop() {
        guard !stopping else { return }; stopping = true; token = UUID(); removeMonitors()
        guard let recorder else { isRecording = false; controls?.close(); return }
        label.stringValue = "正在封装…"; pauseButton.isEnabled = false
        let options = options, incomplete = recordingFailed
        recorder.stop { result in
            DispatchQueue.global(qos:.userInitiated).async {
                let saved = Result { () throws -> CaptureRecord in
                    let (url,duration) = try result.get()
                    var final = url
                    if options.format == "GIF" { final = try CaptureGIF.convert(url,fps:min(options.fps,15)) }
                    let record = try CaptureStore.shared.get().importFile(final,kind:options.format == "GIF" ? .gif : .video,duration:duration,incomplete:incomplete,moveSource:true)
                    try? FileManager.default.removeItem(at:url); if final != url { try? FileManager.default.removeItem(at:final) }
                    return record
                }
                DispatchQueue.main.async {
                    self.recorder = nil; self.isRecording = false; self.controls?.close(); self.shortcut(options.focusStop)
                    switch saved { case .success(let record): self.completed(record); case .failure(let error): CaptureUI.error(error) }
                }
            }
        }
    }
    private func shortcut(_ name:String) {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.global(qos:.utility).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/shortcuts"); process.arguments = ["run",name]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); if process.terminationStatus != 0 { DispatchQueue.main.async { CaptureUI.error(CaptureError.message("勿扰快捷指令未执行成功：\(name)")) } } }
            catch { DispatchQueue.main.async { CaptureUI.error(error) } }
        }
    }
}

enum CaptureAudioMix {
    /// Two AAC tracks are often treated as alternatives by players. Flatten
    /// them into one mixed track before publishing a dual-source recording.
    static func finish(_ source: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let asset = AVURLAsset(url: source)
                let tracks = asset.tracks(withMediaType: .audio)
                guard tracks.count > 1 else { completion(.success(source)); return }
                let composition = AVMutableComposition()
                let range = CMTimeRange(start: .zero, duration: asset.duration)
                for track in asset.tracks(withMediaType: .video) {
                    guard let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureError.message("无法创建视频轨") }
                    try destination.insertTimeRange(range, of: track, at: .zero)
                    destination.preferredTransform = track.preferredTransform
                }
                var inputs: [AVAudioMixInputParameters] = []
                for track in tracks {
                    guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureError.message("无法创建混音轨") }
                    try destination.insertTimeRange(track.timeRange, of: track, at: track.timeRange.start)
                    let parameters = AVMutableAudioMixInputParameters(track: destination)
                    parameters.setVolume(0.75, at: .zero); inputs.append(parameters)
                }
                let mix = AVMutableAudioMix(); mix.inputParameters = inputs
                let output = source.deletingLastPathComponent().appendingPathComponent("recording-mixed-\(UUID().uuidString).mp4")
                guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw CaptureError.message("双音源混音不可用，原始录制已保留") }
                exporter.outputURL = output; exporter.outputFileType = .mp4; exporter.audioMix = mix; exporter.shouldOptimizeForNetworkUse = true
                exporter.exportAsynchronously {
                    if exporter.status == .completed {
                        try? FileManager.default.removeItem(at: source)
                        completion(.success(output))
                    } else { completion(.failure(exporter.error ?? CaptureError.message("双音源混音失败，原始录制已保留"))) }
                }
            } catch { completion(.failure(error)) }
        }
    }
}

enum CaptureGIF {
    static func convert(_ url:URL,fps:Int) throws -> URL {
        let asset = AVURLAsset(url:url), duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0, duration <= 120 else { throw CaptureError.message("GIF 最长支持 2 分钟；原始 MP4 已保留在捕获目录") }
        let output = url.deletingPathExtension().appendingPathExtension("gif")
        let count = max(1,Int(duration*Double(fps)))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,UTType.gif.identifier as CFString,count,nil) else { throw CaptureError.message("GIF 输出失败") }
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset:asset); generator.maximumSize = CGSize(width:1280,height:1280); generator.appliesPreferredTrackTransform = true
        for index in 0..<count {
            try autoreleasepool {
                let image = try generator.copyCGImage(at:CMTime(seconds:Double(index)/Double(fps),preferredTimescale:600),actualTime:nil)
                CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1/Double(fps)]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("GIF 封装失败，原始 MP4 已保留") }
        return output
    }
}
