import Foundation
import os
import UIKit
import SwiftSignalKit
import AVFoundation
import CoreImage
import TelegramCore
import DeviceModel

final class CameraSession {
    private let singleSession: AVCaptureSession?
    private let multiSession: Any?
    
    let hasMultiCam: Bool
        
    init(forRoundVideo: Bool) {
        if #available(iOS 13.0, *), Camera.isDualCameraSupported(forRoundVideo: forRoundVideo) {
            self.multiSession = AVCaptureMultiCamSession()
            self.singleSession = nil
            self.hasMultiCam = true
        } else {
            self.singleSession = AVCaptureSession()
            self.multiSession = nil
            self.hasMultiCam = false
        }
        self.session.sessionPreset = .inputPriority
    }
    
    var session: AVCaptureSession {
        if #available(iOS 13.0, *), let multiSession = self.multiSession as? AVCaptureMultiCamSession {
            return multiSession
        } else if let session = self.singleSession {
            return session
        } else {
            fatalError()
        }
    }
    
    var supportsDualCam: Bool {
        return self.multiSession != nil
    }
}

final class CameraDeviceContext {
    private weak var session: CameraSession?
    private weak var previewView: CameraSimplePreviewView?
    
    private let exclusive: Bool
    private let additional: Bool
    private let isRoundVideo: Bool
    
    let device = CameraDevice()
    let input = CameraInput()
    let output: CameraOutput
        
    init(session: CameraSession, exclusive: Bool, additional: Bool, ciContext: CIContext, colorSpace: CGColorSpace, isRoundVideo: Bool = false, sharedVideoQueue: DispatchQueue? = nil) {
        self.session = session
        self.exclusive = exclusive
        self.additional = additional
        self.isRoundVideo = isRoundVideo
        self.output = CameraOutput(exclusive: exclusive, ciContext: ciContext, colorSpace: colorSpace, use32BGRA: isRoundVideo, additional: additional, sharedVideoQueue: sharedVideoQueue)
    }

    func configure(position: Camera.Position, previewView: CameraSimplePreviewView?, audio: Bool, photo: Bool, metadata: Bool, preferWide: Bool = false, preferLowerFramerate: Bool = false, switchAudio: Bool = true) {
        guard let session = self.session else {
            return
        }

        self.previewView = previewView

        self.device.configure(for: session, position: position, dual: !self.exclusive || self.additional, switchAudio: switchAudio)
        var fallbackDimensions: CMVideoDimensions?
        var useRoundVideoFormatSelector = false
        if self.isRoundVideo && !self.exclusive, case .r640x480 = Camera.roundVideoDualCaptureQuality {
            fallbackDimensions = self.defaultMaxDimensions(additional: self.additional, preferWide: preferWide)
            useRoundVideoFormatSelector = Camera.roundVideoOptimizationsEnabled
        }
        self.device.configureDeviceFormat(maxDimensions: self.maxDimensions(additional: self.additional, preferWide: preferWide), maxFramerate: self.preferredMaxFrameRate(useLower: preferLowerFramerate), requireMultiCamSupported: session.hasMultiCam, preferBinned: useRoundVideoFormatSelector, fallbackDimensions: fallbackDimensions)
        self.logCaptureFormat()
        self.input.configure(for: session, device: self.device, audio: audio && switchAudio)
        self.output.configure(for: session, device: self.device, input: self.input, previewView: previewView, audio: audio && switchAudio, photo: photo, metadata: metadata)
        
        self.output.configureVideoStabilization()
        
        self.device.resetZoom(neutral: self.exclusive || !self.additional)
    }
    
    func invalidate(switchAudio: Bool = true) {
        guard let session = self.session else {
            return
        }
        self.output.invalidate(for: session, switchAudio: switchAudio)
        self.input.invalidate(for: session, switchAudio: switchAudio)
    }
    
    private func defaultMaxDimensions(additional: Bool, preferWide: Bool) -> CMVideoDimensions {
        if additional || preferWide {
            return CMVideoDimensions(width: 1920, height: 1440)
        } else {
            return CMVideoDimensions(width: 1920, height: 1080)
        }
    }

    private func maxDimensions(additional: Bool, preferWide: Bool) -> CMVideoDimensions {
        if self.isRoundVideo && self.exclusive {
            return CMVideoDimensions(width: 640, height: 480)
        } else {
            if self.isRoundVideo {
                switch Camera.roundVideoDualCaptureQuality {
                case .current:
                    break
                case .r640x480:
                    return CMVideoDimensions(width: 640, height: 480)
                }
            }
            return self.defaultMaxDimensions(additional: additional, preferWide: preferWide)
        }
    }

    private func logCaptureFormat() {
        guard self.isRoundVideo, let format = self.device.videoDevice?.activeFormat else {
            return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let eventName: StaticString = self.additional ? "captureFormatAdditional" : "captureFormatMain"
        os_signpost(
            .event,
            log: RoundVideoSignpost.log,
            name: eventName,
            "mode=%{public}@ width=%d height=%d fov=%.2f binned=%d",
            Camera.roundVideoBenchmarkMode.name as NSString,
            dimensions.width,
            dimensions.height,
            Double(format.videoFieldOfView),
            format.isVideoBinned ? 1 : 0
        )
    }
    
    private func preferredMaxFrameRate(useLower: Bool) -> Double {
        if !self.exclusive || self.isRoundVideo || useLower {
            return 30.0
        }
        switch DeviceModel.current {
        case .iPhone15ProMax, .iPhone14ProMax, .iPhone13ProMax, .iPhone16ProMax, .iPhone17Pro, .iPhone17ProMax:
            return 30.0
        default:
            return 30.0
        }
    }
}

private final class CameraContext {
    private let queue: Queue
    private let session: CameraSession
    private let ciContext: CIContext
    private let colorSpace: CGColorSpace
    
