//
//  ScreenDrawingNativeEngine.swift
//  leanring-buddy
//
//  JavaScriptCore bridge for Clicky's native 2D/3D screen-drawing engine
//  (clicky-draw-native.js + clicky-draw-engine.js + clicky-draw-pieces.js).
//

import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreText
import Foundation
import JavaScriptCore
import QuartzCore

// MARK: - Serialized Render Op Models

public struct ClickyRenderOp: Identifiable {
    public enum OpKind: String {
        case set
        case remove
        case wrap
        case prop
        case stop
        case motion
    }

    public let id = UUID()
    public let op: OpKind
    public let group: String?
    public let beforeNodeID: Int?
    public let nodeID: Int?
    public let wrapperGroupID: Int?
    public let childNodeID: Int?
    public let maskID: String?
    public let propKey: String?
    public let propValue: Any?
    public let node: ClickyRenderNode?
    public let motionBegin: Double?
    public let motionDuration: Double?
    public let motionTiming: [Double]?
    public let motionItems: [ClickyMotionItem]
}

public struct ClickyMotionItem {
    public let key: String
    public let nodeID: Int?
    public let maskID: String?
    public let from: Any?
    public let to: Any?
}

public struct ClickyRenderAnimation {
    public let name: String
    public let duration: Double
    public let delay: Double
    public let timing: [Double]
    public let startedAt: Double
}

public nonisolated struct ClickyRenderTextLine: Sendable {
    public let x: Double?
    public let dy: Double
    public let text: String
}

public nonisolated struct ClickyRenderTextDescription: Sendable {
    public let family: String
    public let size: Double
    public let weight: Int
    public let anchor: String
    public let baseline: String
    public let x: Double
    public let y: Double
    public let lines: [ClickyRenderTextLine]
}

public final class ClickyRenderNode {
    public let nodeID: Int
    public let tag: String
    public let attributes: [String: String]
    public let styles: [String: String]
    public let markIndex: Int?
    public let animation: ClickyRenderAnimation?
    public let text: ClickyRenderTextDescription?
    public let children: [ClickyRenderNode]

    public init(
        nodeID: Int,
        tag: String,
        attributes: [String: String],
        styles: [String: String],
        markIndex: Int?,
        animation: ClickyRenderAnimation?,
        text: ClickyRenderTextDescription?,
        children: [ClickyRenderNode]
    ) {
        self.nodeID = nodeID
        self.tag = tag
        self.attributes = attributes
        self.styles = styles
        self.markIndex = markIndex
        self.animation = animation
        self.text = text
        self.children = children
    }
}

// MARK: - Analysis, Action & Card Models

public struct ClickyDrawingAction: Identifiable, Sendable {
    public let id: String
    public let role: String
    public let x: Double
    public let y: Double
    public let radius: Double
    public let box: [Double]?
    public let label: String?
    public let text: String?
    public let lineIndex: Int
    public let markIndex: Int

    public var isInteractiveButton: Bool { role == "button" }
    public var isGuidedTarget: Bool { role == "target" || role == "hover" }
}

public struct ClickyDrawingAnalysis: Sendable {
    public let lines: [String]
    public let actions: [ClickyDrawingAction]
    public let markCount: Int
    public let inkedCount: Int
    public let hasPicture: Bool
    public let firstLine: Int
    public let error: String?
    public let warnings: [String]
    public let pointingLines: [Int]
    public let cardLines: [Int]
}

public struct ClickyDrawingCardChrome: Sendable {
    public let markIndex: Int
    public let box: CGRect
    public let headerHeight: Double
    public let scale: Double
    public let isZoomed: Bool
    public let title: String
    public let has3D: Bool
}

public struct ClickyDrawingCard: Identifiable, Sendable {
    public var id: String { "\(marks.first ?? 0)-\(Int(box.origin.x))-\(Int(box.origin.y))" }
    public let box: CGRect
    public let marks: [Int]
    public let unitNodeIDs: [Int]
    public let windowChrome: ClickyDrawingCardChrome?
}

public struct ClickySubtitleChip: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let state: String
    public let isLate: Bool
}

public struct ClickyCaptionState: Sendable {
    public let header: String
    public let text: String
    public let chips: [ClickySubtitleChip]
}

public struct ClickyButtonReadyEvent: Sendable {
    public let markIndex: Int
    public let delaySeconds: Double
}

// MARK: - Font & SVG Path Utilities

public enum ClickyDrawFontRegistry {
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var patrickHandFontName: String?
    private nonisolated(unsafe) static var didAttemptRegistration = false

    @discardableResult
    public nonisolated static func registerPatrickHandIfNeeded() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if didAttemptRegistration {
            return patrickHandFontName
        }
        didAttemptRegistration = true

        let url = Bundle.main.url(forResource: "ClickyDraw-PatrickHand", withExtension: "ttf")
            ?? Bundle.main.url(forResource: "ClickyDraw-PatrickHand", withExtension: "ttf", subdirectory: "Resources")

        if let fontURL = url {
            var errorRef: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &errorRef)
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
               let firstDescriptor = descriptors.first,
               let name = CTFontDescriptorCopyAttribute(firstDescriptor, kCTFontNameAttribute) as? String {
                patrickHandFontName = name
            }
        }
        if patrickHandFontName == nil {
            patrickHandFontName = "PatrickHand-Regular"
        }
        return patrickHandFontName
    }

    public nonisolated static func ctFont(family: String, size: CGFloat, weight: Int) -> CTFont {
        let lower = family.lowercased()
        let clampedSize = max(4, size)

        if lower.contains("patrick") || lower.contains("cursive") {
            let fontName = registerPatrickHandIfNeeded() ?? "PatrickHand-Regular"
            if let custom = NSFont(name: fontName, size: clampedSize) {
                return custom as CTFont
            }
        }

        if lower.contains("georgia") || lower.contains("serif") {
            if weight >= 600, let boldSerif = NSFont(name: "Georgia-Bold", size: clampedSize) {
                return boldSerif as CTFont
            }
            if let serif = NSFont(name: "Georgia", size: clampedSize) {
                return serif as CTFont
            }
        }

        let nsWeight: NSFont.Weight
        switch weight {
        case ..<350: nsWeight = .light
        case 350..<500: nsWeight = .regular
        case 500..<600: nsWeight = .medium
        case 600..<700: nsWeight = .semibold
        default: nsWeight = .bold
        }
        return NSFont.systemFont(ofSize: clampedSize, weight: nsWeight) as CTFont
    }
}

