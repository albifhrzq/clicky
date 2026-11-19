//
//  ClickyThreeKernel.swift
//  leanring-buddy
//
//  Background JavaScriptCore 3D geometry kernel (clicky-three.js + clicky-three-parts.js)
//  and transparent SceneKit 3D stage overlay renderer for figure() and scene3d() marks.
//

import AppKit
import Foundation
import JavaScriptCore
import QuartzCore
import SceneKit

// MARK: - 3D Geometry Mesh Payload

public nonisolated struct ClickyThreeGeometryMesh: Sendable {
    public let positions: [Float]
    public let normals: [Float]
    public let uvs: [Float]
    public let indices: [UInt32]
    public let samples: [Float]

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
}

public nonisolated enum ClickyThreeKernelError: LocalizedError, Sendable {
    case resourceMissing(String)
    case buildFunctionUnavailable
    case buildFailed(String)
    case invalidMeshPayload

    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let filename):
            return "3D kernel resource missing from bundle: \(filename)"
        case .buildFunctionUnavailable:
            return "clickyThreeBuild is not available in 3D kernel context"
        case .buildFailed(let message):
            return "3D geometry build failed: \(message)"
        case .invalidMeshPayload:
            return "3D geometry build returned malformed typed arrays"
        }
    }
}

// MARK: - Background 3D Kernel (JavaScriptCore)

/// Runs clicky-three.js + clicky-three-parts.js in an isolated background JavaScriptCore VM
/// so heavy procedural/CSG/metaball meshes never block the 2D drawing engine or MainActor.
public final class ClickyThreeKernel: @unchecked Sendable {
    public nonisolated static let shared = ClickyThreeKernel()

    private nonisolated let workerQueue = DispatchQueue(label: "com.clicky.three-kernel", qos: .userInitiated)
    private nonisolated let queueKey = DispatchSpecificKey<UInt8>()
    private nonisolated let queueKeyValue: UInt8 = 1

    private nonisolated let cacheLock = NSLock()
    private nonisolated(unsafe) var meshCache: [String: ClickyThreeGeometryMesh] = [:]

    private nonisolated(unsafe) var virtualMachine: JSVirtualMachine?
    private nonisolated(unsafe) var context: JSContext?
    private nonisolated(unsafe) var initializationError: Error?
    private nonisolated(unsafe) var isInitialized = false

    private nonisolated init() {
        workerQueue.setSpecific(key: queueKey, value: queueKeyValue)
    }

    // MARK: - Public API

    /// Pre-warms the geometry cache asynchronously when a figure() part statement runs.
    public nonisolated func prewarmShape(kind: String, recipeJSON: String) {
        let cacheKey = "\(kind)|\(recipeJSON)"
        if cachedMesh(forKey: cacheKey) != nil { return }
        workerQueue.async { [weak self] in
            guard let self else { return }
            _ = try? self.buildShapeOnWorkerQueue(kind: kind, recipeJSON: recipeJSON)
        }
    }

    /// Async geometry builder for MainActor / Swift Concurrency callers.
    public nonisolated func buildShapeAsync(kind: String, recipeJSON: String) async throws -> ClickyThreeGeometryMesh {
        let cacheKey = "\(kind)|\(recipeJSON)"
        if let cached = cachedMesh(forKey: cacheKey) {
            return cached
        }
        return try await withCheckedThrowingContinuation { continuation in
            workerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ClickyThreeKernelError.buildFailed("Kernel deallocated"))
                    return
                }
                do {
                    let mesh = try self.buildShapeOnWorkerQueue(kind: kind, recipeJSON: recipeJSON)
                    continuation.resume(returning: mesh)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous geometry builder (thread-safe; dispatches onto the kernel queue if needed).
    public nonisolated func buildShape(kind: String, recipeJSON: String) throws -> ClickyThreeGeometryMesh {
        let cacheKey = "\(kind)|\(recipeJSON)"
        if let cached = cachedMesh(forKey: cacheKey) {
            return cached
        }
        if DispatchQueue.getSpecific(key: queueKey) == queueKeyValue {
            return try buildShapeOnWorkerQueue(kind: kind, recipeJSON: recipeJSON)
        }
        return try workerQueue.sync {
            try self.buildShapeOnWorkerQueue(kind: kind, recipeJSON: recipeJSON)
        }
    }

    public nonisolated func clearCache() {
        cacheLock.lock()
        meshCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Internal JSC Execution

    private nonisolated func cachedMesh(forKey key: String) -> ClickyThreeGeometryMesh? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return meshCache[key]
    }

    private nonisolated func storeCachedMesh(_ mesh: ClickyThreeGeometryMesh, forKey key: String) {
        cacheLock.lock()
        if meshCache.count > 256 {
            meshCache.removeAll()
        }
        meshCache[key] = mesh
        cacheLock.unlock()
    }

    private nonisolated func ensureInitialized() throws {
        if isInitialized {
            if let error = initializationError { throw error }
            return
        }
        isInitialized = true

        guard let threeSource = Self.loadBundleScript(named: "clicky-three") else {
            let error = ClickyThreeKernelError.resourceMissing("clicky-three.js")
            initializationError = error
            throw error
        }
        guard let partsSource = Self.loadBundleScript(named: "clicky-three-parts") else {
            let error = ClickyThreeKernelError.resourceMissing("clicky-three-parts.js")
            initializationError = error
            throw error
        }

        let vm = JSVirtualMachine()
        guard let ctx = JSContext(virtualMachine: vm) else {
            let error = ClickyThreeKernelError.buildFailed("Unable to allocate JSContext")
            initializationError = error
            throw error
        }

        var lastException: String?
        ctx.exceptionHandler = { _, exception in
            lastException = exception?.toString() ?? "Unknown JS exception"
        }

        ctx.evaluateScript("if (typeof globalThis === 'undefined') { var globalThis = this; }")
        ctx.evaluateScript(threeSource, withSourceURL: URL(string: "clicky-three.js"))
        if let err = lastException {
            let error = ClickyThreeKernelError.buildFailed(err)
            initializationError = error
            throw error
        }

        ctx.evaluateScript(partsSource, withSourceURL: URL(string: "clicky-three-parts.js"))
        if let err = lastException {
            let error = ClickyThreeKernelError.buildFailed(err)
            initializationError = error
            throw error
        }

        self.virtualMachine = vm
        self.context = ctx
    }

    private nonisolated func buildShapeOnWorkerQueue(kind: String, recipeJSON: String) throws -> ClickyThreeGeometryMesh {
        let cacheKey = "\(kind)|\(recipeJSON)"
        if let cached = cachedMesh(forKey: cacheKey) {
            return cached
        }

        try ensureInitialized()
        guard let ctx = context,
              let buildFn = ctx.objectForKeyedSubscript("clickyThreeBuild"),
              !buildFn.isUndefined else {
            throw ClickyThreeKernelError.buildFunctionUnavailable
        }

        var trappedError: String?
        ctx.exceptionHandler = { _, exception in
            trappedError = exception?.toString() ?? "Unknown JS error"
        }

        guard let result = buildFn.call(withArguments: [kind, recipeJSON]),
              trappedError == nil,
              !result.isUndefined,
              !result.isNull else {
            throw ClickyThreeKernelError.buildFailed(trappedError ?? "clickyThreeBuild returned null")
        }

        guard let positions = Self.extractFloatArray(from: result.objectForKeyedSubscript("positions"), in: ctx),
              let normals = Self.extractFloatArray(from: result.objectForKeyedSubscript("normals"), in: ctx),
              let indices = Self.extractUInt32Array(from: result.objectForKeyedSubscript("indices"), in: ctx) else {
            throw ClickyThreeKernelError.invalidMeshPayload
        }

        let uvs = Self.extractFloatArray(from: result.objectForKeyedSubscript("uvs"), in: ctx) ?? []
        let samples = Self.extractFloatArray(from: result.objectForKeyedSubscript("samples"), in: ctx) ?? []

        let mesh = ClickyThreeGeometryMesh(
            positions: positions,
            normals: normals,
            uvs: uvs,
            indices: indices,
            samples: samples
        )
        storeCachedMesh(mesh, forKey: cacheKey)
        return mesh
    }

    private nonisolated static func loadBundleScript(named name: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: "js")
            ?? Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Resources")
        guard let scriptURL = url else { return nil }
        return try? String(contentsOf: scriptURL, encoding: .utf8)
    }