    private var mainDeviceContext: CameraDeviceContext?
    private var additionalDeviceContext: CameraDeviceContext?

    private let initialConfiguration: Camera.Configuration
    private var invalidated = false
    
    private let detectedCodesPipe = ValuePipe<[CameraCode]>()
    private let audioLevelPipe = ValuePipe<Float>()
    fileprivate let modeChangePromise = ValuePromise<Camera.ModeChange>(.none)
    
    var mainVideoOutput: CameraVideoOutput?
    var additionalVideoOutput: CameraVideoOutput?
    
    var simplePreviewView: CameraSimplePreviewView?
    var secondaryPreviewView: CameraSimplePreviewView?
    
    private var lastSnapshotTimestamp: Double = CACurrentMediaTime()
    private var savedSnapshot = false
    private var lastAdditionalSnapshotTimestamp: Double = CACurrentMediaTime()
    private var savedAdditionalSnapshot = false
    
    private func savePreviewSnapshot(pixelBuffer: CVPixelBuffer, front: Bool) {
        Queue.concurrentDefaultQueue().async {
            var ciImage = CIImage(cvImageBuffer: pixelBuffer)
            // Blur a small proxy in optimized modes to avoid full-resolution placeholder work.
            if Camera.roundVideoOptimizationsEnabled {
                let downscale: CGFloat = 0.125
                ciImage = ciImage.transformed(by: CGAffineTransformMakeScale(downscale, downscale))
            }
            let size = ciImage.extent.size
            if front {
                var transform = CGAffineTransformMakeScale(1.0, -1.0)
                transform = CGAffineTransformTranslate(transform, 0.0, -size.height)
                ciImage = ciImage.transformed(by: transform)
            }
            let blurSigma: Double
            if Camera.roundVideoOptimizationsEnabled {
                blurSigma = Camera.isDualCameraSupported(forRoundVideo: true) ? 7.5 : 5.0
            } else {
                blurSigma = Camera.isDualCameraSupported(forRoundVideo: true) ? 60.0 : 40.0
            }
            ciImage = ciImage.clampedToExtent().applyingGaussianBlur(sigma: blurSigma).cropped(to: CGRect(origin: .zero, size: size))
            if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
                if front {
                    CameraSimplePreviewView.saveLastFrontImage(uiImage)
                } else {
                    CameraSimplePreviewView.saveLastBackImage(uiImage)
                }
            }
        }
    }
        