public enum ClickySVGPathParser {
    private enum Token {
        case command(Character)
        case number(Double)
    }

    public static func cgPath(from svgData: String) -> CGPath {
        let path = CGMutablePath()
        let tokens = tokenize(svgData)
        var index = 0
        var currentCommand: Character = "M"
        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControlPoint: CGPoint?
        var lastCommand: Character = " "

        func hasNextNumber() -> Bool {
            guard index < tokens.count else { return false }
            if case .number = tokens[index] { return true }
            return false
        }

        func nextNumber() -> Double {
            guard index < tokens.count, case .number(let val) = tokens[index] else { return 0 }
            index += 1
            return val
        }

        while index < tokens.count {
            if case .command(let cmd) = tokens[index] {
                currentCommand = cmd
                index += 1
                if cmd == "Z" || cmd == "z" {
                    path.closeSubpath()
                    currentPoint = subpathStart
                    lastControlPoint = nil
                    lastCommand = "Z"
                    continue
                }
            }

            let isRelative = currentCommand.isLowercase
            let upper = Character(currentCommand.uppercased())

            switch upper {
            case "M":
                guard hasNextNumber() else { break }
                let x = nextNumber()
                let y = nextNumber()
                let pt = CGPoint(
                    x: isRelative ? currentPoint.x + x : x,
                    y: isRelative ? currentPoint.y + y : y
                )
                path.move(to: pt)
                currentPoint = pt
                subpathStart = pt
                lastControlPoint = nil
                lastCommand = "M"
                currentCommand = isRelative ? "l" : "L"

            case "L":
                guard hasNextNumber() else { break }
                let x = nextNumber()
                let y = nextNumber()
                let pt = CGPoint(
                    x: isRelative ? currentPoint.x + x : x,
                    y: isRelative ? currentPoint.y + y : y
                )
                path.addLine(to: pt)
                currentPoint = pt
                lastControlPoint = nil
                lastCommand = "L"

            case "H":
                guard hasNextNumber() else { break }
                let x = nextNumber()
                let pt = CGPoint(x: isRelative ? currentPoint.x + x : x, y: currentPoint.y)
                path.addLine(to: pt)
                currentPoint = pt
                lastControlPoint = nil
                lastCommand = "H"

            case "V":
                guard hasNextNumber() else { break }
                let y = nextNumber()
                let pt = CGPoint(x: currentPoint.x, y: isRelative ? currentPoint.y + y : y)
                path.addLine(to: pt)
                currentPoint = pt
                lastControlPoint = nil
                lastCommand = "V"

            case "C":
                guard hasNextNumber() else { break }
                let x1 = nextNumber(), y1 = nextNumber()
                let x2 = nextNumber(), y2 = nextNumber()
                let x = nextNumber(), y = nextNumber()
                let c1 = CGPoint(x: isRelative ? currentPoint.x + x1 : x1, y: isRelative ? currentPoint.y + y1 : y1)
                let c2 = CGPoint(x: isRelative ? currentPoint.x + x2 : x2, y: isRelative ? currentPoint.y + y2 : y2)
                let end = CGPoint(x: isRelative ? currentPoint.x + x : x, y: isRelative ? currentPoint.y + y : y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControlPoint = c2
                currentPoint = end
                lastCommand = "C"

            case "S":
                guard hasNextNumber() else { break }
                let x2 = nextNumber(), y2 = nextNumber()
                let x = nextNumber(), y = nextNumber()
                let c1: CGPoint
                if (lastCommand == "C" || lastCommand == "S"), let prev = lastControlPoint {
                    c1 = CGPoint(x: 2 * currentPoint.x - prev.x, y: 2 * currentPoint.y - prev.y)
                } else {
                    c1 = currentPoint
                }
                let c2 = CGPoint(x: isRelative ? currentPoint.x + x2 : x2, y: isRelative ? currentPoint.y + y2 : y2)
                let end = CGPoint(x: isRelative ? currentPoint.x + x : x, y: isRelative ? currentPoint.y + y : y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControlPoint = c2
                currentPoint = end
                lastCommand = "S"

            case "Q":
                guard hasNextNumber() else { break }
                let x1 = nextNumber(), y1 = nextNumber()
                let x = nextNumber(), y = nextNumber()
                let c = CGPoint(x: isRelative ? currentPoint.x + x1 : x1, y: isRelative ? currentPoint.y + y1 : y1)
                let end = CGPoint(x: isRelative ? currentPoint.x + x : x, y: isRelative ? currentPoint.y + y : y)
                path.addQuadCurve(to: end, control: c)
                lastControlPoint = c
                currentPoint = end
                lastCommand = "Q"

            case "T":
                guard hasNextNumber() else { break }
                let x = nextNumber(), y = nextNumber()
                let c: CGPoint
                if (lastCommand == "Q" || lastCommand == "T"), let prev = lastControlPoint {
                    c = CGPoint(x: 2 * currentPoint.x - prev.x, y: 2 * currentPoint.y - prev.y)
                } else {
                    c = currentPoint
                }
                let end = CGPoint(x: isRelative ? currentPoint.x + x : x, y: isRelative ? currentPoint.y + y : y)
                path.addQuadCurve(to: end, control: c)
                lastControlPoint = c
                currentPoint = end
                lastCommand = "T"

            case "A":
                guard hasNextNumber() else { break }
                let rx = abs(nextNumber())
                let ry = abs(nextNumber())
                let xAxisRotation = nextNumber() * .pi / 180.0
                let largeArc = nextNumber() != 0
                let sweep = nextNumber() != 0
                let ex = nextNumber(), ey = nextNumber()
                let end = CGPoint(x: isRelative ? currentPoint.x + ex : ex, y: isRelative ? currentPoint.y + ey : ey)
                addSVGArc(
                    to: path,
                    from: currentPoint,
                    to: end,
                    rx: rx,
                    ry: ry,
                    phi: xAxisRotation,
                    largeArc: largeArc,
                    sweep: sweep
                )
                currentPoint = end
                lastControlPoint = nil
                lastCommand = "A"

            case "Z":
                path.closeSubpath()
                currentPoint = subpathStart
                lastControlPoint = nil
                lastCommand = "Z"

            default:
                index += 1
            }
        }
        return path
    }

    public static func boundingBox(of svgData: String) -> CGRect {
        let path = cgPath(from: svgData)
        let box = path.boundingBoxOfPath
        return box.isNull || box.isEmpty ? .zero : box
    }

    public static func flattenedPoints(of svgData: String) -> [CGPoint] {
        let path = cgPath(from: svgData)
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var start = CGPoint.zero

        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
                start = current
                points.append(current)
            case .addLineToPoint:
                current = element.points[0]
                points.append(current)
            case .addQuadCurveToPoint:
                let ctrl = element.points[0]
                let end = element.points[1]
                let steps = 16
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let u = 1 - t
                    let pt = CGPoint(
                        x: u * u * current.x + 2 * u * t * ctrl.x + t * t * end.x,
                        y: u * u * current.y + 2 * u * t * ctrl.y + t * t * end.y
                    )
                    points.append(pt)
                }
                current = end
            case .addCurveToPoint:
                let c1 = element.points[0]
                let c2 = element.points[1]
                let end = element.points[2]
                let steps = 20
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let u = 1 - t
                    let pt = CGPoint(
                        x: u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x,
                        y: u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
                    )
                    points.append(pt)
                }
                current = end
            case .closeSubpath:
                if current != start {
                    points.append(start)
                    current = start
                }
            @unknown default:
                break
            }
        }
        return points
    }

    public static func totalLength(of svgData: String) -> Double {
        let pts = flattenedPoints(of: svgData)
        guard pts.count >= 2 else { return 0 }
        var total = 0.0
        for idx in 1..<pts.count {
            total += hypot(Double(pts[idx].x - pts[idx - 1].x), Double(pts[idx].y - pts[idx - 1].y))
        }
        return total
    }

    public static func pointAtLength(_ targetLength: Double, in svgData: String) -> CGPoint {
        let pts = flattenedPoints(of: svgData)
        guard let first = pts.first else { return .zero }
        if pts.count < 2 || targetLength <= 0 { return first }
        var accumulated = 0.0
        for idx in 1..<pts.count {
            let p0 = pts[idx - 1]
            let p1 = pts[idx]
            let seg = hypot(Double(p1.x - p0.x), Double(p1.y - p0.y))
            if accumulated + seg >= targetLength && seg > 1e-6 {
                let ratio = CGFloat((targetLength - accumulated) / seg)
                return CGPoint(x: p0.x + (p1.x - p0.x) * ratio, y: p0.y + (p1.y - p0.y) * ratio)
            }
            accumulated += seg
        }
        return pts.last ?? first
    }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(d.unicodeScalars)
        var i = 0
        let count = chars.count

        while i < count {
            let scalar = chars[i]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "," {
                i += 1
                continue
            }
            if CharacterSet.letters.contains(scalar) && scalar != "e" && scalar != "E" {
                tokens.append(.command(Character(scalar)))
                i += 1
                continue
            }

            let start = i
            if scalar == "-" || scalar == "+" {
                i += 1
            }
            var seenDot = false
            while i < count {
                let c = chars[i]
                if c >= "0" && c <= "9" {
                    i += 1
                } else if c == "." && !seenDot {
                    seenDot = true
                    i += 1
                } else if (c == "e" || c == "E") && i > start {
                    i += 1
                    if i < count && (chars[i] == "+" || chars[i] == "-") {
                        i += 1
                    }
                } else {
                    break
                }
            }
            if i > start {
                let slice = String(String.UnicodeScalarView(chars[start..<i]))
                if let num = Double(slice) {
                    tokens.append(.number(num))
                }
            } else {
                i += 1
            }
        }
        return tokens
    }

    private static func addSVGArc(
        to path: CGMutablePath,
        from p1: CGPoint,
        to p2: CGPoint,
        rx rxIn: Double,
        ry ryIn: Double,
        phi: Double,
        largeArc: Bool,
        sweep: Bool
    ) {
        if rxIn == 0 || ryIn == 0 {
            path.addLine(to: p2)
            return
        }
        var rx = rxIn
        var ry = ryIn
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = Double(p1.x - p2.x) / 2.0
        let dy = Double(p1.y - p2.y) / 2.0
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let root = sqrt(lambda)
            rx *= root
            ry *= root
        }

        let rx2 = rx * rx, ry2 = ry * ry
        let x1p2 = x1p * x1p, y1p2 = y1p * y1p
        let num = max(0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
        let den = max(1e-9, rx2 * y1p2 + ry2 * x1p2)
        let sign = (largeArc == sweep) ? -1.0 : 1.0
        let coef = sign * sqrt(num / den)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + Double(p1.x + p2.x) / 2.0
        let cy = sinPhi * cxp + cosPhi * cyp + Double(p1.y + p2.y) / 2.0

        func vecAngle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let cross = ux * vy - uy * vx
            return atan2(cross, dot)
        }

        let t1 = vecAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dt = vecAngle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi }
        else if sweep && dt < 0 { dt += 2 * .pi }

        let segments = max(1, Int(ceil(abs(dt) / (.pi / 2.0))))
        let step = dt / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4.0)

        for s in 0..<segments {
            let a = t1 + Double(s) * step
            let b = a + step
            let ePt = { (t: Double) -> CGPoint in
                CGPoint(
                    x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                    y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi
                )
            }
            let dVec = { (t: Double) -> CGPoint in
                CGPoint(
                    x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                    y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi
                )
            }
            let pA = ePt(a), pB = ePt(b), dA = dVec(a), dB = dVec(b)
            let c1 = CGPoint(x: pA.x + CGFloat(k) * dA.x, y: pA.y + CGFloat(k) * dA.y)
            let c2 = CGPoint(x: pB.x - CGFloat(k) * dB.x, y: pB.y - CGFloat(k) * dB.y)
            path.addCurve(to: pB, control1: c1, control2: c2)
        }
    }
}