    private nonisolated static func extractFloatArray(from value: JSValue?, in context: JSContext) -> [Float]? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        let ctxRef = context.jsGlobalContextRef
        let valRef = value.jsValueRef
        var exception: JSValueRef?
        let typedArrayType = JSValueGetTypedArrayType(ctxRef, valRef, &exception)

        if typedArrayType == kJSTypedArrayTypeFloat32Array {
            let objRef = JSValueToObject(ctxRef, valRef, &exception)
            if let objRef,
               let ptr = JSObjectGetTypedArrayBytesPtr(ctxRef, objRef, &exception) {
                let count = JSObjectGetTypedArrayLength(ctxRef, objRef, &exception)
                let floatPtr = ptr.bindMemory(to: Float.self, capacity: count)
                return Array(UnsafeBufferPointer(start: floatPtr, count: count))
            }
        } else if typedArrayType == kJSTypedArrayTypeFloat64Array {
            let objRef = JSValueToObject(ctxRef, valRef, &exception)
            if let objRef,
               let ptr = JSObjectGetTypedArrayBytesPtr(ctxRef, objRef, &exception) {
                let count = JSObjectGetTypedArrayLength(ctxRef, objRef, &exception)
                let doublePtr = ptr.bindMemory(to: Double.self, capacity: count)
                return UnsafeBufferPointer(start: doublePtr, count: count).map { Float($0) }
            }
        }

        if let array = value.toArray() as? [NSNumber] {
            return array.map { $0.floatValue }
        }
        return nil
    }

    private nonisolated static func extractUInt32Array(from value: JSValue?, in context: JSContext) -> [UInt32]? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        let ctxRef = context.jsGlobalContextRef
        let valRef = value.jsValueRef
        var exception: JSValueRef?
        let typedArrayType = JSValueGetTypedArrayType(ctxRef, valRef, &exception)

        if typedArrayType == kJSTypedArrayTypeUint32Array {
            let objRef = JSValueToObject(ctxRef, valRef, &exception)
            if let objRef,
               let ptr = JSObjectGetTypedArrayBytesPtr(ctxRef, objRef, &exception) {
                let count = JSObjectGetTypedArrayLength(ctxRef, objRef, &exception)
                let uintPtr = ptr.bindMemory(to: UInt32.self, capacity: count)
                return Array(UnsafeBufferPointer(start: uintPtr, count: count))
            }
        } else if typedArrayType == kJSTypedArrayTypeUint16Array {
            let objRef = JSValueToObject(ctxRef, valRef, &exception)
            if let objRef,
               let ptr = JSObjectGetTypedArrayBytesPtr(ctxRef, objRef, &exception) {
                let count = JSObjectGetTypedArrayLength(ctxRef, objRef, &exception)
                let u16Ptr = ptr.bindMemory(to: UInt16.self, capacity: count)
                return UnsafeBufferPointer(start: u16Ptr, count: count).map { UInt32($0) }
            }
        } else if typedArrayType == kJSTypedArrayTypeInt32Array {
            let objRef = JSValueToObject(ctxRef, valRef, &exception)
            if let objRef,
               let ptr = JSObjectGetTypedArrayBytesPtr(ctxRef, objRef, &exception) {
                let count = JSObjectGetTypedArrayLength(ctxRef, objRef, &exception)
                let i32Ptr = ptr.bindMemory(to: Int32.self, capacity: count)
                return UnsafeBufferPointer(start: i32Ptr, count: count).map { UInt32(max(0, $0)) }
            }
        }

        if let array = value.toArray() as? [NSNumber] {
            return array.map { $0.uint32Value }
        }
        return nil
    }
}

// MARK: - SceneKit 3D Overlay Renderer

/// Transparent SceneKit stage view for `figure()` and `scene3d()` marks.
/// Supports procedural Three.js meshes from `ClickyThreeKernel`, studio lighting,
/// per-frame `tick3d` poses, `motion3d` animations, `camera3d` framing, and 3D-to-2D label projection.
@MainActor
public final class ClickyThreeStageView: NSView, SCNSceneRendererDelegate {

