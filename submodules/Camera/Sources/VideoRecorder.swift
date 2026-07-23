import Foundation
import os
import AVFoundation
import UIKit
import CoreImage
import SwiftSignalKit
import TelegramCore

private extension CMSampleBuffer {
    var endTime: CMTime {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(self)
        let duration = CMSampleBufferGetDuration(self)
        return presentationTime + duration
    }
}

private final class VideoRecorderImpl {
    public enum RecorderError: LocalizedError {
        case generic
        case avError(Error)
       
        public var errorDescription: String? {
            switch self {
            case .generic:
                return "Error"
            case let .avError(error):
                return error.localizedDescription
            }
        }
    }
    
    private let queue = DispatchQueue(label: "VideoRecorder")
    
    private var assetWriter: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    
    private let ciContext: CIContext
    fileprivate var transitionImage: UIImage?
    private var savedTransitionImage = false
    
    private var pendingAudioSampleBuffers: [CMSampleBuffer] = []
    
    private var _duration = Atomic<CMTime>(value: .zero)
    public var duration: CMTime {
        return self._duration.with { $0 }
    }
        
    private var startedSession = false
    private var lastVideoSampleTime: CMTime = .invalid
    private var recordingStartSampleTime: CMTime = .invalid
    private var recordingStopSampleTime: CMTime = .invalid
    
    private var positionChangeTimestamps: [(Camera.Position, CMTime)] = []
    
    private let configuration: VideoRecorder.Configuration
    private let orientation: AVCaptureVideoOrientation
    private let videoTransform: CGAffineTransform
    private let url: URL
    fileprivate var completion: (Bool, UIImage?, [(Camera.Position, CMTime)]?) -> Void = { _, _, _ in }
    
    private let error = Atomic<Error?>(value: nil)
    
    private var _stopped = Atomic<Bool>(value: false)
    private var stopped: Bool {
        return self._stopped.with { $0 }
    }
    
    private var hasAllVideoBuffers = false
    private var hasAllAudioBuffers = false

    private var didComplete = false
    private var didAppendFirstVideoFrame = false

    // All terminal paths use this guard to prevent duplicate completion.
    private func completeOnce(success: Bool) {
        dispatchPrecondition(condition: .onQueue(self.queue))
        guard !self.didComplete else {
            return
        }
        self.didComplete = true
        let completion = self.completion
        if success {
            Queue.mainQueue().async {
                completion(true, self.transitionImage, self.positionChangeTimestamps)
            }
        } else {
            Queue.mainQueue().async {
                completion(false, nil, nil)
            }
        }
    }

    // Cancel immediately: after an error, append guards prevent buffers from reaching finish.
    private func failTerminally(error: RecorderError) {
        dispatchPrecondition(condition: .onQueue(self.queue))
        let _ = self.error.modify { _ in return error }
        let _ = self._stopped.modify { _ in return true }
        self.pendingAudioSampleBuffers = []
        if self.assetWriter.status == .writing {
            self.assetWriter.cancelWriting()
        }
        self.completeOnce(success: false)
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        dispatchPrecondition(condition: .onQueue(self.queue))
        if self.configuration.optimizeRoundVideo {
            let startTime = CACurrentMediaTime()
            while !input.isReadyForMoreMediaData {
                if self.assetWriter.status == .failed || CACurrentMediaTime() - startTime > 2.0 {
                    return false
                }
                usleep(2000)
            }
        } else {
            // Preserve the legacy wait behavior for the control configuration.
            while !input.isReadyForMoreMediaData {
                let maxDate = Date(timeIntervalSinceNow: 0.05)
                RunLoop.current.run(until: maxDate)
            }
        }
        return true
    }
    
    public init?(configuration: VideoRecorder.Configuration, ciContext: CIContext, orientation: AVCaptureVideoOrientation, fileUrl: URL) {
        self.configuration = configuration
        self.ciContext = ciContext
        
        var transform: CGAffineTransform = CGAffineTransform(rotationAngle: .pi / 2.0)
        if orientation == .landscapeLeft {
            transform = CGAffineTransform(rotationAngle: .pi)
        } else if orientation == .landscapeRight {
            transform = CGAffineTransform(rotationAngle: 0.0)
        } else if orientation == .portraitUpsideDown {
            transform = CGAffineTransform(rotationAngle: -.pi / 2.0)
        }
        
        self.orientation = orientation
        self.videoTransform = transform
        self.url = fileUrl
        
        try? FileManager.default.removeItem(at: url)
        guard let assetWriter = try? AVAssetWriter(url: url, fileType: .mp4) else {
            return nil
        }
        self.assetWriter = assetWriter
        self.assetWriter.shouldOptimizeForNetworkUse = false
    }
    
