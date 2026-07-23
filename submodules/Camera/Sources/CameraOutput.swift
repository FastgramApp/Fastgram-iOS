import Foundation
import os
import AVFoundation
import UIKit
import Display
import SwiftSignalKit
import CoreImage
import Vision
import VideoToolbox
import TelegramCore

public enum VideoCaptureResult: Equatable {
    public struct Result {
        public let path: String
        public let thumbnail: UIImage
        public let isMirrored: Bool
        public let dimensions: CGSize
    }
    
    case finished(main: Result, additional: Result?, duration: Double, positionChangeTimestamps: [(Bool, Double)], captureTimestamp: Double)
    case failed
    
    public static func == (lhs: VideoCaptureResult, rhs: VideoCaptureResult) -> Bool {
        switch lhs {
        case .failed:
            if case .failed = rhs {
                return true
            } else {
                return false
            }
        case let .finished(_, _, lhsDuration, lhsChangeTimestamps, lhsTimestamp):
            if case let .finished(_, _, rhsDuration, rhsChangeTimestamps, rhsTimestamp) = rhs, lhsDuration == rhsDuration, lhsTimestamp == rhsTimestamp {
                if lhsChangeTimestamps.count != rhsChangeTimestamps.count {
                    return false
                }
                return true
            } else {
                return false
            }
        }
    }
}

public struct CameraCode: Equatable {
    public enum CodeType {
        case qr
    }
    
    public let type: CodeType
    public let message: String
    public let corners: [CGPoint]
    
    public init(type: CameraCode.CodeType, message: String, corners: [CGPoint]) {
        self.type = type
        self.message = message
        self.corners = corners
    }
    
    public var boundingBox: CGRect {
        let x = self.corners.map { $0.x }
        let y = self.corners.map { $0.y }
        if let minX = x.min(), let minY = y.min(), let maxX = x.max(), let maxY = y.max() {
            return CGRect(x: minX, y: minY, width: abs(maxX - minX), height: abs(maxY - minY))
        }
        return CGRect.null
    }
    
    public var rotation: CGFloat {
        guard self.corners.count == 4 else {
            return 0.0
        }
        
        let topLeft = self.corners[1]
        let topRight = self.corners[2]
        
        let dx = topRight.x - topLeft.x
        let dy = topRight.y - topLeft.y
        
        return atan2(dy, dx) - .pi / 2.0
    }

    public static func == (lhs: CameraCode, rhs: CameraCode) -> Bool {
        if lhs.type != rhs.type {
            return false
        }
        if lhs.message != rhs.message {
            return false
        }
        if lhs.corners != rhs.corners {
            return false
        }
        return true
    }
}

final class CameraOutput: NSObject {
    private struct RoundVideoFormatDescriptionCacheEntry {
        let sourceFormatDescription: CMFormatDescription
        let outputFormatDescription: CMFormatDescription
    }

    let exclusive: Bool
    let ciContext: CIContext
    let colorSpace: CGColorSpace
    let isVideoMessage: Bool
    let isAdditionalOutput: Bool

    var hasAudio: Bool = false

    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    let metadataOutput = AVCaptureMetadataOutput()

    private var photoConnection: AVCaptureConnection?
    private var videoConnection: AVCaptureConnection?
    private var previewConnection: AVCaptureConnection?

    private var roundVideoFilter: CameraRoundLegacyVideoFilter?
    private var roundVideoMetalCompositor: RoundVideoMetalCompositor?
    private let semaphore = DispatchSemaphore(value: 1)
    private var roundVideoFormatDescriptionCache: [RoundVideoFormatDescriptionCacheEntry] = []

    // Both camera outputs share this queue because they mutate one recording state.
    private let videoQueue: DispatchQueue
    private let audioQueue = DispatchQueue(label: "")

    private let metadataQueue = DispatchQueue(label: "")

    private var photoCaptureRequests = Atomic<[Int64: PhotoCaptureContext]>(value: [:])
    private var videoRecorder: VideoRecorder?
    private var benchmarkRunSignpostID: OSSignpostID?

    private var captureOrientation: AVCaptureVideoOrientation = .portrait

    var processSampleBuffer: ((CMSampleBuffer, CVImageBuffer, AVCaptureConnection) -> Void)?
    var processAudioBuffer: ((CMSampleBuffer) -> Void)?
    var processCodes: (([CameraCode]) -> Void)?