    public struct LabelProjection: Sendable {
        public let id: String
        public let text: String
        public let point2D: CGPoint
        public let side: String?
        public let size: CGFloat
        public let color: NSColor
    }

    public let stageID: String
    public var onTickSample: ((_ stageID: String, _ ticks: [(id: String, elapsed: Double)], _ dt: Double) -> [Float]?)?
    public var onProjectedLabelsUpdated: (([LabelProjection]) -> Void)?

    private let scnView: SCNView
    private let scene = SCNScene()
    private let worldRootNode = SCNNode()
    private let cameraOrbitNode = SCNNode()
    private let cameraPitchNode = SCNNode()
    private let cameraNode = SCNNode()

    private var partNodesByID: [String: SCNNode] = [:]
    private var partNumberToID: [Int: String] = [:]
    private var partBaseTransforms: [String: (pos: SCNVector3, rot: SCNVector3, scale: CGFloat)] = [:]
    private var activeTicks: [(id: String, startTime: CFTimeInterval)] = []
    private var labels3D: [Label3DRecord] = []

    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var autoSpinRateRadPerSec: Double = 0.08
    private var cameraTiltDeg: Double = 15
    private var cameraTurnDeg: Double = 0
    private var cameraZoom: Double = 1.0
    private var cameraFOV: Double = 35
    private var cameraTarget = SCNVector3(0, 0, 0)
    private var baseCameraDistance: Double = 6.0
    private var isStudioLook: Bool = true
    private var sampleCloudPoints: [SCNVector3] = []

    private var userYawOffset: Double = 0
    private var userPitchOffset: Double = 0
    private var userZoomFactor: Double = 1.0
    private var lastDragPoint: NSPoint?

    // Render-on-demand bookkeeping: the stage renders continuously only while something moves.
    private let stageAppearedAt: CFTimeInterval = CACurrentMediaTime()
    private var hasRunningMotions = false
    private var interactionUntil: CFTimeInterval = 0
    private var animationUntil: CFTimeInterval = 0
    private var labelsNeedProjection = true
    private var lastSentLabelPoints: [ClickyThreeLabelPoint]?
    private var lastLabelSendTime: CFTimeInterval = 0
    private var isRenderingContinuously = true
    /// Read from the SceneKit render thread; a stale Bool only costs one extra or one skipped hop.
    private nonisolated(unsafe) var needsFrameStepFlag = true

    private struct Label3DRecord {
        let id: String
        let text: String
        let point: SCNVector3?
        let followPartID: String?
        let side: String?
        let size: CGFloat
        let color: NSColor
    }