    init(queue: Queue, session: CameraSession, configuration: Camera.Configuration, metrics: Camera.Metrics, previewView: CameraSimplePreviewView?, secondaryPreviewView: CameraSimplePreviewView?) {
        Logger.shared.log("CameraContext", "Init")
        
        self.queue = queue
        self.session = session
        
        self.colorSpace = CGColorSpaceCreateDeviceRGB()
        self.ciContext = CIContext(options: [.workingColorSpace : self.colorSpace])
        
        self.initialConfiguration = configuration
        self.simplePreviewView = previewView
        self.secondaryPreviewView = secondaryPreviewView
        
        self.positionValue = configuration.position
        self._positionPromise = ValuePromise<Camera.Position>(configuration.position)
        
#if targetEnvironment(simulator)
#else
        self.setDualCameraEnabled(configuration.isDualEnabled, change: false)
#endif
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.sessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: self.session.session
        )
    }
    
    deinit {
        Logger.shared.log("CameraContext", "deinit")
        NotificationCenter.default.removeObserver(self)
    }
        
    private var isSessionRunning = false
    func startCapture() {
        guard !self.session.session.isRunning else {
            return
        }
        Logger.shared.log("CameraContext", "startCapture")
        if self.initialConfiguration.isRoundVideo {
            os_signpost(.event, log: RoundVideoSignpost.log, name: "captureSessionStart")
        }
        self.session.session.startRunning()
        self.isSessionRunning = self.session.session.isRunning
        self.logMultiCamCosts()
    }

    private func logMultiCamCosts() {
        if #available(iOS 13.0, *), let multiSession = self.session.session as? AVCaptureMultiCamSession {
            Logger.shared.log("Camera", "MultiCam hardwareCost: \(multiSession.hardwareCost), systemPressureCost: \(multiSession.systemPressureCost)")
            os_signpost(.event, log: RoundVideoSignpost.log, name: "multiCamCost", "hardwareCost=%.3f systemPressureCost=%.3f", multiSession.hardwareCost, multiSession.systemPressureCost)
        }
    }
    
    func stopCapture(invalidate: Bool = false) {
        Logger.shared.log("CameraContext", "stopCapture(invalidate: \(invalidate))")
        if invalidate {
            self.mainDeviceContext?.device.resetZoom()
            
            self.configure {
                self.mainDeviceContext?.invalidate()
            }
        }
        
        self.session.session.stopRunning()
        self.isSessionRunning = false
    }
    
    func focus(at point: CGPoint, autoFocus: Bool) {
        let focusMode: AVCaptureDevice.FocusMode
        let exposureMode: AVCaptureDevice.ExposureMode
        if autoFocus {
            focusMode = .continuousAutoFocus
            exposureMode = .continuousAutoExposure
        } else {
            focusMode = .autoFocus
            exposureMode = .autoExpose
        }
        self.mainDeviceContext?.device.setFocusPoint(point, focusMode: focusMode, exposureMode: exposureMode, monitorSubjectAreaChange: true)
    }
    
    func setFps(_ fps: Float64) {
        self.mainDeviceContext?.device.setFps(fps)
    }
    
    private var modeChange: Camera.ModeChange = .none {
        didSet {
            if oldValue != self.modeChange {
                self.modeChangePromise.set(self.modeChange)
            }
        }
    }
    
    private var _positionPromise: ValuePromise<Camera.Position>
    var position: Signal<Camera.Position, NoError> {
        return self._positionPromise.get()
    }
    
    private var positionValue: Camera.Position = .back
    func togglePosition() {
        guard let mainDeviceContext = self.mainDeviceContext else {
            return
        }
        if self.isDualCameraEnabled == true {
            let targetPosition: Camera.Position
            if case .back = self.positionValue {
                targetPosition = .front
            } else {
                targetPosition = .back
            }
            self.positionValue = targetPosition
            self._positionPromise.set(targetPosition)
            
            mainDeviceContext.output.markPositionChange(position: targetPosition)
        } else {
            self.session.session.stopRunning()
            self.configure {
                let isRoundVideo = self.initialConfiguration.isRoundVideo
                self.mainDeviceContext?.invalidate(switchAudio: !isRoundVideo)
                
                let targetPosition: Camera.Position
                if case .back = mainDeviceContext.device.position {
                    targetPosition = .front
                } else {
                    targetPosition = .back
                }
                self.positionValue = targetPosition
                self._positionPromise.set(targetPosition)
                self.modeChange = .position
                
                let preferWide = self.initialConfiguration.preferWide || isRoundVideo
                let preferLowerFramerate = self.initialConfiguration.preferLowerFramerate || isRoundVideo
                
                mainDeviceContext.configure(position: targetPosition, previewView: self.simplePreviewView, audio: self.initialConfiguration.audio, photo: self.initialConfiguration.photo, metadata: self.initialConfiguration.metadata, preferWide: preferWide, preferLowerFramerate: preferLowerFramerate, switchAudio: !isRoundVideo)
                if isRoundVideo {
                    mainDeviceContext.output.markPositionChange(position: targetPosition)
                }
                
                self.queue.after(0.5) {
                    self.modeChange = .none
                }
            }
            self.session.session.startRunning()
        }
    }
    
    public func setPosition(_ position: Camera.Position) {
        self.configure {
            self.mainDeviceContext?.invalidate()
            
            self._positionPromise.set(position)
            self.positionValue = position
            self.modeChange = .position
            
            let preferWide = self.initialConfiguration.preferWide || (self.positionValue == .front && self.initialConfiguration.isRoundVideo)
            let preferLowerFramerate = self.initialConfiguration.preferLowerFramerate || self.initialConfiguration.isRoundVideo
            
            self.mainDeviceContext?.configure(position: position, previewView: self.simplePreviewView, audio: self.initialConfiguration.audio, photo: self.initialConfiguration.photo, metadata: self.initialConfiguration.metadata, preferWide: preferWide, preferLowerFramerate: preferLowerFramerate)
                        
            self.queue.after(0.5) {
                self.modeChange = .none
            }
        }
    }
    
    private var micLevelPeak: Int16 = 0
    private var micLevelPeakCount = 0
    
    private var isDualCameraEnabled: Bool?
    public func setDualCameraEnabled(_ enabled: Bool, change: Bool = true) {
        guard enabled != self.isDualCameraEnabled else {
            return
        }
        self.isDualCameraEnabled = enabled
        
        if change {
            self.modeChange = .dualCamera
        }
        
        self.session.session.stopRunning()
        if enabled {
            self.configure {
                self.mainDeviceContext?.invalidate()
                // Serialize both cameras because they feed one compositor and writer.
                var sharedVideoQueue: DispatchQueue?
                if self.initialConfiguration.isRoundVideo && Camera.roundVideoOptimizationsEnabled {
                    sharedVideoQueue = DispatchQueue(label: "roundVideoCapture", qos: .userInitiated)
                }
                self.mainDeviceContext = CameraDeviceContext(session: self.session, exclusive: false, additional: false, ciContext: self.ciContext, colorSpace: self.colorSpace, isRoundVideo: self.initialConfiguration.isRoundVideo, sharedVideoQueue: sharedVideoQueue)
                self.mainDeviceContext?.configure(position: .back, previewView: self.simplePreviewView, audio: self.initialConfiguration.audio, photo: self.initialConfiguration.photo, metadata: self.initialConfiguration.metadata)

                self.additionalDeviceContext = CameraDeviceContext(session: self.session, exclusive: false, additional: true, ciContext: self.ciContext, colorSpace: self.colorSpace, isRoundVideo: self.initialConfiguration.isRoundVideo, sharedVideoQueue: sharedVideoQueue)
                self.additionalDeviceContext?.configure(position: .front, previewView: self.secondaryPreviewView, audio: false, photo: true, metadata: false)

                self.configureRoundVideoPipeline()
            }
            self.mainDeviceContext?.output.processSampleBuffer = { [weak self] sampleBuffer, pixelBuffer, connection in
                guard let self, let mainDeviceContext = self.mainDeviceContext else {
                    return
                }
                
                var front = false
                if #available(iOS 13.0, *) {
                    front = connection.inputPorts.first?.sourceDevicePosition == .front
                }
                self.mainVideoOutput?.push(sampleBuffer, mirror: front)
                
                let timestamp = CACurrentMediaTime()
                if timestamp > self.lastSnapshotTimestamp + 2.5, !mainDeviceContext.output.isRecording || !self.savedSnapshot {
                    self.savePreviewSnapshot(pixelBuffer: pixelBuffer, front: front)
                    self.lastSnapshotTimestamp = timestamp
                    self.savedSnapshot = true
                }
            }
            self.additionalDeviceContext?.output.processSampleBuffer = { [weak self] sampleBuffer, pixelBuffer, connection in
                guard let self, let additionalDeviceContext = self.additionalDeviceContext else {
                    return
                }
                
                var front = false
                if #available(iOS 13.0, *) {
                    front = connection.inputPorts.first?.sourceDevicePosition == .front
                }
                self.additionalVideoOutput?.push(sampleBuffer, mirror: front)
                
                let timestamp = CACurrentMediaTime()
                if timestamp > self.lastAdditionalSnapshotTimestamp + 2.5, !additionalDeviceContext.output.isRecording || !self.savedAdditionalSnapshot {
                    self.savePreviewSnapshot(pixelBuffer: pixelBuffer, front: front)
                    self.lastAdditionalSnapshotTimestamp = timestamp
                    self.savedAdditionalSnapshot = true
                }
            }
        } else {
            self.configure {
                self.mainDeviceContext?.invalidate()
                self.additionalDeviceContext?.invalidate()
                self.additionalDeviceContext = nil
                
                let preferWide = self.initialConfiguration.preferWide || self.initialConfiguration.isRoundVideo
                let preferLowerFramerate = self.initialConfiguration.preferLowerFramerate || self.initialConfiguration.isRoundVideo
                
                self.mainDeviceContext = CameraDeviceContext(session: self.session, exclusive: true, additional: false, ciContext: self.ciContext, colorSpace: self.colorSpace, isRoundVideo: self.initialConfiguration.isRoundVideo)
                self.mainDeviceContext?.configure(position: self.positionValue, previewView: self.simplePreviewView, audio: self.initialConfiguration.audio, photo: self.initialConfiguration.photo, metadata: self.initialConfiguration.metadata, preferWide: preferWide, preferLowerFramerate: preferLowerFramerate)

                self.configureRoundVideoPipeline()
            }
            self.mainDeviceContext?.output.processSampleBuffer = { [weak self] sampleBuffer, pixelBuffer, connection in
                guard let self, let mainDeviceContext = self.mainDeviceContext else {
                    return
                }
                
                var front = false
                if #available(iOS 13.0, *) {
                    front = connection.inputPorts.first?.sourceDevicePosition == .front
                }
                self.mainVideoOutput?.push(sampleBuffer, mirror: front)
                
                let timestamp = CACurrentMediaTime()
                if timestamp > self.lastSnapshotTimestamp + 2.5, !mainDeviceContext.output.isRecording || !self.savedSnapshot {
                    self.savePreviewSnapshot(pixelBuffer: pixelBuffer, front: front)
                    self.lastSnapshotTimestamp = timestamp
                    self.savedSnapshot = true
                }
            }
