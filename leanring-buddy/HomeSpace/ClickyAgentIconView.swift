//
//  ClickyAgentIconView.swift
//  leanring-buddy
//
//  Expressive animated avatar view for each Clicky buddy with mood expressions
//  and an SF Symbol prop badge covering all 28 ClickyAgentProp cases.
//

import AppKit
import Foundation
import SwiftUI

public nonisolated enum ClickyAgentMood: String, CaseIterable, Codable, Sendable, Hashable {
    case idle
    case working
    case happy
    case needsYou
    case failed
    case sleepy

    public var accessibilityDescription: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .happy: return "Happy"
        case .needsYou: return "Needs your attention"
        case .failed: return "Failed"
        case .sleepy: return "Sleepy"
        }
    }

    public var accentColor: Color {
        switch self {
        case .idle: return DS.Colors.blue400
        case .working: return DS.Colors.blue500
        case .happy: return DS.Colors.success
        case .needsYou: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        case .sleepy: return DS.Colors.textSecondary
        }
    }
}

public struct ClickyAgentIconView: View {
    public let agentKey: String
    public let title: String
    public let mood: ClickyAgentMood
    public let prop: ClickyAgentProp
    public let baseHue: Double
    public let size: CGFloat

    @State private var isBlinking: Bool = false
    @State private var isPulsing: Bool = false
    @State private var workingLookOffset: CGFloat = -1.0
    @State private var blinkTask: Task<Void, Never>?