    public init(stageID: String, frame: NSRect, look: String?, cameraJSON: String?) {
        self.stageID = stageID
        self.isStudioLook = (look == "studio")
        self.scnView = SCNView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scnView.autoresizingMask = [.width, .height]
        scnView.scene = scene
        scnView.backgroundColor = .clear
        scnView.wantsLayer = true
        scnView.layer?.backgroundColor = NSColor.clear.cgColor
        scnView.antialiasingMode = .multisampling2X
        scnView.preferredFramesPerSecond = 30
        scnView.isPlaying = true
        scnView.loops = true
        scnView.allowsCameraControl = false
        scnView.delegate = self

        addSubview(scnView)

        setupSceneAndLighting()
        if let cameraJSON {
            applyCameraConfig(jsonString: cameraJSON)
        }
        updateCameraRig(animated: false)
        refreshRenderingMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSceneAndLighting() {
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(worldRootNode)

        cameraOrbitNode.addChildNode(cameraPitchNode)
        cameraPitchNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(cameraOrbitNode)

        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(cameraFOV)
        camera.zNear = 0.05
        camera.zFar = 200
        cameraNode.camera = camera
        scnView.pointOfView = cameraNode

        // Three-point studio lighting so metallic/ceramic/glass surfaces catch crisp highlights.
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = NSColor(white: 0.78, alpha: 1.0)
        ambientLight.intensity = isStudioLook ? 520 : 750
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.95, alpha: 1.0)
        keyLight.intensity = isStudioLook ? 1100 : 850
        keyLight.castsShadow = false
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-0.75, 0.55, 0)
        scene.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.color = NSColor(calibratedRed: 0.85, green: 0.92, blue: 1.0, alpha: 1.0)
        fillLight.intensity = 450
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.eulerAngles = SCNVector3(0.35, -0.95, 0)
        scene.rootNode.addChildNode(fillNode)

        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.color = NSColor.white
        rimLight.intensity = 550
        let rimNode = SCNNode()
        rimNode.light = rimLight
        rimNode.eulerAngles = SCNVector3(0.35, Double.pi * 0.85, 0)
        scene.rootNode.addChildNode(rimNode)
    }

    // MARK: - Stage Operations

    public func addOrUpdatePart(partJSON: String) {
        guard let data = partJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let partID = dict["id"] as? String else { return }

        let kind = (dict["kind"] as? String) ?? "box"
        let isThree = (dict["three"] as? Bool) ?? false
        let parentID = dict["parent"] as? String

        let posArr = (dict["at"] as? [NSNumber])?.map { $0.doubleValue } ?? [0, 0, 0]
        let rotArr = (dict["rotate"] as? [NSNumber])?.map { $0.doubleValue } ?? [0, 0, 0]
        let scaleVal = (dict["scale"] as? NSNumber)?.doubleValue ?? 1.0
        let materialDict = dict["material"] as? [String: Any] ?? [:]

        let node: SCNNode
        if let existing = partNodesByID[partID] {
            node = existing
        } else {
            node = SCNNode()
            node.name = partID
            partNodesByID[partID] = node
            if let suffixNumber = Self.extractPartNumber(from: partID) {
                partNumberToID[suffixNumber] = partID
            }

            let parentNode = parentID.flatMap { partNodesByID[$0] } ?? worldRootNode
            parentNode.addChildNode(node)

            // Grow-in entrance animation matching engine's part3d 'grow'
            node.opacity = 0
            node.scale = SCNVector3(0.82, 0.82, 0.82)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.42
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            node.opacity = 1
            node.scale = SCNVector3(scaleVal, scaleVal, scaleVal)
            SCNTransaction.commit()
            keepRenderingForAnimation(seconds: 0.5)
        }

        let posVec = SCNVector3(
            posArr.count > 0 ? posArr[0] : 0,
            posArr.count > 1 ? posArr[1] : 0,
            posArr.count > 2 ? posArr[2] : 0
        )
        let rotVec = SCNVector3(
            (rotArr.count > 0 ? rotArr[0] : 0) * .pi / 180.0,
            (rotArr.count > 1 ? rotArr[1] : 0) * .pi / 180.0,
            (rotArr.count > 2 ? rotArr[2] : 0) * .pi / 180.0
        )
        node.position = posVec
        node.eulerAngles = rotVec
        node.scale = SCNVector3(scaleVal, scaleVal, scaleVal)
        partBaseTransforms[partID] = (posVec, rotVec, CGFloat(scaleVal))

        markSceneChanged()
        if kind == "group" {
            return
        }

        let recipeJSON: String
        if isThree, let explicitRecipe = dict["recipe"] as? String {
            recipeJSON = explicitRecipe
        } else if let params = dict["params"] as? [String: Any],
                  let pData = try? JSONSerialization.data(withJSONObject: params),
                  let pStr = String(data: pData, encoding: .utf8) {
            recipeJSON = pStr
        } else {
            recipeJSON = "{}"
        }

        let scnMat = makeSCNMaterial(from: materialDict)
        let capturedPartID = partID
        let capturedPos = posVec

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let mesh = try await ClickyThreeKernel.shared.buildShapeAsync(kind: kind, recipeJSON: recipeJSON)
                guard let targetNode = self.partNodesByID[capturedPartID] else { return }
                let geometry = Self.makeSCNGeometry(from: mesh)
                geometry.materials = [scnMat]
                targetNode.geometry = geometry
                self.recordSamples(mesh.samples, offset: capturedPos)
                self.refitCameraDistance()
                self.markSceneChanged()
            } catch {
                // Fallback primitive if a custom recipe fails
                guard let targetNode = self.partNodesByID[capturedPartID] else { return }
                let fallback = SCNBox(width: 0.4, height: 0.4, length: 0.4, chamferRadius: 0.04)
                fallback.materials = [scnMat]
                targetNode.geometry = fallback
                self.markSceneChanged()
            }
        }
    }

    public func addTick(tickID: String) {
        if !activeTicks.contains(where: { $0.id == tickID }) {
            activeTicks.append((id: tickID, startTime: CACurrentMediaTime()))
            refreshRenderingMode()
        }
    }

    public func applyMotion(opJSON: String) {
        guard let data = opJSON.data(using: .utf8),
              let op = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let targetID = op["target"] as? String,
              let node = partNodesByID[targetID],
              let kind = op["kind"] as? String else { return }

        let period = (op["period"] as? NSNumber)?.doubleValue ?? 4.0

        switch kind {
        case "spin":
            let axis = vector3(op["axis"], default: SCNVector3(0, 1, 0))
            let action = SCNAction.repeatForever(
                SCNAction.rotate(by: .pi * 2, around: axis, duration: max(0.2, period))
            )
            node.runAction(action, forKey: "spin")
            hasRunningMotions = true

        case "bob":
            let axis = vector3(op["axis"], default: SCNVector3(0, 1, 0))
            let amount = (op["amount"] as? NSNumber)?.doubleValue ?? 0.1
            let delta = SCNVector3(axis.x * amount, axis.y * amount, axis.z * amount)
            let neg = SCNVector3(-delta.x, -delta.y, -delta.z)
            let half = max(0.1, period / 2.0)
            let up = SCNAction.move(by: delta, duration: half)
            up.timingMode = .easeInEaseOut
            let down = SCNAction.move(by: neg, duration: half)
            down.timingMode = .easeInEaseOut
            node.runAction(SCNAction.repeatForever(SCNAction.sequence([up, down])), forKey: "bob")
            hasRunningMotions = true

        case "pulse":
            let amount = (op["amount"] as? NSNumber)?.doubleValue ?? 0.08
            let baseScale = partBaseTransforms[targetID]?.scale ?? 1.0
            let half = max(0.1, period / 2.0)
            let grow = SCNAction.scale(to: baseScale * CGFloat(1.0 + amount), duration: half)
            grow.timingMode = .easeInEaseOut
            let shrink = SCNAction.scale(to: baseScale, duration: half)
            shrink.timingMode = .easeInEaseOut
            node.runAction(SCNAction.repeatForever(SCNAction.sequence([grow, shrink])), forKey: "pulse")
            hasRunningMotions = true

        case "orbit":
            let axis = vector3(op["axis"], default: SCNVector3(0, 1, 0))
            let center = vector3(op["center"], default: SCNVector3(0, 0, 0))
            let startPos = node.position
            let duration = max(0.2, period)
            let action = SCNAction.customAction(duration: duration) { targetNode, elapsed in
                let angle = Double(elapsed) / duration * .pi * 2.0
                let rel = SCNVector3(startPos.x - center.x, startPos.y - center.y, startPos.z - center.z)
                let rotated = Self.rotateVector(rel, around: axis, by: angle)
                targetNode.position = SCNVector3(center.x + rotated.x, center.y + rotated.y, center.z + rotated.z)
            }
            node.runAction(SCNAction.repeatForever(action), forKey: "orbit")
            hasRunningMotions = true

        case "path":
            guard let rawPoints = op["points"] as? [[NSNumber]], rawPoints.count >= 2 else { return }
            let pts = rawPoints.map { vector3($0, default: SCNVector3(0, 0, 0)) }
            let closed = (op["closed"] as? Bool) ?? true
            let once = (op["once"] as? Bool) ?? false
            var actions: [SCNAction] = []
            let segDuration = max(0.05, period / Double(max(1, pts.count - 1)))
            node.position = pts[0]
            for pt in pts.dropFirst() {
                actions.append(SCNAction.move(to: pt, duration: segDuration))
            }
            if closed {
                actions.append(SCNAction.move(to: pts[0], duration: segDuration))
            }
            let seq = SCNAction.sequence(actions)
            node.runAction(once ? seq : SCNAction.repeatForever(seq), forKey: "path")
            if once {
                keepRenderingForAnimation(seconds: period + 0.5)
            } else {
                hasRunningMotions = true
            }

        case "tween":
            SCNTransaction.begin()
            SCNTransaction.animationDuration = max(0.05, period)
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if let toArr = op["to"] as? [NSNumber], toArr.count >= 3 {
                node.position = SCNVector3(toArr[0].doubleValue, toArr[1].doubleValue, toArr[2].doubleValue)
            }
            if let rotArr = op["rot"] as? [NSNumber], rotArr.count >= 3 {
                node.eulerAngles = SCNVector3(
                    rotArr[0].doubleValue * .pi / 180.0,
                    rotArr[1].doubleValue * .pi / 180.0,
                    rotArr[2].doubleValue * .pi / 180.0
                )
            }
            SCNTransaction.commit()
            keepRenderingForAnimation(seconds: max(0.05, period) + 0.2)

        case "set":
            if let show = op["show"] as? Bool {
                node.isHidden = !show
            }
            if let scale = (op["scale"] as? NSNumber)?.doubleValue {
                node.scale = SCNVector3(scale, scale, scale)
            }
            if let glow = (op["glow"] as? NSNumber)?.doubleValue,
               let mat = node.geometry?.firstMaterial {
                mat.emission.intensity = CGFloat(glow)
            }
            if let colorHex = op["color"] as? String,
               let color = NSColor.clickyHex(colorHex),
               let mat = node.geometry?.firstMaterial {
                mat.diffuse.contents = color
            }

        default:
            break
        }
        markSceneChanged()
    }

    public func applyCameraConfig(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let cam = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if let tilt = (cam["tilt"] as? NSNumber)?.doubleValue { cameraTiltDeg = tilt }
        if let fov = (cam["fov"] as? NSNumber)?.doubleValue { cameraFOV = fov }
        if let spin = (cam["spin"] as? NSNumber)?.doubleValue {
            // Engine spin 0.7 -> ~0.08..0.25 rad/s gentle turn
            autoSpinRateRadPerSec = spin * 0.14
        }
        if let turn = (cam["turn"] as? NSNumber)?.doubleValue { cameraTurnDeg = turn }
        if let zoom = (cam["zoom"] as? NSNumber)?.doubleValue { cameraZoom = max(0.35, min(3.5, zoom)) }
        if let targetArr = cam["target"] as? [NSNumber], targetArr.count >= 3 {
            cameraTarget = SCNVector3(targetArr[0].doubleValue, targetArr[1].doubleValue, targetArr[2].doubleValue)
        }
        updateCameraRig(animated: true)
        refreshRenderingMode()
    }

    public func addLabel(labelJSON: String, fallbackColor: NSColor) {
        guard let data = labelJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = dict["id"] as? String,
              let text = dict["text"] as? String else { return }

        let pt: SCNVector3? = (dict["point"] as? [NSNumber]).flatMap { arr in
            arr.count >= 3 ? SCNVector3(arr[0].doubleValue, arr[1].doubleValue, arr[2].doubleValue) : nil
        }
        let follow = dict["follow"] as? String
        let side = dict["side"] as? String
        let size = CGFloat((dict["size"] as? NSNumber)?.doubleValue ?? 19.0)

        let record = Label3DRecord(
            id: id,
            text: text,
            point: pt,
            followPartID: follow,
            side: side,
            size: size,
            color: fallbackColor
        )
        labels3D.removeAll { $0.id == id }
        labels3D.append(record)
        lastSentLabelPoints = nil
        markSceneChanged()
    }

    /// Moves/resizes the stage; label projections must be re-sent because their origin changed.
    public func updateStageFrame(_ newFrame: NSRect) {
        guard newFrame != frame else { return }
        frame = newFrame
        lastSentLabelPoints = nil
        markSceneChanged()
    }

    public func removePart(id: String) {
        if let node = partNodesByID.removeValue(forKey: id) {
            node.removeFromParentNode()
        }
        markSceneChanged()
    }

    // MARK: - SCNSceneRendererDelegate

    nonisolated public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // Skip the main-actor hop entirely when nothing needs a per-frame step.
        guard needsFrameStepFlag else { return }
        Task { @MainActor [weak self] in
            self?.stepFrame(at: time)
        }
    }

    // MARK: - Render-on-demand

    private var renderDemand: ClickyThreeRenderDemand {
        let now = CACurrentMediaTime()
        return ClickyThreeRenderDemand(
            hasActiveTicks: !activeTicks.isEmpty,
            hasRunningMotions: hasRunningMotions,
            isAutoSpinning: ClickyThreeRenderDemand.isAutoSpinActive(
                spinRate: autoSpinRateRadPerSec,
                secondsSinceAppeared: now - stageAppearedAt,
                isDragging: lastDragPoint != nil
            ),
            isUserInteracting: lastDragPoint != nil || now < interactionUntil,
            isAnimating: now < animationUntil
        )
    }

    /// Starts/stops continuous rendering to match what is moving right now.
    private func refreshRenderingMode() {
        let shouldRenderContinuously = renderDemand.needsContinuousRendering
        if shouldRenderContinuously != isRenderingContinuously {
            isRenderingContinuously = shouldRenderContinuously
            scnView.isPlaying = shouldRenderContinuously
            // One last pass so labels and the final pose settle after motion stops.
            if !shouldRenderContinuously { markSceneChanged() }
        }
        needsFrameStepFlag = shouldRenderContinuously || labelsNeedProjection
    }

    private func keepRenderingForAnimation(seconds: CFTimeInterval) {
        animationUntil = max(animationUntil, CACurrentMediaTime() + seconds)
        refreshRenderingMode()
    }

    private func markUserInteraction() {
        interactionUntil = CACurrentMediaTime() + 0.5
        refreshRenderingMode()
    }

    /// Something changed in the scene: redraw once (even when not playing) and re-project labels.
    private func markSceneChanged() {
        labelsNeedProjection = true
        needsFrameStepFlag = true
        scnView.needsDisplay = true
    }

    private func stepFrame(at now: CFTimeInterval) {
        let dt = min(0.05, max(1.0 / 120.0, now - lastFrameTime))
        lastFrameTime = now
        let wallClock = CACurrentMediaTime()

        let isSpinning = ClickyThreeRenderDemand.isAutoSpinActive(
            spinRate: autoSpinRateRadPerSec,
            secondsSinceAppeared: wallClock - stageAppearedAt,
            isDragging: lastDragPoint != nil
        )
        if isSpinning {
            cameraTurnDeg += autoSpinRateRadPerSec * dt * 180.0 / .pi
            cameraOrbitNode.eulerAngles.y = CGFloat((cameraTurnDeg + userYawOffset) * .pi / 180.0)
        }

        if !activeTicks.isEmpty, let onTickSample {
            let tickInputs = activeTicks.map { ($0.id, now - $0.startTime) }
            if let flatPoses = onTickSample(stageID, tickInputs, dt) {
                applyTickPoses(flatPoses)
            }
        }

        projectLabelsIfNeeded(wallClock: wallClock)
        labelsNeedProjection = false
        refreshRenderingMode()
    }

    private func projectLabelsIfNeeded(wallClock: CFTimeInterval) {
        guard !labels3D.isEmpty, let onProjectedLabelsUpdated else { return }
        // At most ~30 fps while rendering continuously, unless the scene itself changed.
        if isRenderingContinuously, !labelsNeedProjection,
           wallClock - lastLabelSendTime < ClickyThreeLabelProjectionDelta.minimumSendInterval { return }

        var projected: [LabelProjection] = []
        projected.reserveCapacity(labels3D.count)
        for lbl in labels3D {
            let worldPos: SCNVector3
            if let followID = lbl.followPartID, let node = partNodesByID[followID] {
                worldPos = node.worldPosition
            } else if let pt = lbl.point {
                worldPos = pt
            } else {
                continue
            }
            let proj = scnView.projectPoint(worldPos)
            // projectPoint returns y bottom-up in SCNView coordinates; convert to view top-down
            let pt2D = CGPoint(x: proj.x, y: bounds.height - proj.y)
            projected.append(LabelProjection(
                id: lbl.id,
                text: lbl.text,
                point2D: pt2D,
                side: lbl.side,
                size: lbl.size,
                color: lbl.color
            ))
        }
        let projectedPoints = projected.map { ClickyThreeLabelPoint(id: $0.id, point: $0.point2D) }
        guard ClickyThreeLabelProjectionDelta.hasMeaningfulChange(
            previous: lastSentLabelPoints, current: projectedPoints
        ) else { return }
        lastSentLabelPoints = projectedPoints
        lastLabelSendTime = wallClock
        onProjectedLabelsUpdated(projected)
    }

    private func applyTickPoses(_ flat: [Float]) {
        // 14 floats per part: n, mask, px, py, pz, rx, ry, rz, scale, show, glow, r, g, b
        let stride = 14
        var index = 0
        while index + stride <= flat.count {
            let partNumber = Int(flat[index])
            let mask = Int(flat[index + 1])
            if let partID = partNumberToID[partNumber], let node = partNodesByID[partID] {
                if (mask & 1) != 0 {
                    node.position = SCNVector3(flat[index + 2], flat[index + 3], flat[index + 4])
                }
                if (mask & 2) != 0 {
                    node.eulerAngles = SCNVector3(
                        Double(flat[index + 5]) * .pi / 180.0,
                        Double(flat[index + 6]) * .pi / 180.0,
                        Double(flat[index + 7]) * .pi / 180.0
                    )
                }
                if (mask & 4) != 0 {
                    let s = CGFloat(flat[index + 8])
                    node.scale = SCNVector3(s, s, s)
                }
                if (mask & 8) != 0 {
                    node.isHidden = flat[index + 9] < 0.5
                }
                if (mask & 16) != 0, let mat = node.geometry?.firstMaterial {
                    mat.emission.intensity = CGFloat(flat[index + 10])
                }
                if (mask & 32) != 0, let mat = node.geometry?.firstMaterial {
                    mat.diffuse.contents = NSColor(
                        srgbRed: CGFloat(flat[index + 11]),
                        green: CGFloat(flat[index + 12]),
                        blue: CGFloat(flat[index + 13]),
                        alpha: 1.0
                    )
                }
            }
            index += stride
        }
    }

    // MARK: - Interactive Orbit / Zoom

    /// The SceneKit child must not swallow events: the stage itself handles drag, scroll and pinch.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) && !isHidden ? self : nil
    }

    /// The overlay panel is non-key, so the first click must already start an orbit.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
        markUserInteraction()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let prev = lastDragPoint else { return }
        let cur = convert(event.locationInWindow, from: nil)
        let dx = Double(cur.x - prev.x)
        let dy = Double(cur.y - prev.y)
        lastDragPoint = cur

        userYawOffset -= dx * 0.45
        userPitchOffset = max(-75, min(75, userPitchOffset + dy * 0.45))
        updateCameraRig(animated: false)
        markUserInteraction()
    }

    public override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        interactionUntil = CACurrentMediaTime() + 0.3
        refreshRenderingMode()
    }

    public override func scrollWheel(with event: NSEvent) {
        let factor = ClickyThreeZoom.scrollFactor(
            deltaY: Double(event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas
        )
        applyUserZoom(factor: factor)
    }

    public override func magnify(with event: NSEvent) {
        applyUserZoom(factor: ClickyThreeZoom.magnifyFactor(magnification: Double(event.magnification)))
    }

    private func applyUserZoom(factor: Double) {
        userZoomFactor = ClickyThreeZoom.clamped(userZoomFactor * factor)
        updateCameraRig(animated: false)
        markUserInteraction()
    }

    // MARK: - Helpers

    private func updateCameraRig(animated: Bool) {
        let apply = {
            self.cameraOrbitNode.position = self.cameraTarget
            self.cameraOrbitNode.eulerAngles.y = CGFloat((self.cameraTurnDeg + self.userYawOffset) * .pi / 180.0)
            let totalTilt = max(-85, min(85, self.cameraTiltDeg + self.userPitchOffset))
            self.cameraPitchNode.eulerAngles.x = CGFloat(-totalTilt * .pi / 180.0)
            self.cameraNode.position = SCNVector3(0.0, 0.0, self.baseCameraDistance / max(0.15, self.cameraZoom * self.userZoomFactor))
            self.cameraNode.camera?.fieldOfView = CGFloat(self.cameraFOV)
        }
        markSceneChanged()
        if animated {
            keepRenderingForAnimation(seconds: 0.6)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.45
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            apply()
            SCNTransaction.commit()
        } else {
            apply()
        }
    }

    private func recordSamples(_ flatSamples: [Float], offset: SCNVector3) {
        var i = 0
        while i + 2 < flatSamples.count {
            sampleCloudPoints.append(SCNVector3(
                Double(flatSamples[i]) + Double(offset.x),
                Double(flatSamples[i + 1]) + Double(offset.y),
                Double(flatSamples[i + 2]) + Double(offset.z)
            ))
            i += 3
        }
    }

    private func refitCameraDistance() {
        guard !sampleCloudPoints.isEmpty else { return }
        var minV = SCNVector3(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
        var maxV = SCNVector3(-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for p in sampleCloudPoints {
            minV.x = min(minV.x, p.x); minV.y = min(minV.y, p.y); minV.z = min(minV.z, p.z)
            maxV.x = max(maxV.x, p.x); maxV.y = max(maxV.y, p.y); maxV.z = max(maxV.z, p.z)
        }
        let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
        let dx = Double(maxV.x - minV.x)
        let dy = Double(maxV.y - minV.y)
        let dz = Double(maxV.z - minV.z)
        let radius = max(0.6, sqrt(dx * dx + dy * dy + dz * dz) / 2.0)
        let fovRad = max(15.0, cameraFOV) * .pi / 180.0
        baseCameraDistance = max(2.2, (radius / sin(fovRad / 2.0)) * 1.18)
        cameraTarget = center
        updateCameraRig(animated: false)
    }

    private func makeSCNMaterial(from dict: [String: Any]) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = isStudioLook ? .physicallyBased : .blinn

        let matKind = (dict["mat"] as? String)?.lowercased() ?? "gloss"
        let tintHex = (dict["tint"] as? String) ?? (dict["color"] as? String) ?? "#8E9299"
        let baseColor = NSColor.clickyHex(tintHex) ?? NSColor(white: 0.72, alpha: 1.0)

        var roughness: Double = (dict["roughness"] as? NSNumber)?.doubleValue ?? 0.45
        var metalness: Double = (dict["metalness"] as? NSNumber)?.doubleValue ?? 0.1
        var opacity: Double = (dict["opacity"] as? NSNumber)?.doubleValue ?? 1.0
        var diffuseColor = baseColor

        switch matKind {
        case "steel", "metal":
            metalness = 0.88; roughness = 0.28
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.68, green: 0.71, blue: 0.75, alpha: 1) }
        case "alu", "aluminum", "aluminium":
            metalness = 0.85; roughness = 0.34
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.87, alpha: 1) }
        case "chrome":
            metalness = 1.0; roughness = 0.08
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: 1) }
        case "titanium":
            metalness = 0.86; roughness = 0.30
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.54, green: 0.56, blue: 0.58, alpha: 1) }
        case "brass":
            metalness = 0.9; roughness = 0.26
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.78, green: 0.63, blue: 0.28, alpha: 1) }
        case "copper":
            metalness = 0.9; roughness = 0.26
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.79, green: 0.44, blue: 0.31, alpha: 1) }
        case "gold":
            metalness = 0.95; roughness = 0.20
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.92, green: 0.74, blue: 0.26, alpha: 1) }
        case "iron":
            metalness = 0.75; roughness = 0.58
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.32, green: 0.33, blue: 0.35, alpha: 1) }
        case "black", "rubber":
            metalness = 0.0; roughness = 0.82
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.17, alpha: 1) }
        case "glass", "water":
            metalness = 0.05; roughness = 0.06
            opacity = min(opacity, matKind == "water" ? 0.55 : 0.35)
            if dict["tint"] == nil && dict["color"] == nil { diffuseColor = NSColor(srgbRed: 0.78, green: 0.90, blue: 0.98, alpha: 1) }
        case "wood", "paper", "matte", "soft":
            metalness = 0.0; roughness = 0.78
        case "ceramic", "gloss", "paint", "plastic":
            metalness = 0.04; roughness = 0.22
        case "glow":
            metalness = 0.0; roughness = 0.3
            material.emission.contents = baseColor
            material.emission.intensity = CGFloat((dict["emissiveIntensity"] as? NSNumber)?.doubleValue ?? 1.2)
        default:
            break
        }

        material.diffuse.contents = diffuseColor
        material.roughness.contents = NSNumber(value: roughness)
        material.metalness.contents = NSNumber(value: metalness)
        material.transparency = CGFloat(opacity)
        material.isDoubleSided = (dict["double"] as? Bool) ?? (opacity < 0.99)

        if let emissiveHex = dict["emissive"] as? String, let emissiveColor = NSColor.clickyHex(emissiveHex) {
            material.emission.contents = emissiveColor
            material.emission.intensity = CGFloat((dict["emissiveIntensity"] as? NSNumber)?.doubleValue ?? 0.8)
        } else if let glowVal = (dict["glow"] as? NSNumber)?.doubleValue, glowVal > 0 {
            material.emission.contents = baseColor
            material.emission.intensity = CGFloat(glowVal)
        }

        return material
    }

    private nonisolated static func makeSCNGeometry(from mesh: ClickyThreeGeometryMesh) -> SCNGeometry {
        let vertexCount = mesh.positions.count / 3
        let positionData = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let positionSource = SCNGeometrySource(
            data: positionData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        var sources = [positionSource]
        if mesh.normals.count == mesh.positions.count {
            let normalData = mesh.normals.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: normalData,
                semantic: .normal,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 3
            ))
        }

        if mesh.uvs.count == vertexCount * 2 {
            let uvData = mesh.uvs.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: uvData,
                semantic: .texcoord,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 2,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 2
            ))
        }

        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: mesh.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        return SCNGeometry(sources: sources, elements: [element])
    }

    private func vector3(_ any: Any?, default fallback: SCNVector3) -> SCNVector3 {
        guard let arr = any as? [NSNumber], arr.count >= 3 else { return fallback }
        return SCNVector3(arr[0].doubleValue, arr[1].doubleValue, arr[2].doubleValue)
    }

    private static func rotateVector(_ v: SCNVector3, around axis: SCNVector3, by angle: Double) -> SCNVector3 {
        let len = sqrt(Double(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z))
        guard len > 1e-6 else { return v }
        let ux = Double(axis.x) / len, uy = Double(axis.y) / len, uz = Double(axis.z) / len
        let c = cos(angle), s = sin(angle), oneMinusC = 1.0 - c
        let vx = Double(v.x), vy = Double(v.y), vz = Double(v.z)
        let dot = ux * vx + uy * vy + uz * vz
        let crossX = uy * vz - uz * vy
        let crossY = uz * vx - ux * vz
        let crossZ = ux * vy - uy * vx
        return SCNVector3(
            vx * c + crossX * s + ux * dot * oneMinusC,
            vy * c + crossY * s + uy * dot * oneMinusC,
            vz * c + crossZ * s + uz * dot * oneMinusC
        )
    }

    private static func extractPartNumber(from partID: String) -> Int? {
        guard let range = partID.range(of: #"p(\d+)$"#, options: .regularExpression) else { return nil }
        return Int(partID[range].dropFirst())
    }
}