    init(exclusive: Bool, ciContext: CIContext, colorSpace: CGColorSpace, use32BGRA: Bool = false, additional: Bool = false, sharedVideoQueue: DispatchQueue? = nil) {
        self.exclusive = exclusive
        self.ciContext = ciContext
        self.colorSpace = colorSpace
        self.isVideoMessage = use32BGRA
        self.isAdditionalOutput = additional
        self.videoQueue = sharedVideoQueue ?? DispatchQueue(label: "", qos: .userInitiated)

        super.init()
        
        if #available(iOS 13.0, *) {
            self.photoOutput.maxPhotoQualityPrioritization = .balanced
        }
        
        self.videoOutput.alwaysDiscardsLateVideoFrames = false
        // The session switches this to NV12 only after the Metal pipeline is ready.
        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: use32BGRA ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as [String : Any]
    }

    private(set) var useMetalRoundVideoPipeline = false
    private var didConfigureRoundVideoPipeline = false
    private var lastColorVerifiedIsFront: Bool?
    // Double optional distinguishes "no frame yet" from an untagged source.
    private var roundVideoCanonicalColorMatrix: String??

    // This choice is sticky because a writer track cannot change format mid-recording.
    // Only the master output owns the compositor.
    func configureRoundVideoPipeline(v2: Bool) -> Bool {
        guard self.isVideoMessage else {
            return false
        }
        if self.didConfigureRoundVideoPipeline {
            return self.useMetalRoundVideoPipeline
        }
        self.didConfigureRoundVideoPipeline = true

        var effectiveV2 = v2
        if effectiveV2 && !self.isAdditionalOutput {
            self.roundVideoMetalCompositor = RoundVideoMetalCompositor()
            if self.roundVideoMetalCompositor == nil {
                effectiveV2 = false
            }
        }
        self.useMetalRoundVideoPipeline = effectiveV2

        let pixelFormat: OSType = effectiveV2 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: pixelFormat] as [String: Any]

        return effectiveV2
    }
    
    deinit {
        self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
        self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
    }
    
    func configure(for session: CameraSession, device: CameraDevice, input: CameraInput, previewView: CameraSimplePreviewView?, audio: Bool, photo: Bool, metadata: Bool) {
        if session.session.canAddOutput(self.videoOutput) {
            if session.hasMultiCam {
                session.session.addOutputWithNoConnections(self.videoOutput)
            } else {
                session.session.addOutput(self.videoOutput)
            }
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
        } else {
            Logger.shared.log("Camera", "Can't add video output")
        }
        if audio {
            self.hasAudio = true
            if session.session.canAddOutput(self.audioOutput) {
                session.session.addOutput(self.audioOutput)
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
            } else {
                Logger.shared.log("Camera", "Can't add audio output")
            }
        }
        if photo, session.session.canAddOutput(self.photoOutput) {
            if session.hasMultiCam {
                session.session.addOutputWithNoConnections(self.photoOutput)
            } else {
                session.session.addOutput(self.photoOutput)
            }
        } else {
            Logger.shared.log("Camera", "Can't add photo output")
        }
        if metadata, session.session.canAddOutput(self.metadataOutput) {
            session.session.addOutput(self.metadataOutput)
            
            self.metadataOutput.setMetadataObjectsDelegate(self, queue: self.metadataQueue)
            if self.metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                self.metadataOutput.metadataObjectTypes = [.qr]
            }
        }
        
        if #available(iOS 13.0, *), session.hasMultiCam {
            if let device = device.videoDevice, let ports = input.videoInput?.ports(for: AVMediaType.video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position), let firstPort = ports.first {
                if let previewView {
                    let previewConnection = AVCaptureConnection(inputPort: firstPort, videoPreviewLayer: previewView.videoPreviewLayer)
                    if session.session.canAddConnection(previewConnection) {
                        session.session.addConnection(previewConnection)
                        self.previewConnection = previewConnection
                    } else {
                        Logger.shared.log("Camera", "Can't add preview connection")
                    }
                }
                
                let videoConnection = AVCaptureConnection(inputPorts: ports, output: self.videoOutput)
                if session.session.canAddConnection(videoConnection) {
                    session.session.addConnection(videoConnection)
                    self.videoConnection = videoConnection
                } else {
                    Logger.shared.log("Camera", "Can't add video connection")
                }

                if photo {
                    let photoConnection = AVCaptureConnection(inputPorts: ports, output: self.photoOutput)
                    if session.session.canAddConnection(photoConnection) {
                        session.session.addConnection(photoConnection)
                        self.photoConnection = photoConnection
                    }
                }
            } else {
                Logger.shared.log("Camera", "Can't get video port")
            }
        }
    }
        
    func invalidate(for session: CameraSession, switchAudio: Bool = true) {
        if #available(iOS 13.0, *) {
            if let previewConnection = self.previewConnection {
                if session.session.connections.contains(where: { $0 === previewConnection }) {
                    session.session.removeConnection(previewConnection)
                }
                self.previewConnection = nil
            }
            if let videoConnection = self.videoConnection {
                if session.session.connections.contains(where: { $0 === videoConnection }) {
                    session.session.removeConnection(videoConnection)
                }
                self.videoConnection = nil
            }
            if let photoConnection = self.photoConnection {
                if session.session.connections.contains(where: { $0 === photoConnection }) {
                    session.session.removeConnection(photoConnection)
                }
                self.photoConnection = nil
            }
        }
        if session.session.outputs.contains(where: { $0 === self.videoOutput }) {
            session.session.removeOutput(self.videoOutput)
        }
        if switchAudio, session.session.outputs.contains(where: { $0 === self.audioOutput }) {
            session.session.removeOutput(self.audioOutput)
        }
        if session.session.outputs.contains(where: { $0 === self.photoOutput }) {
            session.session.removeOutput(self.photoOutput)
        }
        if session.session.outputs.contains(where: { $0 === self.metadataOutput }) {
            session.session.removeOutput(self.metadataOutput)
        }
    }
    
    func configureVideoStabilization() {
        if let videoDataOutputConnection = self.videoOutput.connection(with: .video) {
            if videoDataOutputConnection.isVideoStabilizationSupported {
                videoDataOutputConnection.preferredVideoStabilizationMode = .standard
//                videoDataOutputConnection.preferredVideoStabilizationMode = self.isVideoMessage ? .cinematic : .standard
            }
        }
    }
    
    var isFlashActive: Signal<Bool, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                return EmptyDisposable
            }
            subscriber.putNext(self.photoOutput.isFlashScene)
            let observer = self.photoOutput.observe(\.isFlashScene, options: [.new], changeHandler: { output, _ in
                subscriber.putNext(output.isFlashScene)
            })
            return ActionDisposable {
                observer.invalidate()
            }
        }
        |> distinctUntilChanged
    }
    
    func takePhoto(orientation: AVCaptureVideoOrientation, flashMode: AVCaptureDevice.FlashMode) -> Signal<PhotoCaptureResult, NoError> {
        var mirror = false
        if let connection = self.photoOutput.connection(with: .video) {
            connection.videoOrientation = orientation
            
            if #available(iOS 13.0, *) {
                mirror = connection.inputPorts.first?.sourceDevicePosition == .front
            }
        }
        
        let settings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        settings.flashMode = mirror ? .off : flashMode
        if let previewPhotoPixelFormatType = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPhotoPixelFormatType]
        }
        if #available(iOS 13.0, *) {
            if self.photoOutput.maxPhotoQualityPrioritization != .speed  {
                settings.photoQualityPrioritization = .balanced
            } else {
                settings.photoQualityPrioritization = .speed
            }
        }
        
