//
//  HeyClickyDocumentColumn.swift
//  leanring-buddy
//

import AppKit
import Combine
import Foundation
import PDFKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document Mode & Classification

private enum HeyClickyDocumentKind {
    case markdown
    case codeOrPlainText
    case pdf
    case image
    case spreadsheet(delimiter: Character)
    case webPage
    case quickLookFallback

    static func classify(url: URL?, activeContext: ActiveDocumentContext?) -> HeyClickyDocumentKind {
        if let url {
            if !url.isFileURL {
                return .webPage
            }
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "md", "markdown", "mdx":
                return .markdown
            case "pdf":
                return .pdf
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "icns":
                return .image
            case "csv":
                return .spreadsheet(delimiter: ",")
            case "tsv":
                return .spreadsheet(delimiter: "\t")
            case "txt", "log", "json", "jsonl", "yaml", "yml", "xml", "html", "htm", "css", "scss",
                 "js", "mjs", "cjs", "ts", "tsx", "jsx", "swift", "py", "rs", "go", "sh", "zsh",
                 "bash", "rb", "sql", "toml", "ini", "cfg", "conf", "env", "c", "h", "cpp", "hpp",
                 "m", "mm", "java", "kt", "kts", "plist", "pbxproj", "diff", "patch":
                return .codeOrPlainText
            default:
                if let utType = UTType(filenameExtension: ext) {
                    if utType.conforms(to: .pdf) { return .pdf }
                    if utType.conforms(to: .image) { return .image }
                    if utType.conforms(to: .commaSeparatedText) { return .spreadsheet(delimiter: ",") }
                    if utType.conforms(to: .tabSeparatedText) { return .spreadsheet(delimiter: "\t") }
                    if utType.conforms(to: .plainText) || utType.conforms(to: .sourceCode) {
                        return .codeOrPlainText
                    }
                }
                return .quickLookFallback
            }
        }

        if let activeContext {
            switch activeContext.kind {
            case .webPage:
                return .webPage
            case .pdf:
                return .pdf
            case .textFile, .officeOrRichDocument, .finderSelection, .accessibilityWindow, .unknown:
                return .codeOrPlainText
            }
        }

        return .codeOrPlainText
    }
}

private enum MarkdownDisplayMode: String, CaseIterable, Identifiable {
    case ink = "Ink"
    case source = "Source"

    var id: String { rawValue }
}

// MARK: - HeyClickyDocumentColumn

struct HeyClickyDocumentColumn: View {
    let documentURL: URL?
    let activeDocumentContext: ActiveDocumentContext?
    let onClose: () -> Void
    var onInkAction: ((String) -> Void)? = nil

    @State private var markdownMode: MarkdownDisplayMode = .ink
    @State private var imageZoomScale: CGFloat = 1.0
    @State private var isImageFitToWidth: Bool = true
    @State private var loadedTextContent: String = ""
    @State private var loadedTextError: String? = nil
    @State private var loadedImage: NSImage? = nil
    @State private var loadedSpreadsheet: SpreadsheetTableData? = nil
    @State private var fileByteCount: Int64? = nil

    private var documentKind: HeyClickyDocumentKind {
        HeyClickyDocumentKind.classify(url: documentURL, activeContext: activeDocumentContext)
    }

    private var displayTitle: String {
        if let documentURL {
            if documentURL.isFileURL {
                return documentURL.lastPathComponent
            }
            return documentURL.host ?? documentURL.absoluteString
        }
        return activeDocumentContext?.reference.displayTitle ?? "Document"
    }

    private var subtitleText: String {
        if let documentURL {
            if documentURL.isFileURL {
                if let fileByteCount {
                    let formattedSize = ByteCountFormatter.string(fromByteCount: fileByteCount, countStyle: .file)
                    return "\(documentURL.deletingLastPathComponent().lastPathComponent) · \(formattedSize)"
                }
                return documentURL.path
            }
            return documentURL.absoluteString
        }
        if let activeDocumentContext {
            return activeDocumentContext.applicationName ?? activeDocumentContext.reference.rawLocation
        }
        return ""
    }