// MARK: - Native Screen Drawing Engine

@MainActor
public final class ScreenDrawingNativeEngine: ObservableObject {

    @Published public private(set) var latestAnalysis: ClickyDrawingAnalysis?
    @Published public private(set) var captionState: ClickyCaptionState?
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var isFinished: Bool = true
    @Published public private(set) var latestError: String?

    /// Invoked whenever `__drainRender()` yields one or more serialized render ops.
    public var onRenderOps: (([ClickyRenderOp]) -> Void)?
    /// Invoked when `__host.buttonReady(markIndex, delaySeconds)` fires.
    public var onButtonReady: ((ClickyButtonReadyEvent) -> Void)?

    /// Optional screen luminance sampler: returns 0..1 luminance in canvas coords, or -1 if unavailable.
    public var luminanceSampler: ((CGRect) -> Double)?
    /// Optional screen busyness sampler: returns 0..1 density of text/UI controls in canvas coords.
    public var busynessSampler: ((CGRect) -> Double)?
    /// Whether 3D figures float without a paper card (Stream mode).
    public var figuresFloat: Bool = true

    private let virtualMachine = JSVirtualMachine()
    private var context: JSContext?
    private var isLoaded = false
    private nonisolated(unsafe) var scheduledTimers: [Int: Timer] = [:]
    private nonisolated(unsafe) var drainTimer: Timer?
    private var soundPlayers: [String: AVAudioPlayer] = [:]