#if targetEnvironment(simulator)
        let image = generateImage(CGSize(width: 1080, height: 1920), opaque: true, scale: 1.0, rotatedContext: { size, context in
            let colors: [UIColor] = [UIColor(rgb: 0xff00ff), UIColor(rgb: 0xff0000), UIColor(rgb: 0x00ffff), UIColor(rgb: 0x00ff00)]
            if let randomColor = colors.randomElement() {
                context.setFillColor(randomColor.cgColor)
            }
            context.fill(CGRect(origin: .zero, size: size))
        })!
        return .single(.began)
        |> then(
            .single(.finished(image, nil, CACurrentMediaTime())) |> delay(0.5, queue: Queue.concurrentDefaultQueue())
        )
#else
        let uniqueId = settings.uniqueID
        let photoCapture = PhotoCaptureContext(ciContext: self.ciContext, settings: settings, orientation: orientation, mirror: mirror)
        let _ = self.photoCaptureRequests.modify { dict in
            var dict = dict
            dict[uniqueId] = photoCapture
            return dict
        }
        self.photoOutput.capturePhoto(with: settings, delegate: photoCapture)
        
        return photoCapture.signal
        |> afterDisposed { [weak self] in
            let _ = self?.photoCaptureRequests.modify { dict in
                var dict = dict
                dict.removeValue(forKey: uniqueId)
                return dict
            }
        }
