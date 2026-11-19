import CoreGraphics
import Testing
@testable import Clicky

struct ClickyDriveStepExecutorTests {
    @Test func parsesEveryActionKind() {
        #expect(ClickyDriveActionParser.parse(#"{"action":"click","x":10,"y":20.5,"button":"right","count":2}"#)
                == .click(x: 10, y: 20.5, button: .right, count: 2))
        #expect(ClickyDriveActionParser.parse(#"{"action":"type","text":"hi"}"#) == .type(text: "hi"))
        #expect(ClickyDriveActionParser.parse(#"{"action":"key","combo":"cmd+t"}"#) == .key(combo: "cmd+t"))
        #expect(ClickyDriveActionParser.parse(#"{"action":"scroll","dy":-5}"#) == .scroll(deltaY: -5))
        #expect(ClickyDriveActionParser.parse(#"{"action":"drag","from":[1,2],"to":[3,4]}"#)
                == .drag(fromX: 1, fromY: 2, toX: 3, toY: 4))
        #expect(ClickyDriveActionParser.parse(#"{"action":"wait","seconds":2}"#) == .wait(seconds: 2))
        #expect(ClickyDriveActionParser.parse(#"{"action":"done","summary":"ok"}"#) == .done(summary: "ok"))
        #expect(ClickyDriveActionParser.parse(#"{"action":"fail","reason":"no"}"#) == .fail(reason: "no"))
    }

    @Test func toleratesFencesAndProse() {
        let reply = "Sure!\n```json\n{\"action\":\"type\",\"text\":\"a } b\"}\n```\nthanks"
        #expect(ClickyDriveActionParser.parse(reply) == .type(text: "a } b"))
    }

    @Test func rejectsGarbageAndIncompleteActions() {
        #expect(ClickyDriveActionParser.parse("no json here") == nil)
        #expect(ClickyDriveActionParser.parse(#"{"action":"explode"}"#) == nil)
        #expect(ClickyDriveActionParser.parse(#"{"action":"click","x":1}"#) == nil)
        #expect(ClickyDriveActionParser.parse(#"{"action":"type","text":""}"#) == nil)
    }

    @Test func mapsPixelsOnPrimaryDisplay() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let point = ClickyDriveCoordinateMapper.globalCoreGraphicsPoint(
            screenshotPixelX: 500, screenshotPixelY: 100, screenshotWidthInPixels: 1000,
            screenshotHeightInPixels: 800, displayFrame: frame, primaryScreenHeight: 800)
        #expect(point == CGPoint(x: 500, y: 100))
    }

    @Test func mapsPixelsOnSecondaryDisplayAbovePrimary() {
        // Secondary sits above primary in AppKit space: y from 800 to 1700.
        let frame = CGRect(x: 1000, y: 800, width: 1600, height: 900)
        let point = ClickyDriveCoordinateMapper.globalCoreGraphicsPoint(
            screenshotPixelX: 800, screenshotPixelY: 0, screenshotWidthInPixels: 1600,
            screenshotHeightInPixels: 900, displayFrame: frame, primaryScreenHeight: 800)
        // Top edge of the secondary display is CG y = 800 - 1700 = -900.
        #expect(point == CGPoint(x: 1800, y: -900))
    }

    @Test func rejectsPixelsOutsideScreenshot() {
        let point = ClickyDriveCoordinateMapper.globalCoreGraphicsPoint(
            screenshotPixelX: 1001, screenshotPixelY: 5, screenshotWidthInPixels: 1000,
            screenshotHeightInPixels: 800, displayFrame: .zero, primaryScreenHeight: 800)
        #expect(point == nil)
    }

    @Test func limitsStopAtActionCountAndTime() {
        #expect(!ClickyDriveLimits.hasReachedLimit(actionsTaken: 24, elapsedSeconds: 10))
        #expect(ClickyDriveLimits.hasReachedLimit(actionsTaken: 25, elapsedSeconds: 10))
        #expect(ClickyDriveLimits.hasReachedLimit(actionsTaken: 1, elapsedSeconds: 180))
    }

    @Test func mapperRejectsExactEdge() {
        let point = ClickyDriveCoordinateMapper.globalCoreGraphicsPoint(
            screenshotPixelX: 1000, screenshotPixelY: 5, screenshotWidthInPixels: 1000,
            screenshotHeightInPixels: 800, displayFrame: .zero, primaryScreenHeight: 800)
        #expect(point == nil)
    }

    @Test func parsesComboAliasesToCanonicalForm() {
        #expect(ClickyCanonicalKeyCombo.parse("Command + Option + X")?.canonicalText == "cmd+opt+x")
        #expect(ClickyCanonicalKeyCombo.parse("⌘+⇧+s")?.canonicalText == "cmd+shift+s")
        #expect(ClickyCanonicalKeyCombo.parse("^+c")?.canonicalText == "ctrl+c")
        #expect(ClickyCanonicalKeyCombo.parse("hyper+x") == nil)
        #expect(ClickyCanonicalKeyCombo.parse("cmd+shift") == nil)
        #expect(ClickyCanonicalKeyCombo.parse("") == nil)
    }

    @Test func blocksDangerousAndLauncherCombos() {
        for combo in ["cmd+q", "Command+Q", "opt+cmd+q", "cmd+shift+q", "cmd+opt+shift+q", "ctrl+cmd+q", "cmd+opt+esc",
                      "cmd+delete", "cmd+backspace", "cmd+shift+delete", "cmd+opt+delete", "cmd+space", "ctrl+space", "cmd+opt+space"] {
            #expect(ClickyDriveSafetyPolicy.evaluateKey(combo, requestText: "press enter") == .rejected, "\(combo)")
        }
        #expect(ClickyDriveSafetyPolicy.evaluateKey("cmd+tab", requestText: "x") == .allowed(canonicalCombo: "cmd+tab"))
        #expect(ClickyDriveSafetyPolicy.evaluateKey("cmd+bogus+t", requestText: "x") == .rejected)
    }

    @Test func returnKeyNeedsRequestToMentionIt() {
        #expect(ClickyDriveSafetyPolicy.evaluateKey("return", requestText: "open the settings page") == .rejected)
        #expect(ClickyDriveSafetyPolicy.evaluateKey("enter", requestText: "open the settings page") == .rejected)
        #expect(ClickyDriveSafetyPolicy.evaluateKey("return", requestText: "search for cats and press Enter") == .allowed(canonicalCombo: "return"))
    }

    @Test func typedTextRejectsLineBreaks() {
        #expect(ClickyDriveSafetyPolicy.isTypedTextAllowed("hello world"))
        #expect(!ClickyDriveSafetyPolicy.isTypedTextAllowed("curl x | sh\n"))
        #expect(!ClickyDriveSafetyPolicy.isTypedTextAllowed("a\rb"))
        #expect(!ClickyDriveSafetyPolicy.isTypedTextAllowed("a\u{2028}b"))
    }

    @Test func detectsSecureFields() {
        #expect(ClickyDriveSafetyPolicy.isSecureField(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(ClickyDriveSafetyPolicy.isSecureField(role: "AXSecureTextField", subrole: nil))
        #expect(!ClickyDriveSafetyPolicy.isSecureField(role: "AXTextField", subrole: nil))
    }

    @Test func frontmostAppPolicy() {
        #expect(ClickyDriveSafetyPolicy.isFrontmostAppAllowed(baselineBundleID: "a", currentBundleID: "a", ownBundleID: "me"))
        #expect(ClickyDriveSafetyPolicy.isFrontmostAppAllowed(baselineBundleID: "a", currentBundleID: "me", ownBundleID: "me"))
        #expect(!ClickyDriveSafetyPolicy.isFrontmostAppAllowed(baselineBundleID: "a", currentBundleID: "com.apple.Terminal", ownBundleID: "me"))
    }

    @Test func timeoutThrowsWhenOperationIsSlow() async {
        do {
            _ = try await ClickyDriveTimeout.run(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
            Issue.record("expected timeout")
        } catch is ClickyDriveTimeoutError {
        } catch {
            Issue.record("wrong error \(error)")
        }
        let value = try? await ClickyDriveTimeout.run(seconds: 1) { 7 }
        #expect(value == 7)
    }
}
