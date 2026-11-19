import Foundation
import Testing
@testable import Clicky

struct ClickyAgentsInkTests {
    @Test func answerBlockBecomesBannerAtTop() {
        let document = ClickyInkParser.parse("# Title\nanswer: Yes\nbig: 42\naside: since Monday\n\n## Details\nbody")
        guard case .answerBanner(_, let answer, let big, let aside) = document.blocks.first else {
            Issue.record("expected answer banner first")
            return
        }
        #expect(answer == "Yes")
        #expect(big == "42")
        #expect(aside == "since Monday")
    }

    @Test func answerLinesAfterFirstSectionAreNotBanner() {
        let document = ClickyInkParser.parse("# Title\n\n## Details\nanswer: not a banner")
        let hasBanner = document.blocks.contains { block in
            if case .answerBanner = block { return true }
            return false
        }
        #expect(!hasBanner)
    }

    @Test func outMarkerParsesAsOutBadge() {
        let document = ClickyInkParser.parse("- Option A {out}\n- Option B")
        guard case .unorderedList(_, let items) = document.blocks.first else {
            Issue.record("expected list")
            return
        }
        #expect(items[0].contains(.badge(.out)))
        #expect(!items[1].contains(.badge(.out)))
    }

    @Test func headingKindSuffixIsIgnored() {
        let document = ClickyInkParser.parse("## Options :: mystery")
        guard case .heading(_, _, let inlines) = document.blocks.first else {
            Issue.record("expected heading")
            return
        }
        #expect(inlines == [.text("Options")])
    }
}