#endif
    }
    
    var isRecording: Bool {
        return self.videoRecorder != nil
    }
    
    enum RecorderMode {
        case `default`
        case roundVideo
        case dualCamera
    }
    
    private var currentMode: RecorderMode = .default
    private var recordingCompletionPromise: Promise<VideoCaptureResult>?
    func startRecording(mode: RecorderMode, position: Camera.Position? = nil, orientation: AVCaptureVideoOrientation, additionalOutput: CameraOutput? = nil) -> Signal<CameraRecordingData, CameraRecordingError> {
        guard self.videoRecorder == nil, self.recordingCompletionPromise == nil else {
            return .complete()
        }
        
        Logger.shared.log("CameraOutput", "startRecording")
        
        self.currentMode = mode
        self.lastSampleTimestamp = nil
        self.captureOrientation = orientation
        
        var orientation = orientation
        let dimensions: CGSize
        let videoSettings: [String: Any]
        if case .roundVideo = mode {
            dimensions = videoMessageDimensions.cgSize
            orientation = .landscapeRight
            
            let compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: 1000 * 1000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC
            ]
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoCompressionPropertiesKey: compressionProperties,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height)
            ]
        } else {
            let codecType: AVVideoCodecType = hasHEVCHardwareEncoder ? .hevc : .h264
            if orientation == .landscapeLeft || orientation == .landscapeRight {
                dimensions = CGSize(width: 1920, height: 1080)
            } else {
                dimensions = CGSize(width: 1080, height: 1920)
            }
            guard let settings = self.videoOutput.recommendedVideoSettings(forVideoCodecType: codecType, assetWriterOutputFileType: .mp4) else {
                return .complete()
            }
            videoSettings = settings
        }
        
        let audioSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) ?? [:]
        if self.hasAudio && audioSettings.isEmpty {
            Logger.shared.log("Camera", "Audio settings are empty on recording start")
            return .fail(.audioInitializationError)
        }
        
        let outputFileName = NSUUID().uuidString
        let outputFilePath = NSTemporaryDirectory() + outputFileName + ".mp4"
        let outputFileURL = URL(fileURLWithPath: outputFilePath)
        
        var optimizeRoundVideo = false
        if case .roundVideo = mode {
            optimizeRoundVideo = Camera.roundVideoOptimizationsEnabled
        }
        let recordingCompletionPromise = Promise<VideoCaptureResult>()
        let videoRecorder = VideoRecorder(
            configuration: VideoRecorder.Configuration(videoSettings: videoSettings, audioSettings: audioSettings, optimizeRoundVideo: optimizeRoundVideo),
            ciContext: self.ciContext,
            orientation: orientation,
            fileUrl: outputFileURL,
            completion: { [weak self] result in
                guard let self else {
                    return
                }
                if let signpostID = self.benchmarkRunSignpostID {
                    os_signpost(.end, log: RoundVideoSignpost.log, name: "benchmarkRun", signpostID: signpostID)
                    self.benchmarkRunSignpostID = nil
                }
                let captureResult: VideoCaptureResult
                if case let .success(transitionImage, duration, positionChangeTimestamps) = result {
                    captureResult = .finished(
                        main: VideoCaptureResult.Result(
                            path: outputFilePath,
                            thumbnail: transitionImage ?? UIImage(),
                            isMirrored: false,
                            dimensions: dimensions
                        ),
                        additional: nil,
                        duration: duration,
                        positionChangeTimestamps: positionChangeTimestamps.map { ($0 == .front, $1) },
                        captureTimestamp: CACurrentMediaTime()
                    )
                } else {
                    captureResult = .failed
                }
                recordingCompletionPromise.set(.single(captureResult))
            }
        )
        guard let videoRecorder else {
            return .fail(.videoRecorderInitializationError)
        }
        self.recordingCompletionPromise = recordingCompletionPromise

        if case .roundVideo = mode {
            let signpostID = OSSignpostID(log: RoundVideoSignpost.log)
            self.benchmarkRunSignpostID = signpostID
            os_signpost(
                .begin,
                log: RoundVideoSignpost.log,
                name: "benchmarkRun",
                signpostID: signpostID,
                "mode=%{public}@ effectiveNV12=%d dropLateFrames=%d",
                Camera.roundVideoBenchmarkMode.name as NSString,
                self.useMetalRoundVideoPipeline ? 1 : 0,
                self.videoOutput.alwaysDiscardsLateVideoFrames ? 1 : 0
            )
            os_signpost(.event, log: RoundVideoSignpost.log, name: "recordingStartRequested")
        }
        
        videoRecorder.start()
        self.videoRecorder = videoRecorder
        
        if case .dualCamera = mode, let position {
            videoRecorder.markPositionChange(position: position, time: .zero)
        } else if case .roundVideo = mode {
            additionalOutput?.masterOutput = self
        }
        
        return Signal { subscriber in
            let timer = SwiftSignalKit.Timer(timeout: 0.09, repeat: true, completion: { [weak videoRecorder] in
                let recordingData = CameraRecordingData(duration: videoRecorder?.duration ?? 0.0, filePath: outputFilePath)
                subscriber.putNext(recordingData)
            }, queue: Queue.mainQueue())
            timer.start()
            
            return ActionDisposable {
                timer.invalidate()
            }
        }
    }
    
    func stopRecording() -> Signal<VideoCaptureResult, NoError> {
        guard let recordingCompletionPromise = self.recordingCompletionPromise else {
            return .complete()
        }
        if let videoRecorder = self.videoRecorder, videoRecorder.isRecording {
            videoRecorder.stop()
        }
        
        return recordingCompletionPromise.get()
        |> take(1)
        |> afterDisposed { [weak self] in
            guard let self, self.recordingCompletionPromise === recordingCompletionPromise else {
                return
            }
            self.videoRecorder = nil
            self.recordingCompletionPromise = nil
        }
    }
    
    var transitionImage: UIImage? {
        return self.videoRecorder?.transitionImage
    }
    
    private weak var masterOutput: CameraOutput?

    private var lastSampleTimestamp: CMTime?
    private var emittedFirstFrameSignpost = false
    
    private func roundVideoFormatDescription(for sourceFormatDescription: CMFormatDescription) -> CMFormatDescription? {
        if let entry = self.roundVideoFormatDescriptionCache.first(where: { CFEqual($0.sourceFormatDescription, sourceFormatDescription) }) {
            return entry.outputFormatDescription
        }

        guard let extensions = CMFormatDescriptionGetExtensions(sourceFormatDescription) as? [String: Any] else {
            return nil
        }

        let mediaSubType = CMFormatDescriptionGetMediaSubType(sourceFormatDescription)
        var updatedExtensions = extensions
        updatedExtensions["CVBytesPerRow"] = videoMessageDimensions.width * 4

        var outputFormatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: mediaSubType,
            width: videoMessageDimensions.width,
            height: videoMessageDimensions.height,
            extensions: updatedExtensions as CFDictionary,
            formatDescriptionOut: &outputFormatDescription
        )
        guard status == noErr, let outputFormatDescription else {
            return nil
        }

        self.roundVideoFormatDescriptionCache.append(RoundVideoFormatDescriptionCacheEntry(
            sourceFormatDescription: sourceFormatDescription,
            outputFormatDescription: outputFormatDescription
        ))
        if self.roundVideoFormatDescriptionCache.count > 4 {
            self.roundVideoFormatDescriptionCache.removeFirst(self.roundVideoFormatDescriptionCache.count - 4)
        }

        return outputFormatDescription
    }

    private var needsCrossfadeTransition = false
    private var crossfadeTransitionStart: Double = 0.0

    // Audio and video use different callback queues, so switch timing is lock-protected.
    private struct SwitchTimingState {
        var needsSwitchSampleOffset = false
        var lastAudioSampleTime: CMTime?
        var videoSwitchSampleTimeOffset: CMTime?
    }
    private let switchTimingLock = NSLock()
    private var switchTimingState = SwitchTimingState()
    private func withSwitchTiming<T>(_ f: (inout SwitchTimingState) -> T) -> T {
        self.switchTimingLock.lock()
        defer {
            self.switchTimingLock.unlock()
        }
        return f(&self.switchTimingState)
    }
    
    func processVideoRecording(_ sampleBuffer: CMSampleBuffer, fromAdditionalOutput: Bool) {
        guard let videoRecorder = self.videoRecorder, videoRecorder.isRecording else {
            return
        }
        guard let formatDescriptor = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        let type = CMFormatDescriptionGetMediaType(formatDescriptor)
        
        if case .roundVideo = self.currentMode, type == kCMMediaType_Video {
            let currentTimestamp = CACurrentMediaTime()
            let duration: Double = 0.2
            if !self.exclusive {
                var transitionFactor: CGFloat = 0.0
                if case .front = self.currentPosition {
                    transitionFactor = 1.0
                    if self.lastSwitchTimestamp > 0.0, currentTimestamp - self.lastSwitchTimestamp < duration {
                        transitionFactor = max(0.0, (currentTimestamp - self.lastSwitchTimestamp) / duration)
                    }
                } else {
                    transitionFactor = 0.0
                    if self.lastSwitchTimestamp > 0.0, currentTimestamp - self.lastSwitchTimestamp < duration {
                        transitionFactor = 1.0 - max(0.0, (currentTimestamp - self.lastSwitchTimestamp) / duration)
                    }
                }
                
                var shouldProcess = (transitionFactor == 1.0 && fromAdditionalOutput)
                    || (transitionFactor == 0.0 && !fromAdditionalOutput)
                    || (transitionFactor > 0.0 && transitionFactor < 1.0)
                var effectiveTransitionFactor = transitionFactor
                if self.useMetalRoundVideoPipeline {
                    // Metal hard-cuts at the midpoint to avoid interleaving both cameras.
                    let useAdditional = transitionFactor >= 0.5
                    shouldProcess = fromAdditionalOutput == useAdditional
                    effectiveTransitionFactor = useAdditional ? 1.0 : 0.0
                }
                if shouldProcess {
                    if let processedSampleBuffer = self.processRoundVideoSampleBuffer(sampleBuffer, additional: fromAdditionalOutput, transitionFactor: effectiveTransitionFactor) {
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(processedSampleBuffer)
                        // Reject equal timestamps while both streams overlap during a crossfade.
                        let shouldSkipTimestamp: Bool
                        if let lastSampleTimestamp = self.lastSampleTimestamp {
                            shouldSkipTimestamp = Camera.roundVideoOptimizationsEnabled ? lastSampleTimestamp >= presentationTime : lastSampleTimestamp > presentationTime
                        } else {
                            shouldSkipTimestamp = false
                        }
                        if shouldSkipTimestamp {

                        } else {
                            videoRecorder.appendSampleBuffer(processedSampleBuffer)
                            self.lastSampleTimestamp = presentationTime
                        }
                    }
                }
            } else {
                var additional = self.currentPosition == .front
                var transitionFactor = self.currentPosition == .front ? 1.0 : 0.0
                if self.lastSwitchTimestamp > 0.0 {
                    if self.needsCrossfadeTransition {
                        self.needsCrossfadeTransition = false
                        self.crossfadeTransitionStart = currentTimestamp + 0.03
                        self.withSwitchTiming { state in
                            state.needsSwitchSampleOffset = true
                        }
                    }
                    if self.crossfadeTransitionStart > 0.0, currentTimestamp - self.crossfadeTransitionStart < duration {
                        if case .front = self.currentPosition {
                            transitionFactor = max(0.0, (currentTimestamp - self.crossfadeTransitionStart) / duration)
                        } else {
                            transitionFactor = 1.0 - max(0.0, (currentTimestamp - self.crossfadeTransitionStart) / duration)
                        }
                    } else if currentTimestamp - self.lastSwitchTimestamp < 0.05 {
                        additional = !additional
                        transitionFactor = 1.0 - transitionFactor
                        self.needsCrossfadeTransition = true
                    }
                }
                if let processedSampleBuffer = self.processRoundVideoSampleBuffer(sampleBuffer, additional: additional, transitionFactor: transitionFactor) {
                    videoRecorder.appendSampleBuffer(processedSampleBuffer)
                } else if !self.useMetalRoundVideoPipeline {
                    // A raw full-resolution frame would establish the wrong Metal track format.
                    // Drop it instead; legacy keeps its existing fallback.
                    videoRecorder.appendSampleBuffer(sampleBuffer)
                }
            }
        } else {
            if type == kCMMediaType_Audio {
                self.withSwitchTiming { state in
                    if state.needsSwitchSampleOffset {
                        state.needsSwitchSampleOffset = false

                        if let lastAudioSampleTime = state.lastAudioSampleTime {
                            let videoSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            let offset = videoSampleTime - lastAudioSampleTime
                            if let current = state.videoSwitchSampleTimeOffset {
                                state.videoSwitchSampleTimeOffset = current + offset
                            } else {
                                state.videoSwitchSampleTimeOffset = offset
                            }
                            state.lastAudioSampleTime = nil
                        }
                    }

                    state.lastAudioSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) + CMSampleBufferGetDuration(sampleBuffer)
                }
            }
            videoRecorder.appendSampleBuffer(sampleBuffer)
        }
    }
    
    private func processRoundVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, additional: Bool, transitionFactor: CGFloat) -> CMSampleBuffer? {
        guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        self.semaphore.wait()
        defer {
            self.semaphore.signal()
        }

        // Metal hard-cuts, so transitionFactor applies only to legacy.
        if self.useMetalRoundVideoPipeline {
            guard let compositor = self.roundVideoMetalCompositor else {
                return nil
            }
            // One writer track requires stable color metadata across both cameras.
            // Terminate rather than silently mislabel samples.
            if self.lastColorVerifiedIsFront != additional {
                let matrix = CVBufferGetAttachment(videoPixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue() as? String
                if let canonicalMatrix = self.roundVideoCanonicalColorMatrix {
                    if matrix != canonicalMatrix {
                        os_signpost(.event, log: RoundVideoSignpost.log, name: "v2ColorRuntimeMismatch")
                        Logger.shared.log("Camera", "Round video V2: source YCbCr matrix \(matrix ?? "nil") disagrees with the recording's canonical \(canonicalMatrix ?? "nil"), terminating recording")
                        self.videoRecorder?.fail()
                        return nil
                    }
                } else {
                    self.roundVideoCanonicalColorMatrix = matrix
                }
                self.lastColorVerifiedIsFront = additional
            }
            let renderSignpostID = OSSignpostID(log: RoundVideoSignpost.log)
            os_signpost(.begin, log: RoundVideoSignpost.log, name: "filterRender", signpostID: renderSignpostID)
            let renderedPixelBuffer = compositor.render(pixelBuffer: videoPixelBuffer, isFront: additional)
            os_signpost(.end, log: RoundVideoSignpost.log, name: "filterRender", signpostID: renderSignpostID)
            // The compositor creates this from the first tagged output buffer.
            guard let metalPixelBuffer = renderedPixelBuffer, let metalFormatDescription = compositor.outputFormatDescription else {
                return nil
            }
            var metalTimingInfo: CMSampleTimingInfo = .invalid
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &metalTimingInfo)
            if let videoSwitchSampleTimeOffset = self.withSwitchTiming({ $0.videoSwitchSampleTimeOffset }) {
                metalTimingInfo.decodeTimeStamp = metalTimingInfo.decodeTimeStamp - videoSwitchSampleTimeOffset
                metalTimingInfo.presentationTimeStamp = metalTimingInfo.presentationTimeStamp - videoSwitchSampleTimeOffset
            }
            var metalSampleBuffer: CMSampleBuffer?
            let metalStatus = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: metalPixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: metalFormatDescription,
                sampleTiming: &metalTimingInfo,
                sampleBufferOut: &metalSampleBuffer
            )
            if metalStatus == noErr, let metalSampleBuffer {
                return metalSampleBuffer
            }
            return nil
        }

        guard let newFormatDescription = self.roundVideoFormatDescription(for: formatDescription) else {
            return nil
        }
        
        let filter: CameraRoundLegacyVideoFilter
        if let current = self.roundVideoFilter {
            filter = current
        } else {
            filter = CameraRoundLegacyVideoFilter(ciContext: self.ciContext, colorSpace: self.colorSpace, simple: self.exclusive)
            self.roundVideoFilter = filter
        }
        if !filter.isPrepared || filter.inputFormatDescription.map({ !CFEqual($0, newFormatDescription) }) ?? true {
            filter.prepare(with: newFormatDescription, outputRetainedBufferCountHint: 4)
        }

        let renderSignpostID = OSSignpostID(log: RoundVideoSignpost.log)
        os_signpost(.begin, log: RoundVideoSignpost.log, name: "filterRender", signpostID: renderSignpostID)
        let renderedPixelBuffer = filter.render(pixelBuffer: videoPixelBuffer, additional: additional, captureOrientation: self.captureOrientation, transitionFactor: transitionFactor)
        os_signpost(.end, log: RoundVideoSignpost.log, name: "filterRender", signpostID: renderSignpostID)
        guard let newPixelBuffer = renderedPixelBuffer else {
            return nil
        }
        
        var sampleTimingInfo: CMSampleTimingInfo = .invalid
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &sampleTimingInfo)

        if let videoSwitchSampleTimeOffset = self.withSwitchTiming({ $0.videoSwitchSampleTimeOffset }) {
            sampleTimingInfo.decodeTimeStamp = sampleTimingInfo.decodeTimeStamp - videoSwitchSampleTimeOffset
            sampleTimingInfo.presentationTimeStamp = sampleTimingInfo.presentationTimeStamp - videoSwitchSampleTimeOffset
        }
        
        var newSampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: newPixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: newFormatDescription,
            sampleTiming: &sampleTimingInfo,
            sampleBufferOut: &newSampleBuffer
        )
        
        if status == noErr, let newSampleBuffer {
            return newSampleBuffer
        }
        return nil
    }
    
    private var currentPosition: Camera.Position = .front
    private var lastSwitchTimestamp: Double = 0.0

    func markPositionChange(position: Camera.Position) {
        // Capture the timestamp before dispatch so queue latency does not shift the transition.
        let timestamp = CACurrentMediaTime()
        if case .roundVideo = self.currentMode {
            let positionName = position == .front ? "front" : "back"
            os_signpost(
                .event,
                log: RoundVideoSignpost.log,
                name: "cameraSwitch",
                "position=%{public}@",
                positionName as NSString
            )
        }
        if Camera.roundVideoOptimizationsEnabled {
            self.videoQueue.async { [weak self] in
                guard let self else {
                    return
                }
                self.currentPosition = position
                self.lastSwitchTimestamp = timestamp
            }
        } else {
            self.currentPosition = position
            self.lastSwitchTimestamp = timestamp
        }

        if let videoRecorder = self.videoRecorder {
            videoRecorder.markPositionChange(position: position)
        }
    }
}