    private func hasError() -> Error? {
        return self.error.with { $0 }
    }
    
    public func start() {
        self.queue.async {
            self.recordingStartSampleTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            if self.configuration.optimizeRoundVideo {
                self.preflightStartWriting()
            }
        }
    }

    // Prepare both inputs before frames arrive so initialization does not consume frame one.
    // Pre-check failures fall back to lazy setup; startWriting failures are terminal.
    private func preflightStartWriting() {
        dispatchPrecondition(condition: .onQueue(self.queue))
        guard self.assetWriter.status == .unknown, self.videoInput == nil, self.audioInput == nil else {
            return
        }
        guard self.assetWriter.canApply(outputSettings: self.configuration.videoSettings, forMediaType: .video) else {
            return
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: self.configuration.videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = self.videoTransform
        guard self.assetWriter.canAdd(videoInput) else {
            return
        }

        var audioInput: AVAssetWriterInput?
        if self.configuration.hasAudio {
            guard self.assetWriter.canApply(outputSettings: self.configuration.audioSettings, forMediaType: .audio) else {
                return
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: self.configuration.audioSettings)
            input.expectsMediaDataInRealTime = true
            guard self.assetWriter.canAdd(input) else {
                return
            }
            audioInput = input
        }

        self.assetWriter.add(videoInput)
        self.videoInput = videoInput
        if let audioInput {
            self.assetWriter.add(audioInput)
            self.audioInput = audioInput
        }

        Logger.shared.log("VideoRecorder", "Preflight added inputs, starting writing")
        if !self.assetWriter.startWriting() {
            self.failTerminally(error: self.assetWriter.error.flatMap { RecorderError.avError($0) } ?? .generic)
        }
    }
    
    public func markPositionChange(position: Camera.Position, time: CMTime? = nil) {
        self.queue.async {
            guard self.recordingStartSampleTime.isValid || time != nil else {
                return
            }
            if let time {
                self.positionChangeTimestamps.append((position, time))
            } else {
                let currentTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                let delta = currentTime - self.recordingStartSampleTime
                self.positionChangeTimestamps.append((position, delta))
            }
        }
    }
    
    
    private var previousPresentationTime: Double?
    private var previousAppendTime: Double?
    
    public func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        #if compiler(>=6.0) // Xcode 16
        nonisolated(unsafe) let sampleBuffer = sampleBuffer
        #endif
        
        self.queue.async {
            guard self.hasError() == nil && !self.stopped else {
                return
            }
            
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer), CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video else {
                return
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            var failed = false
            if self.videoInput == nil {
                Logger.shared.log("VideoRecorder", "Try adding video input")
                
                let videoSettings = self.configuration.videoSettings
                if self.assetWriter.canApply(outputSettings: videoSettings, forMediaType: .video) {
                    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: formatDescription)
                    videoInput.expectsMediaDataInRealTime = true
                    videoInput.transform = self.videoTransform
                    if self.assetWriter.canAdd(videoInput) {
                        self.assetWriter.add(videoInput)
                        self.videoInput = videoInput
                        
                        Logger.shared.log("VideoRecorder", "Successfully added video input")
                    } else {
                        failed = true
                    }
                } else {
                    failed = true
                }
            }
            
            if failed {
                Logger.shared.log("VideoRecorder", "Failed to append video buffer")
                return
            }
            
            if self.assetWriter.status == .unknown {
                if sampleBuffer.presentationTimestamp < self.recordingStartSampleTime {
                    return
                }
                if self.videoInput != nil && (self.audioInput != nil || !self.configuration.hasAudio) {
                    print("startWriting")
                    let start = CACurrentMediaTime()
                    if !self.assetWriter.startWriting() {
                        if let error = self.assetWriter.error {
                            self.failTerminally(error: .avError(error))
                        }
                    }
                    print("started In \(CACurrentMediaTime() - start)")
                    return
                }
            } else if self.assetWriter.status == .writing && !self.startedSession {
                // Preflight bypasses the lazy path's timestamp check, so reject pre-press frames here.
                if presentationTime < self.recordingStartSampleTime {
                    return
                }
                print("Started session at \(presentationTime)")
                self.assetWriter.startSession(atSourceTime: presentationTime)
                self.recordingStartSampleTime = presentationTime
                self.lastVideoSampleTime = presentationTime
                self.startedSession = true
            }
            
            if self.recordingStartSampleTime == .invalid || sampleBuffer.presentationTimestamp < self.recordingStartSampleTime {
                return
            }
           
            if self.assetWriter.status == .writing && self.startedSession {
                if self.recordingStopSampleTime != .invalid && sampleBuffer.presentationTimestamp > self.recordingStopSampleTime {
                    self.hasAllVideoBuffers = true
                    self.maybeFinish()
                    return
                }

                if let videoInput = self.videoInput {
                    let appendSignpostID = OSSignpostID(log: RoundVideoSignpost.log)
                    os_signpost(.begin, log: RoundVideoSignpost.log, name: "writerAppendVideo", signpostID: appendSignpostID)
                    let busyWaitSignpostID = OSSignpostID(log: RoundVideoSignpost.log)
                    os_signpost(.begin, log: RoundVideoSignpost.log, name: "writerBusyWait", signpostID: busyWaitSignpostID)
                    let writerReady = self.waitUntilReady(videoInput)
                    os_signpost(.end, log: RoundVideoSignpost.log, name: "writerBusyWait", signpostID: busyWaitSignpostID)
                    if !writerReady {
                        os_signpost(.end, log: RoundVideoSignpost.log, name: "writerAppendVideo", signpostID: appendSignpostID)
                        self.failTerminally(error: self.assetWriter.error.flatMap { RecorderError.avError($0) } ?? .generic)
                        return
                    }

                    let time = CACurrentMediaTime()
//                    if let previousPresentationTime = self.previousPresentationTime, let previousAppendTime = self.previousAppendTime {
//                        print("appending \(presentationTime.seconds) (\(presentationTime.seconds - previousPresentationTime) ) on \(time) (\(time - previousAppendTime)")
//                    }
                    self.previousPresentationTime = presentationTime.seconds
                    self.previousAppendTime = time
                    
                    if videoInput.append(sampleBuffer) {
                        if !self.didAppendFirstVideoFrame {
                            self.didAppendFirstVideoFrame = true
                            os_signpost(.event, log: RoundVideoSignpost.log, name: "firstVideoFrameAppended")
                        }
                        self.lastVideoSampleTime = presentationTime
                        let startTime = self.recordingStartSampleTime
                        let duration = presentationTime - startTime
                        let _ = self._duration.modify { _ in return duration }
                    }
                    os_signpost(.end, log: RoundVideoSignpost.log, name: "writerAppendVideo", signpostID: appendSignpostID)

                    if !self.savedTransitionImage, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        self.savedTransitionImage = true
                        Queue.concurrentBackgroundQueue().async {
                            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                            if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                                var orientation: UIImage.Orientation = .right
                                if self.orientation == .landscapeLeft {
                                    orientation = .down
                                } else if self.orientation == .landscapeRight {
                                    orientation = .up
                                } else if self.orientation == .portraitUpsideDown {
                                    orientation = .left
                                }
                                Queue.mainQueue().async {
                                    self.transitionImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
                                }
                            } else {
                                self.savedTransitionImage = false
                            }
                        }
                    }
                    
                    if !self.tryAppendingPendingAudioBuffers() {
                        self.failTerminally(error: .generic)
                    }
                }
            }
        }
    }
    
    public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        #if compiler(>=6.0) // Xcode 16
        nonisolated(unsafe) let sampleBuffer = sampleBuffer
        #endif
        
        self.queue.async {
            guard self.hasError() == nil && !self.stopped else {
                return
            }
            
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer), CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio else {
                return
            }
            
            var failed = false
            if self.audioInput == nil {
                Logger.shared.log("VideoRecorder", "Try adding audio input")
                
                var audioSettings = self.configuration.audioSettings
                if let currentAudioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                    audioSettings[AVSampleRateKey] = currentAudioStreamBasicDescription.pointee.mSampleRate
                    audioSettings[AVNumberOfChannelsKey] = currentAudioStreamBasicDescription.pointee.mChannelsPerFrame
                }
                
                var audioChannelLayoutSize: Int = 0
                let currentChannelLayout = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &audioChannelLayoutSize)
                let currentChannelLayoutData: Data
                if let currentChannelLayout = currentChannelLayout, audioChannelLayoutSize > 0 {
                    currentChannelLayoutData = Data(bytes: currentChannelLayout, count: audioChannelLayoutSize)
                } else {
                    currentChannelLayoutData = Data()
                }
                audioSettings[AVChannelLayoutKey] = currentChannelLayoutData
                
                if self.assetWriter.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: formatDescription)
                    audioInput.expectsMediaDataInRealTime = true
                    if self.assetWriter.canAdd(audioInput) {
                        self.assetWriter.add(audioInput)
                        self.audioInput = audioInput
                        
                        Logger.shared.log("VideoRecorder", "Successfully added audio input")
                    } else {
                        failed = true
                    }
                } else {
                    failed = true
                }
            }

            if failed {
                Logger.shared.log("VideoRecorder", "Failed to append audio buffer")
                return
            }
                                    
            if self.recordingStartSampleTime != .invalid {
                if sampleBuffer.presentationTimestamp < self.recordingStartSampleTime {
                    return
                }
                if self.recordingStopSampleTime != .invalid && sampleBuffer.presentationTimestamp > self.recordingStopSampleTime {
                    self.hasAllAudioBuffers = true
                    self.maybeFinish()
                    return
                }
                var result = false
                if self.tryAppendingPendingAudioBuffers() {
                    if self.tryAppendingAudioSampleBuffer(sampleBuffer) {
                        result = true
                    }
                }
                if !result {
                    self.failTerminally(error: .generic)
                }
            }
        }
    }
    
    public func cancelRecording(completion: @escaping () -> Void) {
        self.queue.async {
            if self.stopped {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }
            let _ = self._stopped.modify { _ in return true }
            // Prevent a later writer callback from completing the cancelled recording.
            self.didComplete = true
            self.pendingAudioSampleBuffers = []
            if self.assetWriter.status == .writing {
                self.assetWriter.cancelWriting()
            }
            let fileManager = FileManager()
            try? fileManager.removeItem(at: self.url)
            DispatchQueue.main.async {
                completion()
            }
        }
    }
    
    public var isRecording: Bool {
        return !self.stopped
    }
    
    // Route external pipeline failures through the same terminal path.
    public func fail() {
        self.queue.async {
            self.failTerminally(error: .generic)
        }
    }

    public func stopRecording() {
        self.queue.async {
            var stopTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            if self.recordingStartSampleTime.isValid {
                if (stopTime - self.recordingStartSampleTime).seconds < 1.5 {
                    stopTime = self.recordingStartSampleTime + CMTime(seconds: 1.5, preferredTimescale: self.recordingStartSampleTime.timescale)
                }
            }
            
            self.recordingStopSampleTime = stopTime
        }
    }
    
    private func maybeFinish() {
        dispatchPrecondition(condition: .onQueue(self.queue))
        guard self.hasAllVideoBuffers && (!self.configuration.hasAudio || self.hasAllAudioBuffers) && !self.stopped else {
            return
        }
        let _ = self._stopped.modify { _ in return true }
        self.finish()
    }
    
    private func finish() {
        dispatchPrecondition(condition: .onQueue(self.queue))
        if self.recordingStopSampleTime == .invalid {
            self.completeOnce(success: false)
            return
        }

        if let _ = self.error.with({ $0 }) {
            self.completeOnce(success: false)
            return
        }

        if !self.tryAppendingPendingAudioBuffers() {
            self.completeOnce(success: false)
            return
        }

        if self.assetWriter.status == .writing {
            let finishSignpostID = OSSignpostID(log: RoundVideoSignpost.log)
            os_signpost(.begin, log: RoundVideoSignpost.log, name: "finishWriting", signpostID: finishSignpostID)
            self.assetWriter.finishWriting {
                os_signpost(.end, log: RoundVideoSignpost.log, name: "finishWriting", signpostID: finishSignpostID)
                let success = self.assetWriter.error == nil
                self.queue.async {
                    self.completeOnce(success: success)
                }
            }
        } else {
            self.completeOnce(success: false)
        }
    }
    
    private func tryAppendingPendingAudioBuffers() -> Bool {
        dispatchPrecondition(condition: .onQueue(self.queue))
        guard self.pendingAudioSampleBuffers.count > 0 else {
            return true
        }
        
        var result = true
        let (sampleBuffersToAppend, pendingSampleBuffers) = self.pendingAudioSampleBuffers.stableGroup(using: { $0.endTime <= self.lastVideoSampleTime })
        for sampleBuffer in sampleBuffersToAppend {
            if !self.internalAppendAudioSampleBuffer(sampleBuffer) {
                result = false
                break
            }
        }
        self.pendingAudioSampleBuffers = pendingSampleBuffers
        return result
    }
    
    private func tryAppendingAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        dispatchPrecondition(condition: .onQueue(self.queue))
        
        var result = true
        if sampleBuffer.endTime > self.lastVideoSampleTime {
            self.pendingAudioSampleBuffers.append(sampleBuffer)
        } else {
            result = self.internalAppendAudioSampleBuffer(sampleBuffer)
        }
        return result
    }
    
    private func internalAppendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if self.startedSession, let audioInput = self.audioInput {
            if !self.waitUntilReady(audioInput) {
                return false
            }

            if !audioInput.append(sampleBuffer) {
                if let _ = self.assetWriter.error {
                    return false
                }
            }
        } else {

        }
        return true
    }
    
}

