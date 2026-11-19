//
//  ClickyMicrophoneCaptureInput.swift
//  leanring-buddy
//
//  Mic capture through AVCaptureSession on the microphone chosen in Settings → Microphone.
//  Pinning AVAudioEngine's input node to a device makes macOS build an input/output aggregate,
//  which fails on Bluetooth headsets and flips them into the call profile (HFP). AVCaptureSession
//  reads any input device without touching the output device, so a headset stays in music mode
//  while the built-in mic records.
//
//  Everything here is nonisolated: sample buffers arrive on a private dispatch queue, and a
//  MainActor-isolated closure invoked there would trip Swift's runtime isolation check.
//

import AVFoundation
import CoreMedia
import Foundation

nonisolated final class ClickyMicrophoneCaptureInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "com.clicky.microphone-capture.session")
    private let sampleBufferDeliveryQueue = DispatchQueue(label: "com.clicky.microphone-capture.delivery")
    private let logPrefix: String

    // Guarded by stateLock: written from start/stop (any thread), read on the delivery queue.
    private let stateLock = NSLock()
    private var audioBufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var captureSession: AVCaptureSession?
    private var audioDataOutput: AVCaptureAudioDataOutput?

    init(logPrefix: String) {
        self.logPrefix = logPrefix
        super.init()
    }

    /// Pure decision: which AVCaptureDevice unique ID to look up. nil = system default input.
    static func preferredCaptureDeviceUniqueID(
        storedUniqueID: String?,
        availableDevices: [ClickyMicrophoneDeviceOption]
    ) -> String? {
        ClickyMicrophoneSelection.resolveCaptureDevice(
            storedUniqueID: storedUniqueID,
            availableDevices: availableDevices
        )?.uniqueID
    }

    private static func resolveCaptureDevice() -> AVCaptureDevice? {
        let storedUniqueID = UserDefaults.standard.string(forKey: ClickyMicrophoneSelection.selectedMicrophoneUniqueIDDefaultsKey)
        let preferredUniqueID = preferredCaptureDeviceUniqueID(
            storedUniqueID: storedUniqueID,
            availableDevices: ClickyMicrophoneSelection.queryInputDevices()
        )
        // On macOS an audio AVCaptureDevice's uniqueID equals the CoreAudio device UID.
        if let preferredUniqueID, let chosenDevice = AVCaptureDevice(uniqueID: preferredUniqueID) {
            return chosenDevice
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Starts capturing. The handler runs on the delivery queue, never the main actor.
    func start(onAudioBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()

        guard let captureDevice = Self.resolveCaptureDevice() else {
            throw Self.makeError("No microphone found", code: 1)
        }
        print("🎙️ \(logPrefix): capturing from '\(captureDevice.localizedName)'")

        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: captureDevice)
        let output = AVCaptureAudioDataOutput()
        // Native sample rate, mono Float32 non-interleaved: what every consumer here expects.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1
        ]
        output.setSampleBufferDelegate(self, queue: sampleBufferDeliveryQueue)

        session.beginConfiguration()
        guard session.canAddInput(deviceInput) else {
            session.commitConfiguration()
            throw Self.makeError("Cannot use microphone '\(captureDevice.localizedName)' as capture input", code: 2)
        }
        session.addInput(deviceInput)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Self.makeError("Cannot add audio output to capture session", code: 3)
        }
        session.addOutput(output)
        session.commitConfiguration()

        stateLock.lock()
        audioBufferHandler = onAudioBuffer
        captureSession = session
        audioDataOutput = output
        stateLock.unlock()

        // startRunning blocks, so it runs off the caller's thread (often the main actor).
        sessionQueue.async { session.startRunning() }
    }

    /// Idempotent. Safe to call from the main actor.
    func stop() {
        stateLock.lock()
        let session = captureSession
        let output = audioDataOutput
        captureSession = nil
        audioDataOutput = nil
        audioBufferHandler = nil
        stateLock.unlock()

        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session {
            sessionQueue.async { session.stopRunning() }
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        stateLock.lock()
        let handler = audioBufferHandler
        stateLock.unlock()
        guard let handler, let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
        handler(pcmBuffer)
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let audioFormat = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        return status == noErr ? pcmBuffer : nil
    }

    private static func makeError(_ message: String, code: Int) -> NSError {
        NSError(domain: "ClickyMicrophoneCaptureInput", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