//            if self.initialConfiguration.reportAudioLevel {
//                self.mainDeviceContext?.output.processAudioBuffer = { [weak self] sampleBuffer in
//                    guard let self else {
//                        return
//                    }
//                    var blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
//                    let numSamplesInBuffer = CMSampleBufferGetNumSamples(sampleBuffer)
//                    var audioBufferList = AudioBufferList()
//
//                    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &audioBufferList, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
//
////                    for bufferCount in 0..<Int(audioBufferList.mNumberBuffers) {
//                        let buffer = audioBufferList.mBuffers.mData
//                        let size = audioBufferList.mBuffers.mDataByteSize
//                        if let data = buffer?.bindMemory(to: Int16.self, capacity: Int(size)) {
//                            processWaveformPreview(samples: data, count: numSamplesInBuffer)
//                        }
////                    }
//                    
//                    func processWaveformPreview(samples: UnsafePointer<Int16>, count: Int) {
//                        for i in 0..<count {
//                            var sample = samples[i]
//                            if sample < 0 {
//                                sample = -sample
//                            }
//
//                            if self.micLevelPeak < sample {
//                                self.micLevelPeak = sample
//                            }
//                            self.micLevelPeakCount += 1
//
//                            if self.micLevelPeakCount >= 1200 {
//                                let level = Float(self.micLevelPeak) / 4000.0
//                                self.audioLevelPipe.putNext(level)
//                     
//                                self.micLevelPeak = 0
//                                self.micLevelPeakCount = 0
//                            }
//                        }
//                    }
//                }
//            }
            self.mainDeviceContext?.output.processCodes = { [weak self] codes in
                self?.detectedCodesPipe.putNext(codes)
            }
        }
        self.session.session.startRunning()
        self.logMultiCamCosts()

        if change {
            if #available(iOS 13.0, *), let previewView = self.simplePreviewView {
                if enabled, let secondaryPreviewView = self.secondaryPreviewView {
                    let _ = (combineLatest(previewView.isPreviewing, secondaryPreviewView.isPreviewing)
                    |> map { first, second in
                        return first && second
                    }
                    |> filter { $0 }
                    |> take(1)
                    |> delay(0.1, queue: self.queue)
                    |> deliverOn(self.queue)).startStandalone(next: { [weak self] _ in
                        self?.modeChange = .none
                    })
                } else {
                    let _ = (previewView.isPreviewing
                    |> filter { $0 }
                    |> take(1)
                    |> deliverOn(self.queue)).startStandalone(next: { [weak self] _ in
                        self?.modeChange = .none
                    })
                }
            } else {
                self.queue.after(0.4) {
                    self.modeChange = .none
                }
            }
        }
    }
    
    private func configure(_ f: () -> Void) {
        self.session.session.beginConfiguration()
        f()
        self.session.session.commitConfiguration()
    }

    // Both cameras must use one pixel format and YCbCr matrix because they share a writer
    // track. Disable Metal when their format metadata disagrees.
    private func configureRoundVideoPipeline() {
        guard self.initialConfiguration.isRoundVideo, let mainDeviceContext = self.mainDeviceContext else {
            return
        }
        var wantV2 = Camera.roundVideoPipelineV2 && RoundVideoMetalCompositor.sharedPipeline != nil
        if wantV2 {
            let mainMatrix = self.formatColorMatrix(mainDeviceContext.device.videoDevice?.activeFormat)
            let additionalMatrix = self.formatColorMatrix(self.additionalDeviceContext?.device.videoDevice?.activeFormat)
            if let mainMatrix, let additionalMatrix, mainMatrix != additionalMatrix {
                wantV2 = false
                Logger.shared.log("Camera", "Round video V2 disabled: cameras disagree on YCbCr matrix (\(mainMatrix) vs \(additionalMatrix))")
                os_signpost(.event, log: RoundVideoSignpost.log, name: "v2ColorFallback")
            }
        }
        let effectiveV2 = mainDeviceContext.output.configureRoundVideoPipeline(v2: wantV2)
        let _ = self.additionalDeviceContext?.output.configureRoundVideoPipeline(v2: effectiveV2)
        os_signpost(
            .event,
            log: RoundVideoSignpost.log,
            name: "pipelineConfigured",
            "mode=%{public}@ requestedNV12=%d effectiveNV12=%d",
            Camera.roundVideoBenchmarkMode.name as NSString,
            Camera.roundVideoPipelineV2 ? 1 : 0,
            effectiveV2 ? 1 : 0
        )
    }

    private func formatColorMatrix(_ format: AVCaptureDevice.Format?) -> String? {
        guard let format, let extensions = CMFormatDescriptionGetExtensions(format.formatDescription) as? [String: Any] else {
            return nil
        }
        return extensions[kCVImageBufferYCbCrMatrixKey as String] as? String
    }
    
    var hasTorch: Signal<Bool, NoError> {
        return self.mainDeviceContext?.device.isTorchAvailable ?? .never()
    }
    
    func setTorchActive(_ active: Bool) {
        self.mainDeviceContext?.device.setTorchActive(active)
    }
    
    var isFlashActive: Signal<Bool, NoError> {
        return self.mainDeviceContext?.output.isFlashActive ?? .never()
    }
    
    private var _flashMode: Camera.FlashMode = .off {
        didSet {
            self._flashModePromise.set(self._flashMode)
        }
    }
    private var _flashModePromise = ValuePromise<Camera.FlashMode>(.off)
    var flashMode: Signal<Camera.FlashMode, NoError> {
        return self._flashModePromise.get()
    }
    
    func setFlashMode(_ mode: Camera.FlashMode) {
        self._flashMode = mode
    }
    
    func setZoomLevel(_ zoomLevel: CGFloat) {
        if self.initialConfiguration.isRoundVideo {
            if self.positionValue == .front {
                self.additionalDeviceContext?.device.setZoomLevel(zoomLevel)
            } else {
                self.mainDeviceContext?.device.setZoomLevel(zoomLevel)
            }
        } else {
            self.mainDeviceContext?.device.setZoomLevel(zoomLevel)
        }
    }
    
    func setZoomDelta(_ zoomDelta: CGFloat) {
        if self.initialConfiguration.isRoundVideo {
            if self.positionValue == .front {
                self.additionalDeviceContext?.device.setZoomDelta(zoomDelta)
            } else {
                self.mainDeviceContext?.device.setZoomDelta(zoomDelta)
            }
        } else {
            self.mainDeviceContext?.device.setZoomDelta(zoomDelta)
        }
    }
    
    func rampZoom(_ zoomLevel: CGFloat, rate: CGFloat) {
        if self.initialConfiguration.isRoundVideo {
            if self.positionValue == .front {
                self.additionalDeviceContext?.device.rampZoom(zoomLevel, rate: rate)
            } else {
                self.mainDeviceContext?.device.rampZoom(zoomLevel, rate: rate)
            }
        } else {
            self.mainDeviceContext?.device.rampZoom(zoomLevel, rate: rate)
        }
    }
    
    func takePhoto() -> Signal<PhotoCaptureResult, NoError> {
        guard let mainDeviceContext = self.mainDeviceContext else {
            return .complete()
        }
        let orientation = self.simplePreviewView?.videoPreviewLayer.connection?.videoOrientation ?? .portrait
        if let additionalDeviceContext = self.additionalDeviceContext {
            let dualPosition = self.positionValue
            return combineLatest(
                mainDeviceContext.output.takePhoto(orientation: orientation, flashMode: self._flashMode),
                additionalDeviceContext.output.takePhoto(orientation: orientation, flashMode: self._flashMode)
            ) |> map { main, additional in
                if case let .finished(mainImage, _, _) = main, case let .finished(additionalImage, _, _) = additional {
                    if dualPosition == .front {
                        return .finished(additionalImage, mainImage, CACurrentMediaTime())
                    } else {
                        return .finished(mainImage, additionalImage, CACurrentMediaTime())
                    }
                } else {
                    if case .failed = main {
                        return .failed
                    } else if case .failed = additional {
                        return .failed
                    }
                    return .began
                }
            } |> distinctUntilChanged
        } else {
            return mainDeviceContext.output.takePhoto(orientation: orientation, flashMode: self._flashMode)
        }
    }
    
    public func startRecording() -> Signal<CameraRecordingData, CameraRecordingError> {
        guard let mainDeviceContext = self.mainDeviceContext else {
            return .complete()
        }
        if self.initialConfiguration.isRoundVideo && self.positionValue == .front {
            
        } else {
            mainDeviceContext.device.setTorchMode(self._flashMode)
        }
        
        let timestamp = CACurrentMediaTime() + 2.0
        self.lastSnapshotTimestamp = timestamp
        self.lastAdditionalSnapshotTimestamp = timestamp
        
        let orientation = self.simplePreviewView?.videoPreviewLayer.connection?.videoOrientation ?? .portrait
        if self.initialConfiguration.isRoundVideo {
            return mainDeviceContext.output.startRecording(mode: .roundVideo, orientation: DeviceModel.current.isIpad ? orientation : .portrait, additionalOutput: self.additionalDeviceContext?.output)
        } else {
            if let additionalDeviceContext = self.additionalDeviceContext {
                return combineLatest(
                    mainDeviceContext.output.startRecording(mode: .dualCamera, position: self.positionValue, orientation: orientation),
                    additionalDeviceContext.output.startRecording(mode: .dualCamera, orientation: .portrait)
                ) |> map { value, _ in
                    return value
                }
            } else {
                return mainDeviceContext.output.startRecording(mode: .default, orientation: orientation)
            }
        }
    }
    
    public func stopRecording() -> Signal<VideoCaptureResult, NoError> {
        guard let mainDeviceContext = self.mainDeviceContext else {
            return .complete()
        }
        if self.initialConfiguration.isRoundVideo {
            return mainDeviceContext.output.stopRecording()
            |> map { result -> VideoCaptureResult in
                if case let .finished(mainResult, _, duration, positionChangeTimestamps, captureTimestamp) = result {
                    return .finished(
                        main: mainResult,
                        additional: nil,
                        duration: duration,
                        positionChangeTimestamps: positionChangeTimestamps,
                        captureTimestamp: captureTimestamp
                    )
                } else {
                    return result
                }
            }
        } else {
            if let additionalDeviceContext = self.additionalDeviceContext {
                return combineLatest(
                    mainDeviceContext.output.stopRecording(),
                    additionalDeviceContext.output.stopRecording()
                ) |> mapToSignal { main, additional in
                    if case let .finished(mainResult, _, duration, positionChangeTimestamps, _) = main, case let .finished(additionalResult, _, _, _, _) = additional {
                        var additionalThumbnailImage = additionalResult.thumbnail
                        if let cgImage = additionalResult.thumbnail.cgImage {
                            additionalThumbnailImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .leftMirrored)
                        }
                        
                        return .single(
                            .finished(
                                main: mainResult,
                                additional: VideoCaptureResult.Result(path: additionalResult.path, thumbnail: additionalThumbnailImage, isMirrored: true, dimensions: additionalResult.dimensions),
                                duration: duration,
                                positionChangeTimestamps: positionChangeTimestamps,
                                captureTimestamp: CACurrentMediaTime()
                            )
                        )
                    } else {
                        return .complete()
                    }
                }
            } else {
                let isMirrored = self.positionValue == .front
                return mainDeviceContext.output.stopRecording()
                |> map { result -> VideoCaptureResult in
                    if case let .finished(mainResult, _, duration, positionChangeTimestamps, captureTimestamp) = result {
                        var thumbnailImage = mainResult.thumbnail
                        if isMirrored, let cgImage = thumbnailImage.cgImage {
                            thumbnailImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .leftMirrored)
                        }
                        return .finished(
                            main: VideoCaptureResult.Result(path: mainResult.path, thumbnail: thumbnailImage, isMirrored: isMirrored, dimensions: mainResult.dimensions),
                            additional: nil,
                            duration: duration,
                            positionChangeTimestamps: positionChangeTimestamps,
                            captureTimestamp: captureTimestamp
                        )
                    } else {
                        return result
                    }
                }
            }
        }
    }
    
    var detectedCodes: Signal<[CameraCode], NoError> {
        return self.detectedCodesPipe.signal()
    }
    
    var audioLevel: Signal<Float, NoError> {
        return self.audioLevelPipe.signal()
    }
    
    var transitionImage: Signal<UIImage?, NoError> {
        return .single(self.mainDeviceContext?.output.transitionImage)
    }
    
    @objc private func sessionInterruptionEnded(notification: NSNotification) {
    }
    
    @objc private func sessionRuntimeError(notification: NSNotification) {
        guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        
        let error = AVError(_nsError: errorValue)
        Logger.shared.log("Camera", "Runtime error: \(error)")
    
        if error.code == .mediaServicesWereReset {
            self.queue.async {
                if self.isSessionRunning {
                    self.session.session.startRunning()
                    self.isSessionRunning = self.session.session.isRunning
                }
            }
        }
    }
}