// MARK: - Color Parsing Helper

extension NSColor {
    static func clickyHex(_ raw: String) -> NSColor? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "none", trimmed != "transparent" else { return nil }
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1.0)
    }
}


// MARK: - Pure helpers (render policy, zoom, label deltas, label placement)

nonisolated struct ClickyThreeLabelPoint: Equatable, Sendable {
    let id: String
    let point: CGPoint
}

/// Decides whether the SceneKit stage must render every frame or only on demand.
nonisolated struct ClickyThreeRenderDemand: Sendable {
    var hasActiveTicks: Bool
    var hasRunningMotions: Bool
    var isAutoSpinning: Bool
    var isUserInteracting: Bool
    var isAnimating: Bool

    /// Seconds the idle auto-spin runs after the stage appears.
    static let autoSpinDurationSeconds: Double = 6

    var needsContinuousRendering: Bool {
        hasActiveTicks || hasRunningMotions || isAutoSpinning || isUserInteracting || isAnimating
    }

    static func isAutoSpinActive(spinRate: Double, secondsSinceAppeared: Double, isDragging: Bool) -> Bool {
        spinRate != 0 && !isDragging && secondsSinceAppeared < autoSpinDurationSeconds
    }
}

nonisolated enum ClickyThreeZoom {
    static let minimumUserZoom: Double = 0.4
    static let maximumUserZoom: Double = 4.0

    static func clamped(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(maximumUserZoom, max(minimumUserZoom, zoom))
    }

    /// Positive scroll (up) zooms in. Trackpads report small pixel deltas, mice report line deltas.
    static func scrollFactor(deltaY: Double, isPrecise: Bool) -> Double {
        let clampedDelta = max(-40, min(40, deltaY))
        return exp(clampedDelta * (isPrecise ? 0.01 : 0.06))
    }

    static func magnifyFactor(magnification: Double) -> Double {
        max(0.2, 1 + max(-0.8, min(2, magnification)))
    }
}