    public init(
        agentKey: String,
        title: String = "",
        mood: ClickyAgentMood = .idle,
        prop: ClickyAgentProp = .sparkle,
        baseHue: Double = 0.58,
        size: CGFloat = 36
    ) {
        self.agentKey = agentKey
        self.title = title
        self.mood = mood
        self.prop = prop
        self.baseHue = baseHue
        self.size = size
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarSphere
                .frame(width: size, height: size)

            if size >= 20 {
                propBadge
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onAppear {
            startAnimationsForCurrentMood()
        }
        .onChange(of: mood) { _, _ in
            startAnimationsForCurrentMood()
        }
        .onDisappear {
            blinkTask?.cancel()
            blinkTask = nil
        }
    }

    private var accessibilityText: String {
        let baseName = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? agentKey : title
        return "\(baseName), \(mood.accessibilityDescription)"
    }

    private var normalizedHue: Double {
        if baseHue.isFinite {
            let wrapped = baseHue.truncatingRemainder(dividingBy: 1.0)
            return wrapped >= 0 ? wrapped : wrapped + 1.0
        }
        let scalarSum = agentKey.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31) &+ Int(scalar.value)
        }
        return Double(abs(scalarSum) % 360) / 360.0
    }

    private var bodyTopColor: Color {
        switch mood {
        case .failed:
            return Color(hue: normalizedHue, saturation: 0.42, brightness: 0.86)
        case .sleepy:
            return Color(hue: normalizedHue, saturation: 0.36, brightness: 0.80)
        default:
            return Color(hue: normalizedHue, saturation: 0.58, brightness: 0.96)
        }
    }

    private var bodyBottomColor: Color {
        switch mood {
        case .failed:
            return Color(hue: normalizedHue, saturation: 0.55, brightness: 0.58)
        case .sleepy:
            return Color(hue: normalizedHue, saturation: 0.48, brightness: 0.54)
        default:
            return Color(hue: normalizedHue, saturation: 0.78, brightness: 0.72)
        }
    }

    private var haloRingColor: Color {
        switch mood {
        case .working:
            return DS.Colors.blue400.opacity(isPulsing ? 0.85 : 0.25)
        case .needsYou:
            return DS.Colors.warning.opacity(isPulsing ? 0.92 : 0.35)
        case .happy:
            return DS.Colors.success.opacity(0.65)
        case .failed:
            return DS.Colors.destructive.opacity(0.75)
        case .idle, .sleepy:
            return Color.white.opacity(0.18)
        }
    }

    private var avatarSphere: some View {
        ZStack {
            // Outer status ring for active / attention / failed moods
            if mood == .working || mood == .needsYou || mood == .failed || mood == .happy {
                Circle()
                    .stroke(haloRingColor, lineWidth: max(1.5, size * 0.06))
                    .scaleEffect((mood == .working || mood == .needsYou) && isPulsing ? 1.12 : 1.04)
            }

            // Main pastel/vivid orb
            Circle()
                .fill(
                    LinearGradient(
                        colors: [bodyTopColor, bodyBottomColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    // Aqua-inspired upper specular sheen
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.45),
                                    Color.white.opacity(0.08),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .padding(size * 0.06)
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.32), lineWidth: max(0.8, size * 0.028))
                )
                .shadow(color: bodyBottomColor.opacity(0.35), radius: size * 0.14, x: 0, y: size * 0.06)

            // Expressive face
            faceExpressionView
                .offset(y: mood == .happy && isPulsing ? -size * 0.025 : 0)

            // Sleepy floating "z" indicator on larger avatars
            if mood == .sleepy && size >= 30 {
                Text("z")
                    .font(.system(size: max(8, size * 0.22), weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.88))
                    .offset(x: size * 0.26, y: -size * 0.30)
            }
        }
    }

    private var faceExpressionView: some View {
        let eyeWidth = max(2.0, size * 0.11)
        let eyeHeight = max(2.0, size * 0.16)
        let eyeSpacing = max(4.0, size * 0.19)
        let strokeWeight = max(1.3, size * 0.055)
        let faceTint = Color(red: 0.08, green: 0.10, blue: 0.14)

        return VStack(spacing: max(1.5, size * 0.07)) {
            HStack(spacing: eyeSpacing) {
                eyeView(
                    eyeWidth: eyeWidth,
                    eyeHeight: eyeHeight,
                    strokeWeight: strokeWeight,
                    tint: faceTint
                )
                eyeView(
                    eyeWidth: eyeWidth,
                    eyeHeight: eyeHeight,
                    strokeWeight: strokeWeight,
                    tint: faceTint
                )
            }

            mouthView(strokeWeight: strokeWeight, tint: faceTint)
        }
        .offset(y: size * 0.02)
    }

    @ViewBuilder
    private func eyeView(
        eyeWidth: CGFloat,
        eyeHeight: CGFloat,
        strokeWeight: CGFloat,
        tint: Color
    ) -> some View {
        switch mood {
        case .idle:
            if isBlinking {
                Capsule()
                    .fill(tint)
                    .frame(width: eyeWidth * 1.15, height: max(1.5, strokeWeight * 0.9))
            } else {
                ZStack(alignment: .topTrailing) {
                    Capsule()
                        .fill(tint)
                        .frame(width: eyeWidth, height: eyeHeight)
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: max(1.2, eyeWidth * 0.42), height: max(1.2, eyeWidth * 0.42))
                        .offset(x: -eyeWidth * 0.12, y: eyeHeight * 0.12)
                }
            }

        case .working:
            ZStack {
                Capsule()
                    .fill(tint)
                    .frame(width: eyeWidth * 1.05, height: eyeHeight * 0.88)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(1.2, eyeWidth * 0.42), height: max(1.2, eyeWidth * 0.42))
                    .offset(x: workingLookOffset * eyeWidth * 0.18, y: -eyeHeight * 0.14)
            }

        case .happy:
            ClickyHappyEyeShape()
                .stroke(tint, style: StrokeStyle(lineWidth: strokeWeight, lineCap: .round))
                .frame(width: eyeWidth * 1.35, height: eyeHeight * 0.55)

        case .needsYou:
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: eyeWidth * 1.45, height: eyeWidth * 1.45)
                Circle()
                    .fill(tint)
                    .frame(width: eyeWidth * 0.85, height: eyeWidth * 0.85)
                Circle()
                    .fill(Color.white)
                    .frame(width: max(1.0, eyeWidth * 0.3), height: max(1.0, eyeWidth * 0.3))
                    .offset(x: eyeWidth * 0.16, y: -eyeWidth * 0.16)
            }

        case .failed:
            ClickyCrossEyeShape()
                .stroke(tint, style: StrokeStyle(lineWidth: strokeWeight * 0.9, lineCap: .round))
                .frame(width: eyeWidth * 1.15, height: eyeWidth * 1.15)

        case .sleepy:
            ClickySleepyEyeShape()
                .stroke(tint, style: StrokeStyle(lineWidth: strokeWeight * 0.9, lineCap: .round))
                .frame(width: eyeWidth * 1.25, height: eyeHeight * 0.45)
        }
    }

    @ViewBuilder
    private func mouthView(strokeWeight: CGFloat, tint: Color) -> some View {
        let mouthWidth = max(4.0, size * 0.24)
        let mouthHeight = max(2.0, size * 0.11)

        switch mood {
        case .idle:
            ClickySmileShape(curvature: 0.7)
                .stroke(tint, style: StrokeStyle(lineWidth: strokeWeight * 0.9, lineCap: .round))
                .frame(width: mouthWidth * 0.85, height: mouthHeight * 0.75)

        case .working:
            Capsule()
                .fill(tint)
                .frame(width: mouthWidth * 0.5, height: max(1.8, strokeWeight * 0.9))

        case .happy:
            ClickySmileShape(curvature: 1.0)
                .stroke(tint, style: StrokeStyle(lineWidth: strokeWeight, lineCap: .round))
                .frame(width: mouthWidth * 1.05, height: mouthHeight)

        case .needsYou:
            Circle()
                .stroke(tint, lineWidth: strokeWeight * 0.85)
                .frame(width: mouthHeight * 1.05, height: mouthHeight * 1.05)

        case .failed:
            ClickyFrownShape()
                .stroke(tint, style: StrokeStyle(lineWidth: strokeWeight * 0.9, lineCap: .round))
                .frame(width: mouthWidth * 0.85, height: mouthHeight * 0.75)

        case .sleepy:
            Circle()
                .fill(tint.opacity(0.82))
                .frame(width: max(2.2, mouthHeight * 0.75), height: max(2.2, mouthHeight * 0.75))
        }
    }

    private var propBadge: some View {
        let badgeSize = max(13.0, size * 0.40)
        let badgeTint = propAccentColor(for: prop)

        return ZStack {
            Circle()
                .fill(DS.Colors.surface1)
            Circle()
                .fill(badgeTint.opacity(0.22))
            Circle()
                .stroke(badgeTint.opacity(0.65), lineWidth: max(0.8, badgeSize * 0.07))

            Image(systemName: prop.systemImageName)
                .font(.system(size: badgeSize * 0.52, weight: .semibold))
                .foregroundColor(badgeTint)
        }
        .frame(width: badgeSize, height: badgeSize)
        .shadow(color: Color.black.opacity(0.42), radius: 3, x: 0, y: 1.5)
    }

    private func propAccentColor(for agentProp: ClickyAgentProp) -> Color {
        switch agentProp {
        case .pencil:
            return Color(hex: "#FBBF24")
        case .hammer:
            return Color(hex: "#60A5FA")
        case .envelope:
            return Color(hex: "#38BDF8")
        case .magnifier:
            return Color(hex: "#93C5FD")
        case .paintbrush:
            return Color(hex: "#F472B6")
        case .paperPlane:
            return Color(hex: "#34D399")
        case .cart:
            return Color(hex: "#FB923C")
        case .book:
            return Color(hex: "#A78BFA")
        case .chart:
            return Color(hex: "#2DD4BF")
        case .musicNote:
            return Color(hex: "#EC4899")
        case .camera:
            return Color(hex: "#CBD5E1")
        case .clipboard:
            return Color(hex: "#60A5FA")
        case .pan:
            return Color(hex: "#F97316")
        case .globe:
            return Color(hex: "#22D3EE")
        case .gear:
            return Color(hex: "#94A3B8")
        case .lightbulb:
            return Color(hex: "#FACC15")
        case .heart:
            return Color(hex: "#FB7185")
        case .clock:
            return Color(hex: "#38BDF8")
        case .mapPin:
            return Color(hex: "#F87171")
        case .gift:
            return Color(hex: "#E879F9")
        case .trophy:
            return Color(hex: "#FBBF24")
        case .key:
            return Color(hex: "#FDE047")
        case .flask:
            return Color(hex: "#4ADE80")
        case .graduationCap:
            return Color(hex: "#818CF8")
        case .speechBubble:
            return Color(hex: "#60A5FA")
        case .sparkle:
            return Color(hex: "#C084FC")
        case .star:
            return Color(hex: "#FBBF24")
        case .bolt:
            return Color(hex: "#FACC15")
        }
    }

    private func startAnimationsForCurrentMood() {
        blinkTask?.cancel()
        blinkTask = nil
        isBlinking = false
        isPulsing = false
        workingLookOffset = -1.0

        switch mood {
        case .idle:
            blinkTask = Task { @MainActor in
                while !Task.isCancelled {
                    let waitSeconds = Double.random(in: 2.6...5.2)
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    if Task.isCancelled { break }
                    withAnimation(.easeInOut(duration: 0.08)) {
                        isBlinking = true
                    }
                    try? await Task.sleep(nanoseconds: 130_000_000)
                    if Task.isCancelled { break }
                    withAnimation(.easeInOut(duration: 0.08)) {
                        isBlinking = false
                    }
                }
            }

        case .working:
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
                workingLookOffset = 1.0
            }

        case .needsYou:
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                isPulsing = true
            }

        case .happy:
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }

        case .failed, .sleepy:
            break
        }
    }
}

// MARK: - Facial Expression Shapes

private struct ClickySmileShape: Shape {
    let curvature: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startPoint = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
        let endPoint = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
        let controlPoint = CGPoint(
            x: rect.midX,
            y: rect.minY + rect.height * (0.35 + curvature * 0.85)
        )
        path.move(to: startPoint)
        path.addQuadCurve(to: endPoint, control: controlPoint)
        return path
    }
}

private struct ClickyFrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startPoint = CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.2)
        let endPoint = CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.2)
        let controlPoint = CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.2)
        path.move(to: startPoint)
        path.addQuadCurve(to: endPoint, control: controlPoint)
        return path
    }
}

private struct ClickyHappyEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.35)
        )
        return path
    }
}

private struct ClickySleepyEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.35)
        )
        return path
    }
}

private struct ClickyCrossEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}