public final class Camera {
    public typealias Preset = AVCaptureSession.Preset
    public typealias Position = AVCaptureDevice.Position
    public typealias FocusMode = AVCaptureDevice.FocusMode
    public typealias ExposureMode = AVCaptureDevice.ExposureMode
    public typealias FlashMode = AVCaptureDevice.FlashMode

    // MARK: Round-video benchmark
    public enum RoundVideoBenchmarkMode: Int32 {
        case vanilla = 0
        case optimizedCurrentResolution = 1
        case optimized640x480 = 2

        public var name: String {
            switch self {
            case .vanilla:
                return "vanilla"
            case .optimizedCurrentResolution:
                return "optimized-current"
            case .optimized640x480:
                return "optimized-640x480"
            }
        }
    }
    public static var roundVideoBenchmarkMode: RoundVideoBenchmarkMode = .vanilla

    public static var roundVideoOptimizationsEnabled: Bool {
        return self.roundVideoBenchmarkMode != .vanilla
    }

    // MARK: Round-video capture quality
    public enum RoundVideoDualCaptureQuality {
        case current
        case r640x480
    }
    public static var roundVideoDualCaptureQuality: RoundVideoDualCaptureQuality {
        switch self.roundVideoBenchmarkMode {
        case .vanilla, .optimizedCurrentResolution:
            return .current
        case .optimized640x480:
            return .r640x480
        }
    }