    private var headerIconName: String {
        switch documentKind {
        case .markdown:
            return "doc.richtext"
        case .codeOrPlainText:
            return "doc.plaintext"
        case .pdf:
            return "doc.text.fill"
        case .image:
            return "photo"
        case .spreadsheet:
            return "tablecells"
        case .webPage:
            return "globe"
        case .quickLookFallback:
            return "doc.viewfinder"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            documentHeader

            Divider()
                .background(DS.Colors.borderSubtle)

            documentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.surface1.opacity(0.60))
        .onAppear {
            reloadContent()
        }
        .onChange(of: documentURL) { _, _ in
            reloadContent()
        }
        .onChange(of: activeDocumentContext) { _, _ in
            if documentURL == nil {
                reloadContent()
            }
        }
    }

    // MARK: - Header

    private var documentHeader: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: headerIconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.accentSubtle)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if case .markdown = documentKind {
                markdownModePicker
            }

            if case .image = documentKind {
                imageZoomControls
            }

            if let documentURL {
                if documentURL.isFileURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .dsIconButtonStyle(size: 26, tooltip: "Reveal in Finder", tooltipAlignment: .trailing)

                    Button {
                        NSWorkspace.shared.open(documentURL)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .dsIconButtonStyle(size: 26, tooltip: "Open in Default App", tooltipAlignment: .trailing)
                } else {
                    Button {
                        NSWorkspace.shared.open(documentURL)
                    } label: {
                        Image(systemName: "safari")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .dsIconButtonStyle(size: 26, tooltip: "Open in Browser", tooltipAlignment: .trailing)
                }
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .dsIconButtonStyle(size: 26, tooltip: "Close Document", tooltipAlignment: .trailing)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1.opacity(0.85))
    }

    private var markdownModePicker: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownDisplayMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: DS.Animation.fast)) {
                        markdownMode = mode
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(markdownMode == mode ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(markdownMode == mode ? DS.Colors.surface3 : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        )
    }

    private var imageZoomControls: some View {
        HStack(spacing: 4) {
            Button {
                isImageFitToWidth.toggle()
                if !isImageFitToWidth && imageZoomScale == 1.0 {
                    imageZoomScale = 1.0
                }
            } label: {
                Text(isImageFitToWidth ? "Fit" : "\(Int(imageZoomScale * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if !isImageFitToWidth {
                Button {
                    imageZoomScale = max(0.25, imageZoomScale - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11))
                }
                .dsIconButtonStyle(size: 24, tooltip: "Zoom Out", tooltipAlignment: .center)

                Button {
                    imageZoomScale = min(4.0, imageZoomScale + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                }
                .dsIconButtonStyle(size: 24, tooltip: "Zoom In", tooltipAlignment: .center)
            }
        }
    }

    // MARK: - Body Dispatcher

    @ViewBuilder
    private var documentBody: some View {
        switch documentKind {
        case .markdown:
            if let loadedTextError {
                documentErrorView(message: loadedTextError)
            } else if markdownMode == .ink {
                ScrollView {
                    ClickyInkSheetView(
                        markdown: loadedTextContent,
                        title: displayTitle,
                        onAction: onInkAction
                    )
                    .padding(DS.Spacing.md)
                }
            } else {
                SelectableDocumentTextView(
                    text: loadedTextContent,
                    isMonospaced: true
                )
            }

        case .codeOrPlainText:
            if let loadedTextError {
                documentErrorView(message: loadedTextError)
            } else {
                SelectableDocumentTextView(
                    text: loadedTextContent,
                    isMonospaced: isMonospacedExtension(documentURL?.pathExtension)
                )
            }

        case .pdf:
            if let documentURL, documentURL.isFileURL {
                PDFKitDocumentView(url: documentURL)
            } else if !loadedTextContent.isEmpty {
                SelectableDocumentTextView(text: loadedTextContent, isMonospaced: false)
            } else {
                documentErrorView(message: "Unable to load PDF preview.")
            }

        case .image:
            if let loadedImage {
                imagePreviewView(image: loadedImage)
            } else {
                documentErrorView(message: loadedTextError ?? "Unable to load image.")
            }

        case .spreadsheet:
            if let loadedSpreadsheet {
                SpreadsheetGridView(
                    table: loadedSpreadsheet,
                    fileURL: documentURL
                )
            } else {
                documentErrorView(message: loadedTextError ?? "Unable to parse spreadsheet.")
            }

        case .webPage:
            webPageContextView

        case .quickLookFallback:
            if let documentURL, documentURL.isFileURL {
                quickLookAndFinderFallbackView(fileURL: documentURL)
            } else {
                documentErrorView(message: "No document selected.")
            }
        }
    }

    // MARK: - Subviews

    private func imagePreviewView(image: NSImage) -> some View {
        VStack(spacing: 0) {
            if isImageFitToWidth {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: max(geometry.size.width - 24, 100),
                                maxHeight: max(geometry.size.height - 24, 100)
                            )
                            .padding(12)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(
                            width: max(image.size.width * imageZoomScale, 16),
                            height: max(image.size.height * imageZoomScale, 16)
                        )
                        .padding(16)
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            HStack {
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) px")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                if let documentURL {
                    Text(documentURL.pathExtension.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.surface2))
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 6)
            .background(DS.Colors.surface1.opacity(0.8))
        }
    }

    private var webPageContextView: some View {
        VStack(spacing: 0) {
            if let documentURL {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(documentURL.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, 8)
                .background(DS.Colors.surface2.opacity(0.6))

                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            if !loadedTextContent.isEmpty {
                SelectableDocumentTextView(text: loadedTextContent, isMonospaced: false)
            } else {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "safari")
                        .font(.system(size: 28))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("Web page captured without extracted text.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    if let documentURL {
                        Button("Open in Browser") {
                            NSWorkspace.shared.open(documentURL)
                        }
                        .dsSecondaryButtonStyle(isFullWidth: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DS.Spacing.xl)
            }
        }
    }

    private func quickLookAndFinderFallbackView(fileURL: URL) -> some View {
        VStack(spacing: 0) {
            InlineQuickLookView(url: fileURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(DS.Colors.borderSubtle)

            HStack(spacing: DS.Spacing.sm) {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(DS.Colors.surface2)
                        )
                        .overlay(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Label("Open App", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 8)
            .background(DS.Colors.surface1.opacity(0.85))
        }
    }

    private func documentErrorView(message: String) -> some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 28))
                .foregroundColor(DS.Colors.textTertiary)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.lg)

            if let documentURL, documentURL.isFileURL {
                HStack(spacing: DS.Spacing.sm) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
                    } label: {
                        Text("Reveal in Finder")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(DS.Colors.surface2))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button {
                        NSWorkspace.shared.open(documentURL)
                    } label: {
                        Text("Open Externally")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content Loading

    private func reloadContent() {
        loadedTextError = nil
        loadedTextContent = ""
        loadedImage = nil
        loadedSpreadsheet = nil
        fileByteCount = nil

        guard let documentURL else {
            if let activeDocumentContext {
                loadedTextContent = activeDocumentContext.extractedText
            }
            return
        }

        guard documentURL.isFileURL else {
            if let activeDocumentContext,
               activeDocumentContext.reference.rawLocation == documentURL.absoluteString {
                loadedTextContent = activeDocumentContext.extractedText
            }
            return
        }

        let filePath = documentURL.path
        guard FileManager.default.fileExists(atPath: filePath) else {
            loadedTextError = "File no longer exists at \(documentURL.lastPathComponent)."
            return
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
           let sizeNumber = attributes[.size] as? NSNumber {
            fileByteCount = sizeNumber.int64Value
        }

        switch documentKind {
        case .markdown, .codeOrPlainText:
            do {
                loadedTextContent = try Self.readTextFile(at: documentURL)
            } catch {
                loadedTextError = "Could not read \(documentURL.lastPathComponent): \(error.localizedDescription)"
            }

        case .image:
            if let image = NSImage(contentsOf: documentURL) {
                loadedImage = image
            } else {
                loadedTextError = "Could not decode image \(documentURL.lastPathComponent)."
            }

        case .spreadsheet(let delimiter):
            do {
                let rawText = try Self.readTextFile(at: documentURL)
                loadedSpreadsheet = SpreadsheetTableData.parse(rawText, delimiter: delimiter)
            } catch {
                loadedTextError = "Could not parse \(documentURL.lastPathComponent): \(error.localizedDescription)"
            }

        case .pdf, .webPage, .quickLookFallback:
            break
        }
    }

    private nonisolated static func readTextFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func isMonospacedExtension(_ pathExtension: String?) -> Bool {
        guard let ext = pathExtension?.lowercased(), !ext.isEmpty else { return false }
        let proseExtensions: Set<String> = ["txt", "rtf", "md", "markdown"]
        return !proseExtensions.contains(ext)
    }
}

// MARK: - Selectable Text Viewer (NSTextView)

private struct SelectableDocumentTextView: NSViewRepresentable {
    let text: String
    let isMonospaced: Bool

    final class Coordinator {
        var lastRenderedText: String = ""
        var lastIsMonospaced: Bool?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        applyContent(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        applyContent(to: textView, coordinator: context.coordinator)
    }

    private func applyContent(to textView: NSTextView, coordinator: Coordinator) {
        if coordinator.lastRenderedText == text && coordinator.lastIsMonospaced == isMonospaced {
            return
        }
        coordinator.lastRenderedText = text
        coordinator.lastIsMonospaced = isMonospaced

        let font: NSFont = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13, weight: .regular)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = isMonospaced ? 2.5 : 4.0

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}

// MARK: - PDFKit Viewer (NSViewRepresentable)

private struct PDFKitDocumentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .clear
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Inline QuickLook Viewer (NSViewRepresentable)

private struct InlineQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let previewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        previewView.autostarts = true
        previewView.previewItem = url as NSURL
        return previewView
    }

    func updateNSView(_ previewView: QLPreviewView, context: Context) {
        let currentURL = (previewView.previewItem as? NSURL) as URL?
        if currentURL != url {
            previewView.previewItem = url as NSURL
        }
    }
}

