//
//  ActiveDocumentReader.swift
//  leanring-buddy
//

import AppKit
import ApplicationServices
import Combine
import CoreFoundation
import Foundation
import PDFKit

public nonisolated enum ActiveDocumentReference: Equatable, Codable, Sendable {
    case webPage(urlString: String, title: String?)
    case file(path: String, title: String?)

    public var rawLocation: String {
        switch self {
        case .webPage(let urlString, _):
            return urlString
        case .file(let path, _):
            return path
        }
    }

    public var displayTitle: String {
        switch self {
        case .webPage(let urlString, let title):
            if let title, !title.isEmpty {
                return title
            }
            return urlString
        case .file(let path, let title):
            if let title, !title.isEmpty {
                return title
            }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }
}

public nonisolated enum ActiveDocumentKind: String, Codable, Equatable, Sendable {
    case webPage
    case pdf
    case textFile
    case officeOrRichDocument
    case finderSelection
    case accessibilityWindow
    case unknown
}

public nonisolated struct ActiveDocumentContext: Equatable, Sendable {
    public let kind: ActiveDocumentKind
    public let reference: ActiveDocumentReference
    public let extractedText: String
    public let isTruncated: Bool
    public let pageCount: Int?
    public let fileAccessWasDenied: Bool
    public let selectedText: String?
    public let applicationName: String?
    public let applicationBundleIdentifier: String?
    public let applicationProcessIdentifier: pid_t?
    public let windowTitle: String?

    public init(
        kind: ActiveDocumentKind,
        reference: ActiveDocumentReference,
        extractedText: String,
        isTruncated: Bool,
        pageCount: Int? = nil,
        fileAccessWasDenied: Bool = false,
        selectedText: String? = nil,
        applicationName: String? = nil,
        applicationBundleIdentifier: String? = nil,
        applicationProcessIdentifier: pid_t? = nil,
        windowTitle: String? = nil
    ) {
        self.kind = kind
        self.reference = reference
        self.extractedText = extractedText
        self.isTruncated = isTruncated
        self.pageCount = pageCount
        self.fileAccessWasDenied = fileAccessWasDenied
        self.selectedText = selectedText
        self.applicationName = applicationName
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationProcessIdentifier = applicationProcessIdentifier
        self.windowTitle = windowTitle
    }

    public func promptContextSummary() -> String {
        switch reference {
        case .file(let path, _):
            return "Context: the user currently has this file open on screen: \(path) — if the task relates to it, open and read the file directly instead of relying on the screenshot's visible portion."
        case .webPage(let urlString, _):
            return "Context: the user currently has this page open in their browser: \(urlString) — if the task is about what it says, fetch that page (or search the web) instead of relying on the screenshot's visible portion; if the task means acting on it (clicking, filling, posting), use the browser tool in their tab."
        }
    }
}

public nonisolated struct DocumentAccessNotice: Equatable, Identifiable, Sendable {
    public var id: String { deniedFilePath }

    public let title: String
    public let subtitle: String
    public let deniedFilePath: String
    public let folderName: String
    public let showsDontShowAgain: Bool
    public let settingsURL: URL

    public init(
        title: String = "HeyClicky can't read this document",
        subtitle: String,
        deniedFilePath: String,
        folderName: String,
        showsDontShowAgain: Bool = false,
        settingsURL: URL = ActiveDocumentReader.privacyFilesAndFoldersURL
    ) {
        self.title = title
        self.subtitle = subtitle
        self.deniedFilePath = deniedFilePath
        self.folderName = folderName
        self.showsDontShowAgain = showsDontShowAgain
        self.settingsURL = settingsURL
    }
}

public nonisolated enum ActiveBrowserSiteReader {
    public nonisolated struct SupportedBrowser: Sendable {
        public let bundleIdentifiers: [String]
        public let displayName: String
        public let appleScriptKind: AppleScriptKind?

        public nonisolated enum AppleScriptKind: Sendable {
            case safari
            case chromium
        }
    }

    /// Covers 14 supported browsers (Safari, Safari Tech Preview, Chrome, Arc, Dia,
    /// Brave, Edge, Opera, Opera GX, Vivaldi, Comet, ChatGPT Atlas, Aside, Zen/Firefox).
    public static let supportedBrowsers: [SupportedBrowser] = [
        SupportedBrowser(bundleIdentifiers: ["com.apple.Safari"], displayName: "Safari", appleScriptKind: .safari),
        SupportedBrowser(bundleIdentifiers: ["com.apple.SafariTechnologyPreview"], displayName: "Safari Technology Preview", appleScriptKind: .safari),
        SupportedBrowser(bundleIdentifiers: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"], displayName: "Google Chrome", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["company.thebrowser.Browser"], displayName: "Arc", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["company.thebrowser.Dia"], displayName: "Dia", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"], displayName: "Brave", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"], displayName: "Microsoft Edge", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["com.operasoftware.Opera"], displayName: "Opera", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["com.operasoftware.OperaGX"], displayName: "Opera GX", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["com.vivaldi.Vivaldi"], displayName: "Vivaldi", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["ai.perplexity.comet"], displayName: "Comet", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["com.openai.atlas"], displayName: "ChatGPT Atlas", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["com.openai.chatgpt.atlas"], displayName: "ChatGPT Atlas", appleScriptKind: .chromium),
        SupportedBrowser(bundleIdentifiers: ["at.studio.asidebrowser"], displayName: "Aside", appleScriptKind: .chromium)
    ]

    public static let extraBrowserBundleIDs: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.duckduckgo.macos.browser",
        "app.zen-browser.zen"
    ]

    public static func isSupportedBrowser(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let lowered = bundleIdentifier.lowercased()
        if supportedBrowsers.contains(where: { browser in
            browser.bundleIdentifiers.contains(where: { identifier in identifier.lowercased() == lowered })
        }) {
            return true
        }
        return extraBrowserBundleIDs.contains(lowered)
    }

    public static func browserEntry(forBundleIdentifier bundleIdentifier: String) -> SupportedBrowser? {
        let lowered = bundleIdentifier.lowercased()
        return supportedBrowsers.first { browser in
            browser.bundleIdentifiers.contains { identifier in identifier.lowercased() == lowered }
        }
    }

    public static func captureCurrentBrowserURLString() async -> String? {
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }
        guard let frontmost,
              let bundleIdentifier = frontmost.bundleIdentifier,
              isSupportedBrowser(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let pid = frontmost.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            guard AXIsProcessTrusted() else { return nil }
            let appElement = AXUIElementCreateApplication(pid)
            guard let focusedWindow = ActiveDocumentReader.copyElementAttribute(
                appElement,
                attribute: kAXFocusedWindowAttribute as String
            ) else {
                return nil
            }
            return readURLFromBrowserWindow(focusedWindow, bundleIdentifier: bundleIdentifier)
        }.value
    }

    public static func readURLFromBrowserWindow(
        _ windowElement: AXUIElement,
        bundleIdentifier: String
    ) -> String? {
        // 1. Check AXURL / AXDocument on the window or any AXWebArea descendant.
        if let directURL = ActiveDocumentReader.copyURLStringAttribute(windowElement, attribute: kAXURLAttribute as String),
           isLikelyWebURL(directURL) {
            return directURL
        }

        if let documentString = ActiveDocumentReader.copyStringAttribute(windowElement, attribute: kAXDocumentAttribute as String),
           isLikelyWebURL(documentString) {
            return documentString
        }

        // 2. Walk AX hierarchy (bounded breadth/depth) looking for address bar or AXWebArea URL.
        var queue: [(element: AXUIElement, depth: Int)] = [(windowElement, 0)]
        var visitedCount = 0
        let maxVisitedNodes = 450

        while !queue.isEmpty && visitedCount < maxVisitedNodes {
            let current = queue.removeFirst()
            visitedCount += 1

            let role = ActiveDocumentReader.copyStringAttribute(current.element, attribute: kAXRoleAttribute as String) ?? ""
            if role == "AXWebArea" {
                if let webURL = ActiveDocumentReader.copyURLStringAttribute(current.element, attribute: kAXURLAttribute as String),
                   isLikelyWebURL(webURL) {
                    return webURL
                }
            }

            if role == kAXTextFieldRole as String || role == kAXComboBoxRole as String {
                if isAddressField(current.element),
                   let rawValue = ActiveDocumentReader.copyStringAttribute(current.element, attribute: kAXValueAttribute as String),
                   let normalized = normalizeAddressBarValue(rawValue) {
                    return normalized
                }
            }

            if current.depth < 10,
               let children = ActiveDocumentReader.copyElementArrayAttribute(current.element, attribute: kAXChildrenAttribute as String) {
                for child in children.prefix(60) {
                    queue.append((child, current.depth + 1))
                }
            }
        }

        // 3. Best-effort AppleScript fallback for Safari / Chromium browsers when AX address bar didn't expose scheme/host.
        if let browser = browserEntry(forBundleIdentifier: bundleIdentifier),
           let scriptKind = browser.appleScriptKind,
           let matchedBundleID = browser.bundleIdentifiers.first {
            return readActiveTabURLViaAppleScript(bundleIdentifier: matchedBundleID, kind: scriptKind)
        }

        return nil
    }

    private static func isAddressField(_ element: AXUIElement) -> Bool {
        let descriptors = [
            ActiveDocumentReader.copyStringAttribute(element, attribute: kAXIdentifierAttribute as String),
            ActiveDocumentReader.copyStringAttribute(element, attribute: kAXRoleDescriptionAttribute as String),
            ActiveDocumentReader.copyStringAttribute(element, attribute: kAXDescriptionAttribute as String),
            ActiveDocumentReader.copyStringAttribute(element, attribute: kAXTitleAttribute as String)
        ]
        .compactMap { value in value?.lowercased() }

        let knownMarkers = [
            "web_browser_address_and_search_field",
            "urlandsearch",
            "location_bar",
            "address and search",
            "url field",
            "smart search field",
            "search or enter website",
            "address",
            "location"
        ]

        return descriptors.contains { descriptor in
            knownMarkers.contains { marker in descriptor.contains(marker) }
        }
    }

    private static func isLikelyWebURL(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("file://")
    }

    private static func normalizeAddressBarValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("file://") {
            return trimmed
        }
        if trimmed.contains(".") && !trimmed.hasPrefix(".") && !trimmed.hasSuffix(".") {
            return "https://\(trimmed)"
        }
        return nil
    }

    private static func readActiveTabURLViaAppleScript(
        bundleIdentifier: String,
        kind: SupportedBrowser.AppleScriptKind
    ) -> String? {
        let source: String
        switch kind {
        case .safari:
            source = """
            tell application id "\(bundleIdentifier)"
                if (count of windows) > 0 then
                    return URL of current tab of front window
                end if
            end tell
            """
        case .chromium:
            source = """
            tell application id "\(bundleIdentifier)"
                if (count of windows) > 0 then
                    return URL of active tab of front window
                end if
            end tell
            """
        }

        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else { return nil }
        let urlString = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let urlString, !urlString.isEmpty else { return nil }
        return urlString
    }
}