    // Process NV12 directly in Metal instead of converting through BGRA and Core Image.
    public static var roundVideoPipelineV2: Bool {
        return self.roundVideoOptimizationsEnabled
    }

    public struct CollageGrid: Hashable {
        public struct Row: Hashable {
            public let columns: Int
            
            public init(columns: Int) {
                self.columns = columns
            }
        }

        public let rows: [Row]
        
        public init(rows: [Row]) {
            self.rows = rows
        }
        
        public var count: Int {
            return self.rows.reduce(0) { $0 + $1.columns }
        }
    }
    
    public struct Configuration {
        let preset: Preset
        let position: Position
        let isDualEnabled: Bool
        let audio: Bool
        let photo: Bool
        let metadata: Bool
        let preferWide: Bool
        let preferLowerFramerate: Bool
        let reportAudioLevel: Bool
        let isRoundVideo: Bool
        
        public init(preset: Preset, position: Position, isDualEnabled: Bool = false, audio: Bool, photo: Bool, metadata: Bool, preferWide: Bool = false, preferLowerFramerate: Bool = false, reportAudioLevel: Bool = false, isRoundVideo: Bool = false) {
            self.preset = preset
            self.position = position
            self.isDualEnabled = isDualEnabled
            self.audio = audio
            self.photo = photo
            self.metadata = metadata
            self.preferWide = preferWide
            self.preferLowerFramerate = preferLowerFramerate
            self.reportAudioLevel = reportAudioLevel
            self.isRoundVideo = isRoundVideo
        }
    }
    
