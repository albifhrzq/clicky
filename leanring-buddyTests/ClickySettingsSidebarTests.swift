import Testing
@testable import Clicky

@MainActor
struct ClickySettingsSidebarTests {
    @Test func everySectionAppearsExactlyOnceInSidebarGroups() {
        // Arrange
        let sectionsInSidebar = HomeSpaceSettingsSection.sidebarGroups.flatMap { $0.sections }

        // Act / Assert
        #expect(sectionsInSidebar.count == HomeSpaceSettingsSection.allCases.count)
        for section in HomeSpaceSettingsSection.allCases {
            #expect(sectionsInSidebar.filter { $0 == section }.count == 1)
        }
    }

    @Test func everySectionHasTitleAndSubtitle() {
        for section in HomeSpaceSettingsSection.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.subtitle.isEmpty)
        }
    }
}
