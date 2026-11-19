//
//  ClickyAudioTopologyMonitor.swift
//  leanring-buddy
//
//  Monitors macOS CoreAudio HAL topology changes (default output, default input,
//  devices list, and output data source) on a background serial queue so sleep/wake
//  and Bluetooth connections never block the main thread.
//

import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation

public struct ClickyAudioTopologySnapshot: Equatable, Sendable {
    public let defaultOutputDeviceID: AudioObjectID
    public let defaultInputDeviceID: AudioObjectID
    public let defaultOutputDeviceName: String
    public let inputDeviceName: String
    public let outputIsBluetooth: Bool
    public let outputIsHeadphones: Bool
    public let outputTransportType: UInt32
    public let outputDataSourceName: String?
    public let updatedAt: Date

    public var requiredPreRollSilenceDuration: TimeInterval {
        outputIsBluetooth ? 0.25 : 0.125
    }

    public static let empty = ClickyAudioTopologySnapshot(
        defaultOutputDeviceID: kAudioObjectUnknown,
        defaultInputDeviceID: kAudioObjectUnknown,
        defaultOutputDeviceName: "",
        inputDeviceName: "",
        outputIsBluetooth: false,
        outputIsHeadphones: false,
        outputTransportType: 0,
        outputDataSourceName: nil,
        updatedAt: .distantPast
    )
}

@MainActor
public final class ClickyAudioTopologyMonitor: ObservableObject {
    public static let shared = ClickyAudioTopologyMonitor()

    @Published public private(set) var snapshot: ClickyAudioTopologySnapshot

    public let topologyChangedPublisher = PassthroughSubject<ClickyAudioTopologySnapshot, Never>()

    private nonisolated let topologyQueue = DispatchQueue(
        label: "com.clicky.audio-topology-monitor",
        qos: .utility
    )

    nonisolated(unsafe) private var isStarted = false
    nonisolated(unsafe) private var pendingRefreshWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var systemListenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    nonisolated(unsafe) private var watchedOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    private init() {
        self.snapshot = Self.queryCurrentTopologySnapshot()
        start()
    }

    deinit {
        stop()
    }

    public func start() {
        topologyQueue.async { [weak self] in
            self?.installListenersIfNeeded()
        }
    }

    public func refreshNow() {
        topologyQueue.async { [weak self] in
            self?.performRefreshOnTopologyQueue()
        }
    }