    private let queue = Queue()
    private var contextRef: Unmanaged<CameraContext>?

    private weak var previewView: CameraPreviewView?
    
    public let metrics: Camera.Metrics
    
    public init(
        configuration: Camera.Configuration = Configuration(
            preset: .hd1920x1080,
            position: .back,
            audio: true,
            photo: false,
            metadata: false
        ),
        previewView: CameraSimplePreviewView? = nil,
        secondaryPreviewView: CameraSimplePreviewView? = nil
    ) {
        Logger.shared.log("Camera", "Init")
        
        self.metrics = Camera.Metrics(model: DeviceModel.current)
        
        let session = CameraSession(forRoundVideo: configuration.isRoundVideo)
        session.session.automaticallyConfiguresApplicationAudioSession = false
        session.session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.session.usesApplicationAudioSession = true
        if let previewView {
            previewView.setSession(session.session, autoConnect: !session.hasMultiCam)
        }
        if let secondaryPreviewView, session.hasMultiCam {
            secondaryPreviewView.setSession(session.session, autoConnect: false)
        }
        
        if #available(iOS 14.5, *), configuration.isRoundVideo {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
        }
        
        self.queue.async {
            let context = CameraContext(queue: self.queue, session: session, configuration: configuration, metrics: self.metrics, previewView: previewView, secondaryPreviewView: secondaryPreviewView)
            self.contextRef = Unmanaged.passRetained(context)
        }
    }
    
    deinit {
        Logger.shared.log("Camera", "Deinit")
        
        let contextRef = self.contextRef
        self.queue.async {
            contextRef?.release()
        }
        
        if #available(iOS 14.5, *) {
            AVCaptureDevice.centerStageControlMode = .user
        }
    }
    
    public func startCapture() {
#if targetEnvironment(simulator)
#else
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.startCapture()
            }
        }
#endif
    }
    
    public func stopCapture(invalidate: Bool = false) {
#if targetEnvironment(simulator)
#else
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.stopCapture(invalidate: invalidate)
            }
        }