// MARK: - Native SpreadsheetGridView for CSV / TSV

nonisolated struct SpreadsheetTableData: Equatable, Sendable {
    let headers: [String]
    let rows: [[String]]
    let columnWidths: [CGFloat]
    let delimiter: Character
    let wasTruncated: Bool
    let totalRowCount: Int

    static func parse(_ rawText: String, delimiter: Character, maxRows: Int = 2000) -> SpreadsheetTableData {
        var parsedRows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var isInsideQuotes = false

        let characters = Array(rawText)
        var index = 0
        while index < characters.count {
            let character = characters[index]

            if isInsideQuotes {
                if character == "\"" {
                    let nextIndex = index + 1
                    if nextIndex < characters.count && characters[nextIndex] == "\"" {
                        currentField.append("\"")
                        index += 2
                        continue
                    } else {
                        isInsideQuotes = false
                    }
                } else {
                    currentField.append(character)
                }
            } else {
                if character == "\"" && currentField.isEmpty {
                    isInsideQuotes = true
                } else if character == delimiter {
                    currentRow.append(currentField)
                    currentField = ""
                } else if character == "\r" {
                    let nextIndex = index + 1
                    if nextIndex < characters.count && characters[nextIndex] == "\n" {
                        index += 1
                    }
                    currentRow.append(currentField)
                    parsedRows.append(currentRow)
                    currentRow = []
                    currentField = ""
                } else if character == "\n" {
                    currentRow.append(currentField)
                    parsedRows.append(currentRow)
                    currentRow = []
                    currentField = ""
                } else {
                    currentField.append(character)
                }
            }
            index += 1
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            parsedRows.append(currentRow)
        }

        // Remove trailing empty line common in CSV exports
        while let lastRow = parsedRows.last, lastRow.count == 1, lastRow[0].isEmpty {
            parsedRows.removeLast()
        }

        guard let rawHeader = parsedRows.first else {
            return SpreadsheetTableData(
                headers: [],
                rows: [],
                columnWidths: [],
                delimiter: delimiter,
                wasTruncated: false,
                totalRowCount: 0
            )
        }

        let bodySlice = Array(parsedRows.dropFirst())
        let totalRowCount = bodySlice.count
        let wasTruncated = totalRowCount > maxRows
        let boundedBody = wasTruncated ? Array(bodySlice.prefix(maxRows)) : bodySlice

        let maxColumnCount = max(
            rawHeader.count,
            boundedBody.reduce(0) { partialMax, row in max(partialMax, row.count) }
        )

        var normalizedHeaders = rawHeader
        while normalizedHeaders.count < maxColumnCount {
            normalizedHeaders.append("Column \(normalizedHeaders.count + 1)")
        }

        let normalizedRows = boundedBody.map { row -> [String] in
            if row.count == maxColumnCount { return row }
            if row.count > maxColumnCount { return Array(row.prefix(maxColumnCount)) }
            return row + Array(repeating: "", count: maxColumnCount - row.count)
        }

        var computedWidths = normalizedHeaders.map { header -> CGFloat in
            CGFloat(min(max(header.count * 8 + 28, 90), 220))
        }
        for row in normalizedRows.prefix(50) {
            for (columnIndex, cell) in row.enumerated() where columnIndex < computedWidths.count {
                let candidateWidth = CGFloat(min(max(cell.count * 7 + 24, 90), 240))
                computedWidths[columnIndex] = max(computedWidths[columnIndex], candidateWidth)
            }
        }

        return SpreadsheetTableData(
            headers: normalizedHeaders,
            rows: normalizedRows,
            columnWidths: computedWidths,
            delimiter: delimiter,
            wasTruncated: wasTruncated,
            totalRowCount: totalRowCount
        )
    }
}