    public init() {
        _ = ClickyDrawFontRegistry.registerPatrickHandIfNeeded()
        setupContextIfNeeded()
    }

    deinit {
        drainTimer?.invalidate()
        for timer in scheduledTimers.values {
            timer.invalidate()
        }
    }

    // MARK: - Public Engine Lifecycle

    public func beginStream(size: CGSize, displayWidthPoints: CGFloat? = nil, subtitles: Bool = false, inkHex: String? = nil) {
        setupContextIfNeeded()
        guard let canvas = canvasObject else { return }

        let resolvedInk = inkHex ?? Self.defaultInkHex()
        let widthPts = Double(displayWidthPoints ?? size.width)
        let args: [String: Any] = [
            "w": Double(size.width),
            "h": Double(size.height),
            "width": widthPts,
            "subtitles": subtitles,
            "ink": resolvedInk
        ]

        canvas.invokeMethod("beginStream", withArguments: [args])
        isStreaming = true
        isFinished = false
        latestError = nil
        latestAnalysis = nil
        startDrainLoop()
        drainRenderNow()
    }

    @discardableResult
    public func feed(code: String, done: Bool) -> ClickyDrawingAnalysis? {
        setupContextIfNeeded()
        guard let canvas = canvasObject else { return nil }

        let result = canvas.invokeMethod("feed", withArguments: [[
            "code": code,
            "done": done
        ]])
        drainRenderNow()

        if let jsonString = result?.toString(),
           jsonString != "null",
           jsonString != "undefined" {
            let analysis = Self.parseAnalysis(from: jsonString)
            latestAnalysis = analysis
            latestError = analysis?.error
            return analysis
        }
        return nil
    }

    public func continueStream(subtitles: Bool? = nil) -> (firstLine: Int, marks: Int, code: String)? {
        guard let canvas = canvasObject else { return nil }
        var opts: [String: Any] = [:]
        if let subtitles { opts["subtitles"] = subtitles }
        let res = canvas.invokeMethod("continueStream", withArguments: [opts])
        drainRenderNow()
        guard let json = res?.toString(),
              let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (
            firstLine: dict["firstLine"] as? Int ?? 0,
            marks: dict["marks"] as? Int ?? 0,
            code: dict["code"] as? String ?? ""
        )
    }

    public func markLineStarted(_ lineIndex: Int) {
        canvasObject?.invokeMethod("line", withArguments: [lineIndex])
        drainRenderNow()
    }

    public func setLineLength(_ lineIndex: Int, seconds: Double) {
        canvasObject?.invokeMethod("lineLength", withArguments: [lineIndex, seconds])
        drainRenderNow()
    }

    public func finish() {
        canvasObject?.invokeMethod("finish", withArguments: [])
        isStreaming = false
        drainRenderNow()
        updateFinishedFlag()
    }

    public func clear() {
        invalidateAllTimers()
        stopDrainLoop()
        canvasObject?.invokeMethod("clear", withArguments: [])
        isStreaming = false
        isFinished = true
        latestAnalysis = nil
        captionState = nil
        latestError = nil
        drainRenderNow()
    }

    public func renderWhole(size: CGSize, displayWidthPoints: CGFloat? = nil, code: String, inkHex: String? = nil) {
        setupContextIfNeeded()
        guard let canvas = canvasObject else { return }
        let resolvedInk = inkHex ?? Self.defaultInkHex()
        let args: [String: Any] = [
            "w": Double(size.width),
            "h": Double(size.height),
            "width": Double(displayWidthPoints ?? size.width),
            "code": code,
            "ink": resolvedInk
        ]
        canvas.invokeMethod("renderWhole", withArguments: [args])
        isStreaming = false
        isFinished = true
        drainRenderNow()
    }

    // MARK: - Interactive Query / Card Manipulation

    public func dropPointing() -> (dropped: Int, left: Int)? {
        guard let res = canvasObject?.invokeMethod("dropPointing", withArguments: []),
              let json = res.toString(),
              let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        drainRenderNow()
        return (dict["dropped"] as? Int ?? 0, dict["left"] as? Int ?? 0)
    }

    public func keepNotesOnly() -> (kept: Int, dropped: Int)? {
        guard let res = canvasObject?.invokeMethod("keepNotesOnly", withArguments: []),
              let json = res.toString(),
              let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        drainRenderNow()
        return (dict["kept"] as? Int ?? 0, dict["dropped"] as? Int ?? 0)
    }

    public func currentCards() -> [ClickyDrawingCard] {
        guard let res = canvasObject?.invokeMethod("cards", withArguments: []),
              let json = res.toString(),
              json != "null",
              let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { item in
            guard let boxArr = item["box"] as? [NSNumber], boxArr.count == 4 else { return nil }
            let box = CGRect(
                x: boxArr[0].doubleValue,
                y: boxArr[1].doubleValue,
                width: boxArr[2].doubleValue,
                height: boxArr[3].doubleValue
            )
            let marks = (item["marks"] as? [NSNumber])?.map { $0.intValue } ?? []
            let units = (item["units"] as? [NSNumber])?.map { $0.intValue } ?? []

            var chrome: ClickyDrawingCardChrome?
            if let win = item["window"] as? [String: Any],
               let wBoxArr = win["box"] as? [NSNumber], wBoxArr.count == 4 {
                chrome = ClickyDrawingCardChrome(
                    markIndex: (win["mark"] as? NSNumber)?.intValue ?? 0,
                    box: CGRect(
                        x: wBoxArr[0].doubleValue,
                        y: wBoxArr[1].doubleValue,
                        width: wBoxArr[2].doubleValue,
                        height: wBoxArr[3].doubleValue
                    ),
                    headerHeight: (win["header"] as? NSNumber)?.doubleValue ?? 28,
                    scale: (win["scale"] as? NSNumber)?.doubleValue ?? 1.0,
                    isZoomed: (win["zoomed"] as? Bool) ?? false,
                    title: (win["title"] as? String) ?? "",
                    has3D: (win["has3D"] as? Bool) ?? false
                )
            }
            return ClickyDrawingCard(box: box, marks: marks, unitNodeIDs: units, windowChrome: chrome)
        }
    }