#endif
    }
    
    public var position: Signal<Camera.Position, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.position.start(next: { flashMode in
                        subscriber.putNext(flashMode)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public func togglePosition() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.togglePosition()
            }
        }
    }
    
    public func setPosition(_ position: Camera.Position) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setPosition(position)
            }
        }
    }
    
    public func setDualCameraEnabled(_ enabled: Bool) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setDualCameraEnabled(enabled)
            }
        }
    }
    
    public func takePhoto() -> Signal<PhotoCaptureResult, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.takePhoto().start(next: { value in
                        subscriber.putNext(value)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public func startRecording() -> Signal<CameraRecordingData, CameraRecordingError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.startRecording().start(next: { value in
                        subscriber.putNext(value)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public func stopRecording() -> Signal<VideoCaptureResult, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.stopRecording().start(next: { value in
                        subscriber.putNext(value)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public func focus(at point: CGPoint, autoFocus: Bool = true) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.focus(at: point, autoFocus: autoFocus)
            }
        }
    }
    
    public func setFps(_ fps: Double) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setFps(fps)
            }
        }
    }
    
    public func setFlashMode(_ flashMode: FlashMode) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setFlashMode(flashMode)
            }
        }
    }
    
    public func setZoomLevel(_ zoomLevel: CGFloat) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setZoomLevel(zoomLevel)
            }
        }
    }
    
    
    public func setZoomDelta(_ zoomDelta: CGFloat) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setZoomDelta(zoomDelta)
            }
        }
    }
    
    public func rampZoom(_ zoomLevel: CGFloat, rate: CGFloat) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.rampZoom(zoomLevel, rate: rate)
            }
        }
    }
    
    public func setTorchActive(_ active: Bool) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setTorchActive(active)
            }
        }
    }
    
    public var hasTorch: Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.hasTorch.start(next: { hasTorch in
                        subscriber.putNext(hasTorch)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public var isFlashActive: Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.isFlashActive.start(next: { isFlashActive in
                        subscriber.putNext(isFlashActive)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public var flashMode: Signal<Camera.FlashMode, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.flashMode.start(next: { flashMode in
                        subscriber.putNext(flashMode)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public func setMainVideoOutput(_ output: CameraVideoOutput?) {
        let outputRef: Unmanaged<CameraVideoOutput>? = output.flatMap { Unmanaged.passRetained($0) }
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                if let outputRef {
                    context.mainVideoOutput = outputRef.takeUnretainedValue()
                    outputRef.release()
                } else {
                    context.mainVideoOutput = nil
                }
            } else {
                Queue.mainQueue().async {
                    outputRef?.release()
                }
            }
        }
    }
    
    public func setAdditionalVideoOutput(_ output: CameraVideoOutput?) {
        let outputRef: Unmanaged<CameraVideoOutput>? = output.flatMap { Unmanaged.passRetained($0) }
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                if let outputRef {
                    context.additionalVideoOutput = outputRef.takeUnretainedValue()
                    outputRef.release()
                } else {
                    context.additionalVideoOutput = nil
                }
            } else {
                Queue.mainQueue().async {
                    outputRef?.release()
                }
            }
        }
    }
    
    public func attachSimplePreviewView(_ view: CameraSimplePreviewView) {
        let viewRef: Unmanaged<CameraSimplePreviewView> = Unmanaged.passRetained(view)
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.simplePreviewView = viewRef.takeUnretainedValue()
                viewRef.release()
            } else {
                Queue.mainQueue().async {
                    viewRef.release()
                }
            }
        }
    }
    
    public var detectedCodes: Signal<[CameraCode], NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.detectedCodes.start(next: { codes in
                        subscriber.putNext(codes)
                    }))
                }
            }
            return disposable
        }
    }
    
    public var audioLevel: Signal<Float, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.audioLevel.start(next: { codes in
                        subscriber.putNext(codes)
                    }))
                }
            }
            return disposable
        }
    }
    
    public var transitionImage: Signal<UIImage?, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.transitionImage.start(next: { codes in
                        subscriber.putNext(codes)
                    }))
                }
            }
            return disposable
        }
    }
    
    public enum ModeChange: Equatable {
        case none
        case position
        case dualCamera
    }
    public var modeChange: Signal<ModeChange, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.modeChangePromise.get().start(next: { value in
                        subscriber.putNext(value)
                    }))
                }
            }
            return disposable
        }
    }
    
    public static func isDualCameraSupported(forRoundVideo: Bool = false) -> Bool {
        if #available(iOS 13.0, *), AVCaptureMultiCamSession.isMultiCamSupported && !DeviceModel.current.isIpad {
            if forRoundVideo {
                if DeviceModel.current == .iPhoneXR {
                    return false
                }
                if ProcessInfo.processInfo.isLowPowerModeEnabled && !self.roundVideoOptimizationsEnabled {
                    return false
                }
            }
            return true
        } else {
            return false
        }
    }
    
    public static var isIpad: Bool {
        return DeviceModel.current.isIpad
    }
}

public final class CameraHolder {
    public let camera: Camera
    public let previewView: CameraSimplePreviewView
    public let parentView: UIView
    public let restore: () -> Void
    
    public init(
        camera: Camera,
        previewView: CameraSimplePreviewView,
        parentView: UIView,
        restore: @escaping () -> Void
    ) {
        self.camera = camera
        self.previewView = previewView
        self.parentView = parentView
        self.restore = restore
    }
}

public struct CameraRecordingData {
    public let duration: Double
    public let filePath: String
}

public enum CameraRecordingError {
    case videoRecorderInitializationError
    case audioInitializationError
}

public class CameraVideoOutput {
    private let sink: (CMSampleBuffer, Bool) -> Void
    
    public init(sink: @escaping (CMSampleBuffer, Bool) -> Void) {
        self.sink = sink
    }
    
    func push(_ buffer: CMSampleBuffer, mirror: Bool) {
        self.sink(buffer, mirror)
    }
}