private extension Sequence {
    func stableGroup(using predicate: (Element) throws -> Bool) rethrows -> ([Element], [Element]) {
        var trueGroup: [Element] = []
        var falseGroup: [Element] = []
        for element in self {
            if try predicate(element) {
                trueGroup.append(element)
            } else {
                falseGroup.append(element)
            }
        }
        return (trueGroup, falseGroup)
    }
}

public final class VideoRecorder {
    var duration: Double? {
        return self.impl.duration.seconds
    }
    
    enum Result {
        enum Error {
            case generic
        }
        
        case success(UIImage?, Double, [(Camera.Position, Double)])
        case initError(Error)
        case writeError(Error)
        case finishError(Error)
    }
    
    struct Configuration {
        var videoSettings: [String: Any]
        var audioSettings: [String: Any]
        // Selects eager writer setup and bounded backpressure waits.
        var optimizeRoundVideo: Bool

        init(videoSettings: [String: Any], audioSettings: [String: Any], optimizeRoundVideo: Bool = false) {
            self.videoSettings = videoSettings
            self.audioSettings = audioSettings
            self.optimizeRoundVideo = optimizeRoundVideo
        }

        var hasAudio: Bool {
            return !self.audioSettings.isEmpty
        }
    }
    
    private let impl: VideoRecorderImpl
    fileprivate let configuration: Configuration
    fileprivate let fileUrl: URL
    private let completion: (Result) -> Void
    