    @discardableResult
    public func moveCard(marks: [Int], dx: Double, dy: Double) -> Int {
        let count = canvasObject?.invokeMethod("moveCard", withArguments: [[
            "marks": marks,
            "dx": dx,
            "dy": dy
        ]])?.toInt32() ?? 0
        drainRenderNow()
        return Int(count)
    }

    @discardableResult
    public func closeCard(marks: [Int]) -> (closed: Int, left: Int)? {
        guard let res = canvasObject?.invokeMethod("closeCard", withArguments: [["marks": marks]]),
              let json = res.toString(),
              let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        drainRenderNow()
        return (dict["closed"] as? Int ?? 0, dict["left"] as? Int ?? 0)
    }

    @discardableResult
    public func zoomCard(marks: [Int], to transform: [Double]?) -> Int {
        var args: [String: Any] = ["marks": marks]
        if let transform { args["to"] = transform }
        let count = canvasObject?.invokeMethod("zoomCard", withArguments: [args])?.toInt32() ?? 0
        drainRenderNow()
        return Int(count)
    }

    public func buttonSpot(box: CGRect, gap: Double = 6, avoid: [CGRect] = []) -> CGRect {
        let avoidArr = avoid.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)] }
        guard let res = canvasObject?.invokeMethod("buttonSpot", withArguments: [[
            "box": [Double(box.origin.x), Double(box.origin.y), Double(box.width), Double(box.height)],
            "gap": gap,
            "avoid": avoidArr
        ]]),
              let json = res.toString(),
              let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [NSNumber],
              arr.count == 4 else {
            return box
        }
        return CGRect(x: arr[0].doubleValue, y: arr[1].doubleValue, width: arr[2].doubleValue, height: arr[3].doubleValue)
    }

    public func tick3D(stageID: String, ticks: [(id: String, elapsed: Double)], dt: Double) -> [Float]? {
        guard let canvas = canvasObject else { return nil }
        let tickArgs: [[Any]] = ticks.map { [$0.id, $0.elapsed] }
        guard let res = canvas.invokeMethod("tick3d", withArguments: [[
            "stage": stageID,
            "ticks": tickArgs,
            "dt": dt
        ]]), !res.isNull, !res.isUndefined, let ctx = context else {
            return nil
        }

        let ctxRef = ctx.jsGlobalContextRef
        let valRef = res.jsValueRef
        var exception: JSValueRef?
        if JSValueGetTypedArrayType(ctxRef, valRef, &exception) == kJSTypedArrayTypeFloat32Array,
           let objRef = JSValueToObject(ctxRef, valRef, &exception),
           let ptr = JSObjectGetTypedArrayBytesPtr(ctxRef, objRef, &exception) {
            let count = JSObjectGetTypedArrayLength(ctxRef, objRef, &exception)
            let floatPtr = ptr.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: floatPtr, count: count))
        }
        return nil
    }

    public func drainRenderNow() {
        guard let ctx = context,
              let drainFn = ctx.objectForKeyedSubscript("__drainRender"),
              !drainFn.isUndefined else { return }

        guard let json = drainFn.call(withArguments: [])?.toString(),
              !json.isEmpty,
              json != "undefined",
              json != "null" else {
            updateFinishedFlag()
            return
        }

        let ops = Self.parseRenderOps(from: json)
        if !ops.isEmpty {
            onRenderOps?(ops)
        }
        updateFinishedFlag()
    }

    // MARK: - JSContext Initialization & __host Bridge

    private var canvasObject: JSValue? {
        context?.objectForKeyedSubscript("clickyCanvas")
    }

    private func setupContextIfNeeded() {
        if isLoaded && context != nil { return }

        guard let ctx = JSContext(virtualMachine: virtualMachine) else {
            latestError = "Unable to create JavaScriptCore context"
            return
        }

        ctx.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "Unknown JS error"
            print("🎨 ScreenDrawingNativeEngine JS exception: \(message)")
            self?.latestError = message
        }

        ctx.evaluateScript("if (typeof globalThis === 'undefined') { var globalThis = this; }")
        installHostBridge(in: ctx)

        guard let engineSource = Self.loadBundleScript(named: "clicky-draw-engine"),
              let nativeSource = Self.loadBundleScript(named: "clicky-draw-native"),
              let piecesSource = Self.loadBundleScript(named: "clicky-draw-pieces") else {
            latestError = "Missing bundled drawing JS scripts (clicky-draw-engine/native/pieces.js)"
            return
        }

        ctx.evaluateScript(engineSource, withSourceURL: URL(string: "clicky-draw-engine.js"))
        ctx.evaluateScript(nativeSource, withSourceURL: URL(string: "clicky-draw-native.js"))

        if let canvas = ctx.objectForKeyedSubscript("clickyCanvas"), !canvas.isUndefined {
            canvas.invokeMethod("setPieces", withArguments: [piecesSource])
        }

        self.context = ctx
        self.isLoaded = true
    }

    private func installHostBridge(in ctx: JSContext) {
        guard let host = JSValue(newObjectIn: ctx) else { return }

        let nowBlock: @convention(block) () -> Double = {
            CACurrentMediaTime()
        }
        host.setObject(nowBlock, forKeyedSubscript: "now" as NSString)

        let logBlock: @convention(block) (String) -> Void = { message in
            print("🎨 [DrawJS] \(message)")
        }
        host.setObject(logBlock, forKeyedSubscript: "log" as NSString)

        let scheduleBlock: @convention(block) (Int, Double) -> Void = { [weak self] timerID, delay in
            Task { @MainActor [weak self] in
                self?.scheduleTimer(id: timerID, delay: delay)
            }
        }
        host.setObject(scheduleBlock, forKeyedSubscript: "schedule" as NSString)

        let cancelBlock: @convention(block) (Int) -> Void = { [weak self] timerID in
            Task { @MainActor [weak self] in
                self?.cancelTimer(id: timerID)
            }
        }
        host.setObject(cancelBlock, forKeyedSubscript: "cancel" as NSString)

        let textBoxBlock: @convention(block) (String) -> [Double] = { descJSON in
            MainActor.assumeIsolated {
                Self.measureTextBox(descJSON: descJSON)
            }
        }
        host.setObject(textBoxBlock, forKeyedSubscript: "textBox" as NSString)

        let textWidthBlock: @convention(block) (String, Double, Double, String) -> Double = { family, size, weight, text in
            MainActor.assumeIsolated {
                Self.measureTextWidth(family: family, size: size, weight: Int(weight.isFinite ? weight : 400), text: text)
            }
        }
        host.setObject(textWidthBlock, forKeyedSubscript: "textWidth" as NSString)

        let pathBoxBlock: @convention(block) (String) -> [Double] = { d in
            let rect = ClickySVGPathParser.boundingBox(of: d)
            return [Double(rect.origin.x), Double(rect.origin.y), Double(rect.size.width), Double(rect.size.height)]
        }
        host.setObject(pathBoxBlock, forKeyedSubscript: "pathBox" as NSString)

        let pathLengthBlock: @convention(block) (String) -> Double = { d in
            ClickySVGPathParser.totalLength(of: d)
        }
        host.setObject(pathLengthBlock, forKeyedSubscript: "pathLength" as NSString)

        let pathPointBlock: @convention(block) (String, Double) -> [Double] = { d, len in
            let pt = ClickySVGPathParser.pointAtLength(len, in: d)
            return [Double(pt.x), Double(pt.y)]
        }
        host.setObject(pathPointBlock, forKeyedSubscript: "pathPoint" as NSString)

        let lumForBlock: @convention(block) (Double, Double, Double, Double) -> Double = { [weak self] x, y, w, h in
            MainActor.assumeIsolated {
                guard let sampler = self?.luminanceSampler else { return -1.0 }
                return sampler(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        host.setObject(lumForBlock, forKeyedSubscript: "lumFor" as NSString)

        let inkForBlock: @convention(block) (Double, Double, Double, Double) -> String = { [weak self] x, y, w, h in
            MainActor.assumeIsolated {
                guard let sampler = self?.luminanceSampler else { return "#FFFFFF" }
                let lum = sampler(CGRect(x: x, y: y, width: w, height: h))
                if lum < 0 { return "#FFFFFF" }
                return lum > 0.56 ? "#15171C" : "#FFFFFF"
            }
        }
        host.setObject(inkForBlock, forKeyedSubscript: "inkFor" as NSString)

        let busyForBlock: @convention(block) (Double, Double, Double, Double) -> Double = { [weak self] x, y, w, h in
            MainActor.assumeIsolated {
                guard let sampler = self?.busynessSampler else { return 0.0 }
                return sampler(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        host.setObject(busyForBlock, forKeyedSubscript: "busyFor" as NSString)

        let figuresFloatBlock: @convention(block) () -> Bool = { [weak self] in
            MainActor.assumeIsolated {
                self?.figuresFloat ?? true
            }
        }
        host.setObject(figuresFloatBlock, forKeyedSubscript: "figuresFloat" as NSString)

        let shape3dBlock: @convention(block) (String, String) -> Void = { kind, recipeJSON in
            ClickyThreeKernel.shared.prewarmShape(kind: kind, recipeJSON: recipeJSON)
        }
        host.setObject(shape3dBlock, forKeyedSubscript: "shape3d" as NSString)

        let captionBlock: @convention(block) (String) -> Void = { [weak self] json in
            Task { @MainActor [weak self] in
                self?.handleCaptionUpdate(json)
            }
        }
        host.setObject(captionBlock, forKeyedSubscript: "caption" as NSString)

        let markSoundBlock: @convention(block) (Int, String) -> Void = { [weak self] markIndex, payloadJSON in
            Task { @MainActor [weak self] in
                self?.handleMarkSound(markIndex: markIndex, payloadJSON: payloadJSON)
            }
        }
        host.setObject(markSoundBlock, forKeyedSubscript: "markSound" as NSString)

        let buttonReadyBlock: @convention(block) (Int, Double) -> Void = { [weak self] markIndex, delaySeconds in
            Task { @MainActor [weak self] in
                self?.onButtonReady?(ClickyButtonReadyEvent(markIndex: markIndex, delaySeconds: delaySeconds))
            }
        }
        host.setObject(buttonReadyBlock, forKeyedSubscript: "buttonReady" as NSString)

        ctx.setObject(host, forKeyedSubscript: "__host" as NSString)
    }

    // MARK: - Timers & Render Drain Loop

    private func scheduleTimer(id: Int, delay: Double) {
        scheduledTimers[id]?.invalidate()
        let clampedDelay = max(0.001, delay)
        let timer = Timer.scheduledTimer(withTimeInterval: clampedDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledTimers.removeValue(forKey: id)
                self.context?.objectForKeyedSubscript("__fireTimer")?.call(withArguments: [id])
                self.drainRenderNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduledTimers[id] = timer
    }

    private func cancelTimer(id: Int) {
        scheduledTimers[id]?.invalidate()
        scheduledTimers.removeValue(forKey: id)
    }

    private func invalidateAllTimers() {
        for timer in scheduledTimers.values {
            timer.invalidate()
        }
        scheduledTimers.removeAll()
    }

    private func startDrainLoop() {
        drainTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainRenderNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func stopDrainLoop() {
        drainTimer?.invalidate()
        drainTimer = nil
    }

    private func updateFinishedFlag() {
        guard let canvas = canvasObject else { return }
        let finishedNow = canvas.invokeMethod("isFinished", withArguments: [])?.toBool() ?? true
        if isFinished != finishedNow {
            isFinished = finishedNow
        }
        if finishedNow && !isStreaming && scheduledTimers.isEmpty {
            stopDrainLoop()
        }
    }

    // MARK: - Host Callback Implementations

    private func handleCaptionUpdate(_ json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            captionState = nil
            return
        }
        let header = dict["header"] as? String ?? ""
        let text = dict["text"] as? String ?? ""
        let rawChips = dict["chips"] as? [[String: Any]] ?? []
        let chips = rawChips.enumerated().map { idx, item in
            ClickySubtitleChip(
                id: "\(idx)-\(item["label"] as? String ?? "")",
                label: item["label"] as? String ?? "",
                state: item["state"] as? String ?? "waiting",
                isLate: (item["late"] as? Bool) ?? false
            )
        }
        captionState = ClickyCaptionState(header: header, text: text, chips: chips)
    }

    private func handleMarkSound(markIndex: Int, payloadJSON: String) {
        guard ClickyConfiguration.shared.soundEffectsEnabled else { return }
        guard let data = payloadJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        let baseDelay = max(0.0, (dict["delay"] as? NSNumber)?.doubleValue ?? 0.0)
        let dur = max(0.05, (dict["dur"] as? NSNumber)?.doubleValue ?? 0.25)
        let texture = dict["texture"] as? String
        let events = dict["events"] as? [[String: Any]] ?? []

        if let texture, !texture.isEmpty {
            scheduleSoundName(texture, after: baseDelay)
        }

        for ev in events {
            guard let id = ev["id"] as? String, !id.isEmpty else { continue }
            let at = (ev["at"] as? NSNumber)?.doubleValue ?? 0.0
            let fromEnd = (ev["end"] as? Bool) ?? false
            let offset = fromEnd ? max(0, baseDelay + dur + at) : max(0, baseDelay + at)
            scheduleSoundName(id, after: offset)
        }
    }

    private func scheduleSoundName(_ name: String, after delay: Double) {
        let fire = { [weak self] in
            self?.playDrawingSound(named: name)
        }
        if delay <= 0.01 {
            fire()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                fire()
            }
        }
    }

    private func playDrawingSound(named id: String) {
        guard ClickyConfiguration.shared.soundEffectsEnabled else { return }

        // Map directly onto existing ClickySoundEffect cases when available.
        switch id {
        case "gel-pop":
            ClickySoundEffectPlayer.shared.play(.gelPop)
            return
        case "badge-pop":
            ClickySoundEffectPlayer.shared.play(.badgePop)
            return
        case "ding":
            ClickySoundEffectPlayer.shared.play(.ding)
            return
        case "tada":
            ClickySoundEffectPlayer.shared.play(.tada)
            return
        case "slide":
            ClickySoundEffectPlayer.shared.play(.slide)
            return
        case "pencil":
            ClickySoundEffectPlayer.shared.play(.pencilBed)
            return
        case "highlighter":
            ClickySoundEffectPlayer.shared.play(.highlighter)
            return
        default:
            break
        }

        // Otherwise resolve the bundled resource variants in Resources/
        let candidateFilenames: [String]
        switch id {
        case "felt": candidateFilenames = ["pen-screen-bed-1.wav"]
        case "writing": candidateFilenames = ["handwriting-bed-1.wav", "handwriting-bed-2.wav"]
        case "eraser": candidateFilenames = ["page-clear-1.wav"]
        case "build-3d": candidateFilenames = ["build-3d-1.wav", "build-3d-2.wav", "build-3d-3.wav", "build-3d-4.wav"]
        case "button-appear": candidateFilenames = ["button-appear-1.wav", "button-appear-2.wav"]
        case "photo-drop": candidateFilenames = ["photo-drop-1.wav", "photo-drop-2.wav", "photo-drop-3.wav"]
        case "paper-place": candidateFilenames = ["paper-place-2.wav", "paper-place-3.wav"]
        case "sticky-press": candidateFilenames = ["sticky-press-1.wav", "sticky-press-3.wav"]
        case "tape": candidateFilenames = ["tape-1.wav", "tape-3.wav"]
        case "pen-flick": candidateFilenames = ["pen-flick-1.wav", "pen-flick-3.wav"]
        case "page-clear": candidateFilenames = ["page-clear-1.wav", "page-clear-2.wav"]
        case "target-ping": candidateFilenames = ["target-ping-1.wav", "target-ping-2.wav"]
        case "copy-tick": candidateFilenames = ["copy-tick-1.wav", "copy-tick-2.wav"]
        case "type-keys": candidateFilenames = ["type-keys-1.wav"]
        case "sparkle": candidateFilenames = ["sparkle-1.wav", "sparkle-2.wav"]
        case "nope": candidateFilenames = ["nope-1.wav", "nope-2.wav"]
        case "stamp": candidateFilenames = ["stamp-1.wav"]
        case "whoosh": candidateFilenames = ["whoosh-1.wav", "whoosh-2.wav"]
        case "boing": candidateFilenames = ["boing-1.wav"]
        default: candidateFilenames = ["\(id).wav", "\(id)-1.wav"]
        }

        guard let picked = candidateFilenames.randomElement() else { return }
        if let player = soundPlayers[picked] {
            player.currentTime = 0
            player.play()
            return
        }

        let ns = picked as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext)
                ?? Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Resources") else {
            return
        }
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 0.55
            player.prepareToPlay()
            player.play()
            soundPlayers[picked] = player
        }
    }

    // MARK: - CoreText Measurements

    private static func measureTextWidth(family: String, size: Double, weight: Int, text: String) -> Double {
        let font = ClickyDrawFontRegistry.ctFont(family: family, size: CGFloat(size), weight: weight)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return max(0, Double(width))
    }

    private static func measureTextBox(descJSON: String) -> [Double] {
        guard let data = descJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [0, 0, 0, 0]
        }

        let family = dict["family"] as? String ?? "sans-serif"
        let size = (dict["size"] as? NSNumber)?.doubleValue ?? 16
        let weight = (dict["weight"] as? NSNumber)?.intValue ?? 400
        let anchor = dict["anchor"] as? String ?? "start"
        let baseline = dict["baseline"] as? String ?? "auto"
        let baseX = (dict["x"] as? NSNumber)?.doubleValue ?? 0
        let baseY = (dict["y"] as? NSNumber)?.doubleValue ?? 0
        let lines = dict["lines"] as? [[String: Any]] ?? []

        let font = ClickyDrawFontRegistry.ctFont(family: family, size: CGFloat(size), weight: weight)
        let fontAscent = Double(CTFontGetAscent(font))
        let fontDescent = Double(CTFontGetDescent(font))

        var curX = baseX
        var curY = baseY
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for line in lines {
            if let explicitX = (line["x"] as? NSNumber)?.doubleValue {
                curX = explicitX
            }
            let dy = (line["dy"] as? NSNumber)?.doubleValue ?? 0
            curY += dy
            let text = line["text"] as? String ?? ""
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            let width = max(0, Double(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))

            let startX: Double
            switch anchor {
            case "middle": startX = curX - width / 2.0
            case "end": startX = curX - width
            default: startX = curX
            }

            let topY: Double
            switch baseline {
            case "middle", "central":
                topY = curY - (fontAscent + fontDescent) / 2.0
            case "hanging":
                topY = curY
            default:
                topY = curY - fontAscent
            }
            let bottomY = topY + fontAscent + fontDescent

            minX = min(minX, startX)
            maxX = max(maxX, startX + width)
            minY = min(minY, topY)
            maxY = max(maxY, bottomY)
        }

        if minX == Double.greatestFiniteMagnitude {
            return [baseX, baseY - fontAscent, 0, fontAscent + fontDescent]
        }
        return [minX, minY, max(0, maxX - minX), max(0, maxY - minY)]
    }

    // MARK: - JSON Parsing

    private static func loadBundleScript(named name: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: "js")
            ?? Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Resources")
        guard let scriptURL = url else { return nil }
        return try? String(contentsOf: scriptURL, encoding: .utf8)
    }

    private static func defaultInkHex() -> String {
        switch UserDefaults.standard.string(forKey: "clicky_cursor_color_name")?.lowercased() {
        case "red": return "#FF4C4C"
        case "yellow": return "#D4A017"
        case "green": return "#26C281"
        default: return "#3380FF"
        }
    }

    private static func parseAnalysis(from json: String) -> ClickyDrawingAnalysis? {
        guard let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let lines = dict["lines"] as? [String] ?? []
        let rawActions = dict["actions"] as? [[String: Any]] ?? []
        let actions = rawActions.enumerated().map { idx, a in
            let markIdx = (a["i"] as? NSNumber)?.intValue ?? idx
            let role = a["role"] as? String ?? ""
            return ClickyDrawingAction(
                id: "\(markIdx)-\(role)",
                role: role,
                x: (a["x"] as? NSNumber)?.doubleValue ?? 0,
                y: (a["y"] as? NSNumber)?.doubleValue ?? 0,
                radius: (a["r"] as? NSNumber)?.doubleValue ?? 0,
                box: (a["box"] as? [NSNumber])?.map { $0.doubleValue },
                label: a["label"] as? String,
                text: a["text"] as? String,
                lineIndex: (a["line"] as? NSNumber)?.intValue ?? 0,
                markIndex: markIdx
            )
        }

        return ClickyDrawingAnalysis(
            lines: lines,
            actions: actions,
            markCount: (dict["marks"] as? NSNumber)?.intValue ?? 0,
            inkedCount: (dict["inked"] as? NSNumber)?.intValue ?? 0,
            hasPicture: (dict["picture"] as? Bool) ?? false,
            firstLine: (dict["firstLine"] as? NSNumber)?.intValue ?? 0,
            error: dict["error"] as? String,
            warnings: dict["warnings"] as? [String] ?? [],
            pointingLines: (dict["pointingLines"] as? [NSNumber])?.map { $0.intValue } ?? [],
            cardLines: (dict["cardLines"] as? [NSNumber])?.map { $0.intValue } ?? []
        )
    }

    private static func parseRenderOps(from json: String) -> [ClickyRenderOp] {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { dict in
            guard let opRaw = dict["op"] as? String,
                  let opKind = ClickyRenderOp.OpKind(rawValue: opRaw) else {
                return nil
            }
            let nodeDict = dict["node"] as? [String: Any]
            let rawItems = dict["items"] as? [[String: Any]] ?? []
            let motionItems = rawItems.compactMap { item -> ClickyMotionItem? in
                guard let key = item["key"] as? String else { return nil }
                return ClickyMotionItem(
                    key: key,
                    nodeID: (item["n"] as? NSNumber)?.intValue,
                    maskID: item["mask"] as? String,
                    from: item["from"],
                    to: item["to"]
                )
            }
            return ClickyRenderOp(
                op: opKind,
                group: dict["group"] as? String,
                beforeNodeID: (dict["before"] as? NSNumber)?.intValue,
                nodeID: (dict["n"] as? NSNumber)?.intValue,
                wrapperGroupID: (dict["g"] as? NSNumber)?.intValue,
                childNodeID: (dict["child"] as? NSNumber)?.intValue,
                maskID: dict["mask"] as? String,
                propKey: dict["key"] as? String,
                propValue: dict["value"],
                node: nodeDict.flatMap(parseRenderNode),
                motionBegin: (dict["begin"] as? NSNumber)?.doubleValue,
                motionDuration: (dict["dur"] as? NSNumber)?.doubleValue,
                motionTiming: (dict["fn"] as? [NSNumber])?.map { $0.doubleValue },
                motionItems: motionItems
            )
        }
    }

    private static func parseRenderNode(_ dict: [String: Any]) -> ClickyRenderNode? {
        guard let nodeID = (dict["n"] as? NSNumber)?.intValue,
              let tag = dict["tag"] as? String else {
            return nil
        }

        let rawAttrs = dict["a"] as? [String: Any] ?? [:]
        var attrs: [String: String] = [:]
        for (k, v) in rawAttrs {
            attrs[k] = "\(v)"
        }

        let rawStyles = dict["st"] as? [String: Any] ?? [:]
        var styles: [String: String] = [:]
        for (k, v) in rawStyles {
            styles[k] = "\(v)"
        }

        var animation: ClickyRenderAnimation?
        if let anim = dict["anim"] as? [String: Any],
           let name = anim["name"] as? String {
            animation = ClickyRenderAnimation(
                name: name,
                duration: (anim["dur"] as? NSNumber)?.doubleValue ?? 0,
                delay: (anim["delay"] as? NSNumber)?.doubleValue ?? 0,
                timing: (anim["fn"] as? [NSNumber])?.map { $0.doubleValue } ?? [0.25, 0.1, 0.25, 1],
                startedAt: (anim["at"] as? NSNumber)?.doubleValue ?? CACurrentMediaTime()
            )
        }

        var textDesc: ClickyRenderTextDescription?
        if let textDict = dict["text"] as? [String: Any] {
            let rawLines = textDict["lines"] as? [[String: Any]] ?? []
            let lines = rawLines.map { lineDict in
                ClickyRenderTextLine(
                    x: (lineDict["x"] as? NSNumber)?.doubleValue,
                    dy: (lineDict["dy"] as? NSNumber)?.doubleValue ?? 0,
                    text: lineDict["text"] as? String ?? ""
                )
            }
            textDesc = ClickyRenderTextDescription(
                family: textDict["family"] as? String ?? "sans-serif",
                size: (textDict["size"] as? NSNumber)?.doubleValue ?? 16,
                weight: (textDict["weight"] as? NSNumber)?.intValue ?? 400,
                anchor: textDict["anchor"] as? String ?? "start",
                baseline: textDict["baseline"] as? String ?? "auto",
                x: (textDict["x"] as? NSNumber)?.doubleValue ?? 0,
                y: (textDict["y"] as? NSNumber)?.doubleValue ?? 0,
                lines: lines
            )
        }

        let childDicts = dict["ch"] as? [[String: Any]] ?? []
        let children = childDicts.compactMap(parseRenderNode)

        return ClickyRenderNode(
            nodeID: nodeID,
            tag: tag,
            attributes: attrs,
            styles: styles,
            markIndex: (dict["k"] as? NSNumber)?.intValue,
            animation: animation,
            text: textDesc,
            children: children
        )
    }
}