@MainActor
public final class ActiveDocumentReader: ObservableObject {
    public nonisolated struct CollectedPageText: Equatable, Sendable {
        public let text: String
        public let isTruncated: Bool

        public init(text: String, isTruncated: Bool) {
            self.text = text
            self.isTruncated = isTruncated
        }
    }

    public static let shared = ActiveDocumentReader()

    public nonisolated static let privacyFilesAndFoldersURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )!
    public static let noticeShowCountDefaultsKey = "clicky.documentAccess.noticeShowCount.v1"
    public static let noticeSuppressedDefaultsKey = "clicky.documentAccess.noticeSuppressed.v1"

    @Published private(set) var activeDocumentAccessNotice: DocumentAccessNotice?
    @Published private(set) var lastCapturedContext: ActiveDocumentContext?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func captureActiveContext(maxCharacters: Int = 80_000) async -> ActiveDocumentContext? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let frontmost else { return nil }

        let applicationName = frontmost.localizedName
        let bundleIdentifier = frontmost.bundleIdentifier
        let pid = frontmost.processIdentifier

        let context = await Task.detached(priority: .userInitiated) {
            Self.captureSynchronously(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                pid: pid,
                maxCharacters: maxCharacters
            )
        }.value

        if let context {
            lastCapturedContext = context
            if context.fileAccessWasDenied {
                presentAccessDeniedNotice(forPath: context.reference.rawLocation)
            } else {
                activeDocumentAccessNotice = nil
            }
        }
        return context
    }

    public func openFilesAndFoldersPrivacySettings() {
        NSWorkspace.shared.open(Self.privacyFilesAndFoldersURL)
    }

    public func dismissAccessNotice(dontShowAgain: Bool = false) {
        activeDocumentAccessNotice = nil
        if dontShowAgain {
            defaults.set(true, forKey: Self.noticeSuppressedDefaultsKey)
        }
    }

    public func resetAccessNoticeSuppression() {
        defaults.set(false, forKey: Self.noticeSuppressedDefaultsKey)
        defaults.set(0, forKey: Self.noticeShowCountDefaultsKey)
    }

    private func presentAccessDeniedNotice(forPath deniedPath: String) {
        if defaults.bool(forKey: Self.noticeSuppressedDefaultsKey) {
            return
        }
        let showCount = defaults.integer(forKey: Self.noticeShowCountDefaultsKey) + 1
        defaults.set(showCount, forKey: Self.noticeShowCountDefaultsKey)

        let folderName = Self.protectedFolderDisplayName(forPath: deniedPath)
        activeDocumentAccessNotice = DocumentAccessNotice(
            title: "HeyClicky can't read this document",
            subtitle: "Allow access to your \(folderName) folder",
            deniedFilePath: deniedPath,
            folderName: folderName,
            showsDontShowAgain: showCount >= 2,
            settingsURL: Self.privacyFilesAndFoldersURL
        )
    }

    // MARK: - Nonisolated Extraction Workers

    private nonisolated static func captureSynchronously(
        applicationName: String?,
        bundleIdentifier: String?,
        pid: pid_t,
        maxCharacters: Int
    ) -> ActiveDocumentContext? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        guard let focusedWindow = copyElementAttribute(appElement, attribute: kAXFocusedWindowAttribute as String) else {
            return nil
        }

        let windowTitle = copyStringAttribute(focusedWindow, attribute: kAXTitleAttribute as String)
        let focusedUIElement = copyElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute as String)
        let selectedText = focusedUIElement.flatMap { element in
            copyStringAttribute(element, attribute: kAXSelectedTextAttribute as String)
        }

        // 1. Browser URL + AX page text capture across all 14+ supported browsers.
        if ActiveBrowserSiteReader.isSupportedBrowser(bundleIdentifier: bundleIdentifier),
           let bundleIdentifier,
           let urlString = ActiveBrowserSiteReader.readURLFromBrowserWindow(focusedWindow, bundleIdentifier: bundleIdentifier) {
            if urlString.hasPrefix("file://"), let localFileURL = URL(string: urlString), localFileURL.isFileURL {
                return buildLocalFileContext(
                    fileURL: localFileURL,
                    windowTitle: windowTitle,
                    selectedText: selectedText,
                    applicationName: applicationName,
                    bundleIdentifier: bundleIdentifier,
                    pid: pid,
                    maxCharacters: maxCharacters,
                    fallbackWindow: focusedWindow
                )
            }

            let harvested = collectTextFromAccessibilityTree(focusedWindow, maxCharacters: maxCharacters)
            return ActiveDocumentContext(
                kind: .webPage,
                reference: .webPage(urlString: urlString, title: windowTitle),
                extractedText: harvested.text,
                isTruncated: harvested.isTruncated,
                pageCount: nil,
                fileAccessWasDenied: false,
                selectedText: selectedText,
                applicationName: applicationName,
                applicationBundleIdentifier: bundleIdentifier,
                applicationProcessIdentifier: pid,
                windowTitle: windowTitle
            )
        }

        // 2. Local file from AXDocument / AXURL (Preview, TextEdit, Xcode, Pages, Word, Finder, etc.).
        if let fileURL = resolveLocalFileURL(fromWindow: focusedWindow, focusedElement: focusedUIElement) {
            return buildLocalFileContext(
                fileURL: fileURL,
                windowTitle: windowTitle,
                selectedText: selectedText,
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                pid: pid,
                maxCharacters: maxCharacters,
                fallbackWindow: focusedWindow
            )
        }

        // 3. Fallback: harvest whole visible/AX text from the focused window.
        let harvested = collectTextFromAccessibilityTree(focusedWindow, maxCharacters: maxCharacters)
        guard !harvested.text.isEmpty || !(selectedText ?? "").isEmpty else {
            return nil
        }

        let fallbackReference: ActiveDocumentReference = .file(
            path: windowTitle ?? applicationName ?? "Active Window",
            title: windowTitle
        )
        return ActiveDocumentContext(
            kind: bundleIdentifier == "com.apple.finder" ? .finderSelection : .accessibilityWindow,
            reference: fallbackReference,
            extractedText: harvested.text,
            isTruncated: harvested.isTruncated,
            pageCount: nil,
            fileAccessWasDenied: false,
            selectedText: selectedText,
            applicationName: applicationName,
            applicationBundleIdentifier: bundleIdentifier,
            applicationProcessIdentifier: pid,
            windowTitle: windowTitle
        )
    }

    private nonisolated static func buildLocalFileContext(
        fileURL: URL,
        windowTitle: String?,
        selectedText: String?,
        applicationName: String?,
        bundleIdentifier: String?,
        pid: pid_t,
        maxCharacters: Int,
        fallbackWindow: AXUIElement
    ) -> ActiveDocumentContext {
        let fileOutcome = readLocalDocument(at: fileURL, maxCharacters: maxCharacters)
        let ext = fileURL.pathExtension.lowercased()
        let kind: ActiveDocumentKind
        if ext == "pdf" {
            kind = .pdf
        } else if ["rtf", "rtfd", "doc", "docx", "odt"].contains(ext) {
            kind = .officeOrRichDocument
        } else if bundleIdentifier == "com.apple.finder" {
            kind = .finderSelection
        } else {
            kind = .textFile
        }

        var extractedText = fileOutcome.text
        var isTruncated = fileOutcome.isTruncated

        if extractedText.isEmpty && !fileOutcome.accessDenied {
            let axFallback = collectTextFromAccessibilityTree(fallbackWindow, maxCharacters: maxCharacters)
            extractedText = axFallback.text
            isTruncated = axFallback.isTruncated
        }

        return ActiveDocumentContext(
            kind: kind,
            reference: .file(path: fileURL.path, title: windowTitle ?? fileURL.lastPathComponent),
            extractedText: extractedText,
            isTruncated: isTruncated,
            pageCount: fileOutcome.pageCount,
            fileAccessWasDenied: fileOutcome.accessDenied,
            selectedText: selectedText,
            applicationName: applicationName,
            applicationBundleIdentifier: bundleIdentifier,
            applicationProcessIdentifier: pid,
            windowTitle: windowTitle
        )
    }

    public nonisolated static func readLocalDocument(
        at url: URL,
        maxCharacters: Int = 80_000
    ) -> (text: String, pageCount: Int?, isTruncated: Bool, accessDenied: Bool) {
        let pathExtension = url.pathExtension.lowercased()

        // First probe readability so TCC permission denials are detected accurately.
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
        } catch {
            if isPermissionDeniedError(error, path: url.path) {
                return ("", nil, false, true)
            }
        }

        if pathExtension == "pdf" {
            guard let pdfDocument = PDFDocument(url: url) else {
                return ("", nil, false, false)
            }
            let totalPages = pdfDocument.pageCount
            var combined = ""
            var didTruncate = false

            for pageIndex in 0..<totalPages {
                guard let page = pdfDocument.page(at: pageIndex),
                      let pageString = page.string else {
                    continue
                }
                let trimmedPage = pageString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPage.isEmpty else { continue }

                let chunk = "[Page \(pageIndex + 1)]\n\(trimmedPage)\n\n"
                if combined.count + chunk.count > maxCharacters {
                    let remaining = max(0, maxCharacters - combined.count)
                    if remaining > 0 {
                        combined += String(chunk.prefix(remaining))
                    }
                    didTruncate = true
                    break
                }
                combined += chunk
            }
            return (combined.trimmingCharacters(in: .whitespacesAndNewlines), totalPages, didTruncate, false)
        }

        if ["rtf", "rtfd", "doc", "docx", "odt"].contains(pathExtension) {
            if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                let rawString = attributed.string
                if rawString.count > maxCharacters {
                    return (String(rawString.prefix(maxCharacters)), nil, true, false)
                }
                return (rawString, nil, false, false)
            }
        }

        // Plain text / source code / markdown / config files.
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let maxBytes = maxCharacters * 4
            let slice = data.count > maxBytes ? data.prefix(maxBytes) : data[...]
            let decoded = String(data: Data(slice), encoding: .utf8)
                ?? String(decoding: slice, as: UTF8.self)
            let truncated = (data.count > maxBytes) || (decoded.count > maxCharacters)
            let finalString = decoded.count > maxCharacters ? String(decoded.prefix(maxCharacters)) : decoded
            return (finalString, nil, truncated, false)
        } catch {
            if isPermissionDeniedError(error, path: url.path) {
                return ("", nil, false, true)
            }
            return ("", nil, false, false)
        }
    }

    public nonisolated static func isPermissionDeniedError(_ error: Error, path: String) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
            return true
        }
        let epermCode = Int(POSIXErrorCode.EPERM.rawValue)
        let eaccesCode = Int(POSIXErrorCode.EACCES.rawValue)
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == epermCode || nsError.code == eaccesCode) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain && (underlying.code == epermCode || underlying.code == eaccesCode) {
                return true
            }
        }
        return false
    }

    public nonisolated static func protectedFolderDisplayName(forPath path: String) -> String {
        if path.contains("/Desktop/") || path.hasSuffix("/Desktop") {
            return "Desktop"
        }
        if path.contains("/Documents/") || path.hasSuffix("/Documents") {
            return "Documents"
        }
        if path.contains("/Downloads/") || path.hasSuffix("/Downloads") {
            return "Downloads"
        }
        if path.contains("/Library/Mobile Documents/") {
            return "iCloud Drive"
        }
        return "Files & Folders"
    }

    private nonisolated static func resolveLocalFileURL(
        fromWindow window: AXUIElement,
        focusedElement: AXUIElement?
    ) -> URL? {
        let candidates: [AXUIElement] = [focusedElement, window].compactMap { item in item }
        for element in candidates {
            if let docPath = copyURLOrPathAttribute(element, attribute: kAXDocumentAttribute as String),
               FileManager.default.fileExists(atPath: docPath.path) || isProtectedUserFolderPath(docPath.path) {
                return docPath
            }
            if let urlAttribute = copyURLOrPathAttribute(element, attribute: kAXURLAttribute as String),
               urlAttribute.isFileURL {
                return urlAttribute
            }
        }
        return nil
    }

    private nonisolated static func isProtectedUserFolderPath(_ path: String) -> Bool {
        path.contains("/Desktop/")
            || path.contains("/Documents/")
            || path.contains("/Downloads/")
            || path.contains("/Library/Mobile Documents/")
    }

    private nonisolated static func collectTextFromAccessibilityTree(
        _ root: AXUIElement,
        maxCharacters: Int
    ) -> CollectedPageText {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var collectedChunks: [String] = []
        var totalLength = 0
        var seenChunks = Set<String>()
        var visitedNodes = 0
        let maxVisitedNodes = 800
        var isTruncated = false

        while !queue.isEmpty && visitedNodes < maxVisitedNodes {
            let current = queue.removeFirst()
            visitedNodes += 1

            let role = copyStringAttribute(current.element, attribute: kAXRoleAttribute as String) ?? ""
            if role == kAXStaticTextRole as String
                || role == "AXHeading"
                || role == kAXTextAreaRole as String {
                let text = copyStringAttribute(current.element, attribute: kAXValueAttribute as String)
                    ?? copyStringAttribute(current.element, attribute: kAXTitleAttribute as String)
                if let text {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !seenChunks.contains(trimmed) {
                        seenChunks.insert(trimmed)
                        if totalLength + trimmed.count + 1 > maxCharacters {
                            let remaining = max(0, maxCharacters - totalLength)
                            if remaining > 0 {
                                collectedChunks.append(String(trimmed.prefix(remaining)))
                            }
                            isTruncated = true
                            break
                        }
                        collectedChunks.append(trimmed)
                        totalLength += trimmed.count + 1
                    }
                }
            }

            if current.depth < 14,
               let children = copyElementArrayAttribute(current.element, attribute: kAXChildrenAttribute as String) {
                for child in children.prefix(80) {
                    queue.append((child, current.depth + 1))
                }
            }
        }

        return CollectedPageText(
            text: collectedChunks.joined(separator: "\n"),
            isTruncated: isTruncated
        )
    }

    // MARK: - AX Attribute Helpers

    fileprivate nonisolated static func copyElementAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> AXUIElement? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard status == .success, let rawValue else { return nil }
        guard CFGetTypeID(rawValue) == AXUIElementGetTypeID() else { return nil }
        return (rawValue as! AXUIElement)
    }

    fileprivate nonisolated static func copyElementArrayAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> [AXUIElement]? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard status == .success, let array = rawValue as? [AXUIElement] else { return nil }
        return array
    }

    fileprivate nonisolated static func copyStringAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard status == .success, let rawValue else { return nil }
        if let stringValue = rawValue as? String {
            return stringValue
        }
        if let urlValue = rawValue as? URL {
            return urlValue.absoluteString
        }
        return nil
    }

    fileprivate nonisolated static func copyURLStringAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard status == .success, let rawValue else { return nil }
        if let urlValue = rawValue as? URL {
            return urlValue.absoluteString
        }
        if let stringValue = rawValue as? String {
            return stringValue
        }
        return nil
    }

    private nonisolated static func copyURLOrPathAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> URL? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard status == .success, let rawValue else { return nil }
        if let urlValue = rawValue as? URL {
            return urlValue.isFileURL ? urlValue : nil
        }
        if let stringValue = rawValue as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("file://"), let parsed = URL(string: trimmed) {
                return parsed
            }
            if trimmed.hasPrefix("/") {
                return URL(fileURLWithPath: trimmed)
            }
        }
        return nil
    }
}