nonisolated enum ClickyThreeLabelProjectionDelta {
    static let minimumSendInterval: Double = 1.0 / 30.0
    static let pixelTolerance: CGFloat = 0.5

    /// True when labels were never sent, the label set changed, or any point moved more than the tolerance.
    static func hasMeaningfulChange(
        previous: [ClickyThreeLabelPoint]?,
        current: [ClickyThreeLabelPoint],
        tolerance: CGFloat = pixelTolerance
    ) -> Bool {
        guard let previous, previous.count == current.count else { return true }
        for (oldLabel, newLabel) in zip(previous, current) {
            if oldLabel.id != newLabel.id { return true }
            if abs(oldLabel.point.x - newLabel.point.x) > tolerance { return true }
            if abs(oldLabel.point.y - newLabel.point.y) > tolerance { return true }
        }
        return false
    }
}

nonisolated enum ClickyLabelPlacement {
    struct Result: Equatable {
        /// X to use as the text anchor (matches the anchor implied by `side`).
        let anchorX: CGFloat
        let centerY: CGFloat
        let side: String?
    }

    /// Keeps a label of `labelSize` inside `visibleBounds` (minus `margin`): flips left/right when the label would
    /// cross an edge, then clamps whatever overflow remains.
    static func place(
        point: CGPoint,
        side: String?,
        labelSize: CGSize,
        visibleBounds: CGRect,
        margin: CGFloat = 6,
        gap: CGFloat = 12
    ) -> Result {
        let minX = visibleBounds.minX + margin
        let maxX = visibleBounds.maxX - margin
        let minY = visibleBounds.minY + margin + labelSize.height / 2
        let maxY = visibleBounds.maxY - margin - labelSize.height / 2

        func span(for currentSide: String?) -> (start: CGFloat, end: CGFloat) {
            switch currentSide {
            case "left": return (point.x - gap - labelSize.width, point.x - gap)
            case "right": return (point.x + gap, point.x + gap + labelSize.width)
            default: return (point.x - labelSize.width / 2, point.x + labelSize.width / 2)
            }
        }

        var resolvedSide = side
        var current = span(for: side)
        if side == "left", current.start < minX {
            let flipped = span(for: "right")
            if flipped.end <= maxX { resolvedSide = "right"; current = flipped }
        } else if side == "right", current.end > maxX {
            let flipped = span(for: "left")
            if flipped.start >= minX { resolvedSide = "left"; current = flipped }
        }

        var shift: CGFloat = 0
        if current.end + shift > maxX { shift = maxX - current.end }
        if current.start + shift < minX { shift = minX - current.start }

        let anchorX: CGFloat
        switch resolvedSide {
        case "left": anchorX = current.end + shift
        case "right": anchorX = current.start + shift
        default: anchorX = (current.start + current.end) / 2 + shift
        }
        let centerY = maxY >= minY ? min(maxY, max(minY, point.y)) : point.y
        return Result(anchorX: anchorX, centerY: centerY, side: resolvedSide)
    }
}