struct SpreadsheetGridView: View {
    let table: SpreadsheetTableData
    let fileURL: URL?

    @State private var filterText: String = ""

    private var filteredRows: [(originalIndex: Int, values: [String])] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let indexed = table.rows.enumerated().map { offset, values in
            (originalIndex: offset + 1, values: values)
        }
        guard !query.isEmpty else { return indexed }
        return indexed.filter { entry in
            entry.values.contains { cell in
                cell.lowercased().contains(query)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search filter bar
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)

                TextField("Filter rows...", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)

                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 7)
            .background(DS.Colors.surface2.opacity(0.6))

            Divider()
                .background(DS.Colors.borderSubtle)

            if table.headers.isEmpty {
                VStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 24))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("Empty spreadsheet")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(filteredRows, id: \.originalIndex) { rowEntry in
                                spreadsheetDataRow(
                                    rowNumber: rowEntry.originalIndex,
                                    values: rowEntry.values,
                                    isAlternateRow: rowEntry.originalIndex % 2 == 0
                                )
                            }
                        } header: {
                            spreadsheetHeaderRow
                        }
                    }
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            HStack(spacing: DS.Spacing.sm) {
                Text("\(filteredRows.count) rows × \(table.headers.count) cols")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)

                if table.wasTruncated {
                    Text("(showing first \(table.rows.count) of \(table.totalRowCount))")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                }

                Spacer()

                Text(table.delimiter == "\t" ? "TSV" : "CSV")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.surface2))

                if let fileURL {
                    Button {
                        NSWorkspace.shared.open(fileURL)
                    } label: {
                        Text("Open App")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 6)
            .background(DS.Colors.surface1.opacity(0.85))
        }
    }

    private var spreadsheetHeaderRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(DS.Colors.surface2)

            ForEach(Array(table.headers.enumerated()), id: \.offset) { columnIndex, header in
                let columnWidth = columnIndex < table.columnWidths.count ? table.columnWidths[columnIndex] : 120
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .frame(width: columnWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .overlay(
                        Rectangle()
                            .fill(DS.Colors.borderSubtle.opacity(0.6))
                            .frame(width: 1),
                        alignment: .leading
                    )
            }
        }
        .background(DS.Colors.surface2)
        .overlay(
            Rectangle()
                .fill(DS.Colors.borderStrong)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func spreadsheetDataRow(rowNumber: Int, values: [String], isAlternateRow: Bool) -> some View {
        HStack(spacing: 0) {
            Text("\(rowNumber)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            ForEach(Array(values.enumerated()), id: \.offset) { columnIndex, cellValue in
                let columnWidth = columnIndex < table.columnWidths.count ? table.columnWidths[columnIndex] : 120
                Text(cellValue)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(width: columnWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(
                        Rectangle()
                            .fill(DS.Colors.borderSubtle.opacity(0.35))
                            .frame(width: 1),
                        alignment: .leading
                    )
            }
        }
        .background(isAlternateRow ? DS.Colors.surface2.opacity(0.35) : Color.clear)
        .overlay(
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.3))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