    nonisolated public func stop() {
        topologyQueue.sync {
            guard isStarted else { return }
            isStarted = false

            pendingRefreshWorkItem?.cancel()
            pendingRefreshWorkItem = nil

            let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
            for (address, block) in systemListenerBlocks {
                var mutableAddress = address
                AudioObjectRemovePropertyListenerBlock(
                    systemObjectID,
                    &mutableAddress,
                    topologyQueue,
                    block
                )
            }
            systemListenerBlocks.removeAll()

            removeOutputDataSourceListenerOnTopologyQueue()

            if let wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
                self.wakeObserver = nil
            }
        }
    }

    // MARK: - Background Listener Management

    nonisolated private func installListenersIfNeeded() {
        guard !isStarted else { return }
        isStarted = true

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let watchedSelectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices
        ]

        for selector in watchedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleDebouncedRefreshOnTopologyQueue()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                systemObjectID,
                &address,
                topologyQueue,
                listenerBlock
            )
            if status == noErr {
                systemListenerBlocks.append((address, listenerBlock))
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.topologyQueue.async {
                self?.scheduleDebouncedRefreshOnTopologyQueue(delaySeconds: 0.25)
            }
        }

        performRefreshOnTopologyQueue()
    }

    nonisolated private func scheduleDebouncedRefreshOnTopologyQueue(delaySeconds: TimeInterval = 0.05) {
        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performRefreshOnTopologyQueue()
        }
        pendingRefreshWorkItem = workItem
        topologyQueue.asyncAfter(deadline: .now() + delaySeconds, execute: workItem)
    }

    nonisolated private func performRefreshOnTopologyQueue() {
        let updatedSnapshot = Self.queryCurrentTopologySnapshot()
        updateOutputDataSourceListenerOnTopologyQueue(for: updatedSnapshot.defaultOutputDeviceID)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let previous = self.snapshot
            self.snapshot = updatedSnapshot
            let topologyMeaningfullyChanged =
                previous.defaultOutputDeviceID != updatedSnapshot.defaultOutputDeviceID
                || previous.defaultInputDeviceID != updatedSnapshot.defaultInputDeviceID
                || previous.defaultOutputDeviceName != updatedSnapshot.defaultOutputDeviceName
                || previous.inputDeviceName != updatedSnapshot.inputDeviceName
                || previous.outputIsBluetooth != updatedSnapshot.outputIsBluetooth
                || previous.outputIsHeadphones != updatedSnapshot.outputIsHeadphones
                || previous.outputDataSourceName != updatedSnapshot.outputDataSourceName

            if topologyMeaningfullyChanged {
                self.topologyChangedPublisher.send(updatedSnapshot)
            }
        }
    }

    nonisolated private func updateOutputDataSourceListenerOnTopologyQueue(for outputDeviceID: AudioObjectID) {
        guard outputDeviceID != watchedOutputDeviceID else { return }
        removeOutputDataSourceListenerOnTopologyQueue()

        guard outputDeviceID != kAudioObjectUnknown else { return }

        var dataSourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(outputDeviceID, &dataSourceAddress) else { return }

        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleDebouncedRefreshOnTopologyQueue()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            outputDeviceID,
            &dataSourceAddress,
            topologyQueue,
            listenerBlock
        )
        if status == noErr {
            watchedOutputDeviceID = outputDeviceID
            outputDeviceListenerBlock = listenerBlock
        }
    }

    nonisolated private func removeOutputDataSourceListenerOnTopologyQueue() {
        guard watchedOutputDeviceID != kAudioObjectUnknown,
              let listenerBlock = outputDeviceListenerBlock else {
            watchedOutputDeviceID = kAudioObjectUnknown
            outputDeviceListenerBlock = nil
            return
        }

        var dataSourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            watchedOutputDeviceID,
            &dataSourceAddress,
            topologyQueue,
            listenerBlock
        )
        watchedOutputDeviceID = kAudioObjectUnknown
        outputDeviceListenerBlock = nil
    }

    // MARK: - CoreAudio HAL Queries (Pure Nonisolated)

    nonisolated private static func queryCurrentTopologySnapshot() -> ClickyAudioTopologySnapshot {
        let outputDeviceID = queryDefaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let inputDeviceID = queryDefaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)

        let outputName = outputDeviceID == kAudioObjectUnknown ? "" : (queryDeviceName(deviceID: outputDeviceID) ?? "")
        let inputName = inputDeviceID == kAudioObjectUnknown ? "" : (queryDeviceName(deviceID: inputDeviceID) ?? "")
        let transportType = outputDeviceID == kAudioObjectUnknown ? 0 : queryTransportType(deviceID: outputDeviceID)
        let (dataSourceID, dataSourceName) = outputDeviceID == kAudioObjectUnknown
            ? (nil, nil)
            : queryOutputDataSource(deviceID: outputDeviceID)

        let isBluetoothTransport = transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
        let isBluetoothByName = outputName.localizedCaseInsensitiveContains("airpods")
            || outputName.localizedCaseInsensitiveContains("bluetooth")
        let outputIsBluetooth = isBluetoothTransport || isBluetoothByName

        let headphonesSubTypeFourCC: UInt32 = 0x6864706E // 'hdpn'
        let isHeadphoneDataSource = dataSourceID == headphonesSubTypeFourCC
            || (dataSourceName?.localizedCaseInsensitiveContains("headphone") ?? false)
            || (dataSourceName?.localizedCaseInsensitiveContains("headset") ?? false)
        let isHeadphoneByName = outputName.localizedCaseInsensitiveContains("headphone")
            || outputName.localizedCaseInsensitiveContains("headset")
            || outputName.localizedCaseInsensitiveContains("airpods")
            || outputName.localizedCaseInsensitiveContains("earpods")
            || outputName.localizedCaseInsensitiveContains("earbuds")
            || outputName.localizedCaseInsensitiveContains("beats")
        let outputIsHeadphones = isHeadphoneDataSource || isHeadphoneByName

        return ClickyAudioTopologySnapshot(
            defaultOutputDeviceID: outputDeviceID,
            defaultInputDeviceID: inputDeviceID,
            defaultOutputDeviceName: outputName,
            inputDeviceName: inputName,
            outputIsBluetooth: outputIsBluetooth,
            outputIsHeadphones: outputIsHeadphones,
            outputTransportType: transportType,
            outputDataSourceName: dataSourceName,
            updatedAt: Date()
        )
    }

    nonisolated private static func queryDefaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    nonisolated static func queryDeviceName(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var unmanagedName: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &unmanagedName
        )
        guard status == noErr, let cfName = unmanagedName?.takeRetainedValue() else {
            return nil
        }
        return cfName as String
    }

    nonisolated static func queryTransportType(deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return 0 }

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &transportType
        )
        return status == noErr ? transportType : 0
    }

    nonisolated private static func queryOutputDataSource(deviceID: AudioObjectID) -> (UInt32?, String?) {
        var dataSourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &dataSourceAddress) else {
            return (nil, nil)
        }

        var dataSourceID: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &dataSourceAddress,
            0,
            nil,
            &dataSize,
            &dataSourceID
        )
        guard status == noErr else { return (nil, nil) }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &nameAddress) else {
            return (dataSourceID, nil)
        }

        var unmanagedSourceName: Unmanaged<CFString>?
        var sourceIDCopy = dataSourceID
        var translationStatus: OSStatus = noErr

        withUnsafeMutablePointer(to: &sourceIDCopy) { inputPointer in
            withUnsafeMutablePointer(to: &unmanagedSourceName) { outputPointer in
                var translation = AudioValueTranslation(
                    mInputData: inputPointer,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: outputPointer,
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                translationStatus = AudioObjectGetPropertyData(
                    deviceID,
                    &nameAddress,
                    0,
                    nil,
                    &translationSize,
                    &translation
                )
            }
        }

        var resolvedName: String? = nil
        if translationStatus == noErr,
           let cfString = unmanagedSourceName?.takeRetainedValue() {
            resolvedName = cfString as String
        }

        return (dataSourceID, resolvedName)
    }
}
