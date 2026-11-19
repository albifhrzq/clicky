//
//  ClickyDrawingVideoRecorder.swift
//  leanring-buddy
//
//  Records one display (including Clicky's drawing overlay) to an H.264 .mp4 using
//  SCStream + AVAssetWriter. SCRecordingOutput would be simpler but needs macOS 15,
//  and the deployment target is macOS 14.2. Audio is intentionally not recorded.
//

import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

enum ClickyDrawingVideoRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case screenRecordingPermissionMissing
    case displayNotFound
    case noFramesCaptured
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A video is already being recorded."
        case .notRecording:
            return "No video recording is in progress."
        case .screenRecordingPermissionMissing:
            return "Clicky needs Screen Recording permission to save a drawing as video. Enable it in System Settings > Privacy & Security > Screen Recording."
        case .displayNotFound:
            return "The display showing the drawing could not be found."
        case .noFramesCaptured:
            return "No video frames were captured."
        case .writerFailed(let reason):
            return "The video file could not be written: \(reason)"
        }
    }
}

// MARK: - Frame Writer (runs on the ScreenCaptureKit sample queue)

/// Receives frames on SCStream's background queue and appends them to the AVAssetWriter.
/// Kept separate from the main-actor recorder so no actor hopping happens per frame.
nonisolated private final class ClickyVideoFrameWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var hasStartedSession = false
    // Set in finish(); late SCStream callbacks must not append after markAsFinished (would crash).
    private var hasFinishedWriting = false
    private var firstFailure: Error?

    init(outputURL: URL, width: Int, height: Int) throws {
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(videoInput) else {
            throw ClickyDrawingVideoRecorderError.writerFailed("H.264 input is not supported for \(width)x\(height).")
        }
        assetWriter.add(videoInput)
        guard assetWriter.startWriting() else {
            throw ClickyDrawingVideoRecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "unknown error")
        }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }

        // SCStream also delivers status-only buffers (idle/blank); only "complete" frames carry pixels.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachmentsArray.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !hasFinishedWriting, assetWriter.status == .writing || assetWriter.status == .unknown, firstFailure == nil else {
            if assetWriter.status == .failed, firstFailure == nil {
                firstFailure = ClickyDrawingVideoRecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "unknown error")
            }
            return
        }

        if assetWriter.status == .failed {
            firstFailure = ClickyDrawingVideoRecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "unknown error")
            return
        }
        if !hasStartedSession {
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            hasStartedSession = true
        }
        // Dropping a frame when the encoder is busy is fine for a screen recording.
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        firstFailure = firstFailure ?? error
        lock.unlock()
    }

    /// Aborts a writer whose capture never started.
    func cancel() {
        lock.withLock {
            hasFinishedWriting = true
            assetWriter.cancelWriting()
        }
    }

    /// Closes the file. Throws the first failure seen while recording, or `noFramesCaptured`.
    func finish() async throws {
        let (failure, didStart) = lock.withLock { () -> (Error?, Bool) in
            hasFinishedWriting = true
            let failure = firstFailure
            let didStart = hasStartedSession
            if didStart && failure == nil {
                videoInput.markAsFinished()
                // The screen is static after the drawing ends so SCStream stops sending frames;
                // end the session at "now" so the last frame is held instead of cut short.
                assetWriter.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            return (failure, didStart)
        }

        if let failure {
            assetWriter.cancelWriting()
            throw failure
        }
        guard didStart else {
            assetWriter.cancelWriting()
            throw ClickyDrawingVideoRecorderError.noFramesCaptured
        }
        await assetWriter.finishWriting()
        if assetWriter.status != .completed {
            throw ClickyDrawingVideoRecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "unknown error")
        }
    }
}

// MARK: - Recorder

@MainActor
final class ClickyDrawingVideoRecorder {
    private(set) var isRecording = false
    private var isStarting = false
    private var stream: SCStream?
    private var frameWriter: ClickyVideoFrameWriter?
    private var outputURL: URL?
    private let sampleQueue = DispatchQueue(label: "clicky.drawing-video.samples")

    /// Starts recording `screen`. Clicky's own windows are excluded except the drawing overlay
    /// (`overlayWindowID`), so the recording shows the user's screen plus the drawing.
    func start(recording screen: NSScreen, overlayWindowID: CGWindowID, to outputURL: URL) async throws {
        guard !isRecording, !isStarting else { throw ClickyDrawingVideoRecorderError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }
        guard CGPreflightScreenCaptureAccess() else { throw ClickyDrawingVideoRecorderError.screenRecordingPermissionMissing }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ClickyDrawingVideoRecorderError.displayNotFound
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownWindowsToExclude = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier && window.windowID != overlayWindowID
        }
        let contentFilter = SCContentFilter(display: display, excludingWindows: ownWindowsToExclude)

        // H.264 needs even dimensions. Point size (not retina pixels) keeps files small and encoder-safe.
        let videoWidth = Int(display.width) & ~1
        let videoHeight = Int(display.height) & ~1
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = videoWidth
        streamConfiguration.height = videoHeight
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = true
        streamConfiguration.queueDepth = 5

        try? FileManager.default.removeItem(at: outputURL)
        let newFrameWriter = try ClickyVideoFrameWriter(outputURL: outputURL, width: videoWidth, height: videoHeight)
        let newStream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: newFrameWriter)
        do {
            try newStream.addStreamOutput(newFrameWriter, type: .screen, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
        } catch {
            // Don't leave a half-open writer and a partial file behind.
            newFrameWriter.cancel()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        stream = newStream
        frameWriter = newFrameWriter
        self.outputURL = outputURL
        isRecording = true
    }

    /// Stops capture, finalizes the file and returns its URL.
    func stop() async throws -> URL {
        guard isRecording, let stream, let frameWriter, let outputURL else {
            throw ClickyDrawingVideoRecorderError.notRecording
        }
        isRecording = false
        self.stream = nil
        self.frameWriter = nil
        self.outputURL = nil

        do {
            try await stream.stopCapture()
        } catch {
            // The stream may already have stopped on its own; the writer reports a real failure in finish().
            print("⚠️ ClickyDrawingVideoRecorder: stopCapture failed: \(error)")
        }
        try await frameWriter.finish()
        return outputURL
    }
}
