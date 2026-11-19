import Testing
@testable import Clicky

struct ClickyLocalizationTests {

    @Test func systemPreferenceRemovesOverride() {
        #expect(ClickyAppLanguage.appleLanguagesValue(for: "system") == nil)
    }

    @Test func unknownPreferenceFallsBackToSystem() {
        #expect(ClickyAppLanguage.appleLanguagesValue(for: "fr") == nil)
    }

    @Test func englishAndIndonesianMapToSingleLanguage() {
        #expect(ClickyAppLanguage.appleLanguagesValue(for: "en") == ["en"])
        #expect(ClickyAppLanguage.appleLanguagesValue(for: "id") == ["id"])
    }
}