    public var isRecording: Bool {
        return self.impl.isRecording
    }
    
    init?(configuration: Configuration, ciContext: CIContext, orientation: AVCaptureVideoOrientation, fileUrl: URL, completion: @escaping (Result) -> Void) {
        self.configuration = configuration
        self.fileUrl = fileUrl
        self.completion = completion
        
        guard let impl = VideoRecorderImpl(configuration: configuration, ciContext: ciContext, orientation: orientation, fileUrl: fileUrl) else {
            completion(.initError(.generic))
            return nil
        }
        self.impl = impl
        impl.completion = { [weak self] result, transitionImage, positionChangeTimestamps in
            if let self {
                let duration = self.duration ?? 0.0
                if result {
                    var timestamps: [(Camera.Position, Double)] = []
                    if let positionChangeTimestamps {
                        for (position, time) in positionChangeTimestamps {
                            timestamps.append((position, time.seconds))
                        }
                    }
                    self.completion(.success(transitionImage, duration, timestamps))
                } else {
                    self.completion(.finishError(.generic))
                }
            }
        }
    }
    
    func start() {
        self.impl.start()
    }
    
    func stop() {
        self.impl.stopRecording()
    }

    func fail() {
        self.impl.fail()
    }
        
    func markPositionChange(position: Camera.Position, time: CMTime? = nil) {
        self.impl.markPositionChange(position: position, time: time)
    }
        
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescriptor = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        let type = CMFormatDescriptionGetMediaType(formatDescriptor)
        if type == kCMMediaType_Video {
            self.impl.appendVideoSampleBuffer(sampleBuffer)
        } else if type == kCMMediaType_Audio {
            if self.configuration.hasAudio {
                self.impl.appendAudioSampleBuffer(sampleBuffer)
            }
        }
    }
    
    var transitionImage: UIImage? {
        return self.impl.transitionImage
    }
}