extension CameraOutput: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
                        
        if let masterOutput = self.masterOutput {
            masterOutput.processVideoRecording(sampleBuffer, fromAdditionalOutput: true)
        } else {
            self.processVideoRecording(sampleBuffer, fromAdditionalOutput: false)
        }
        
        if let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            if self.isVideoMessage && !self.emittedFirstFrameSignpost {
                self.emittedFirstFrameSignpost = true
                if self.isAdditionalOutput {
                    os_signpost(.event, log: RoundVideoSignpost.log, name: "firstCaptureFrameAdditional")
                } else {
                    os_signpost(.event, log: RoundVideoSignpost.log, name: "firstCaptureFrameMain")
                }
            }
            self.processSampleBuffer?(sampleBuffer, videoPixelBuffer, connection)
        } else if sampleBuffer.type == kCMMediaType_Audio {
            self.processAudioBuffer?(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if self.isVideoMessage {
            os_signpost(.event, log: RoundVideoSignpost.log, name: "dropVideoFrame")
        }
        if #available(iOS 13.0, *) {
            Logger.shared.log("Camera", "Dropped sample buffer \(sampleBuffer.attachments)")
        }
    }
}

extension CameraOutput: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let codes: [CameraCode] = metadataObjects.filter { $0.type == .qr }.compactMap { object in
            if let object = object as? AVMetadataMachineReadableCodeObject, let stringValue = object.stringValue, !stringValue.isEmpty {
                #if targetEnvironment(simulator)
                return CameraCode(type: .qr, message: stringValue, corners: [CGPoint(), CGPoint(), CGPoint(), CGPoint()])
                #else
                return CameraCode(type: .qr, message: stringValue, corners: object.corners)
                #endif
            } else {
                return nil
            }
        }
        self.processCodes?(codes)
    }
}

private let hasHEVCHardwareEncoder: Bool = {
    let spec: [CFString: Any] = [:]
    var outID: CFString?
    var properties: CFDictionary?
    let result = VTCopySupportedPropertyDictionaryForEncoder(width: 1920, height: 1080, codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary, encoderIDOut: &outID, supportedPropertiesOut: &properties)
    if result == kVTCouldNotFindVideoEncoderErr {
        return false
    }
    return result == noErr
}()
