//
//  ClickyHandoffChip.swift
//  leanring-buddy
//
//  Picks the "ready to open" verb for a finished job's artifact from its file type or URL.
//

import Foundation

public nonisolated enum ClickyHandoffChipKind: Equatable, Sendable {
    case page, doc, sheet, slides, pdf, image, video, audio, folder, file

    public static func kind(forPath path: String, isLink: Bool) -> ClickyHandoffChipKind {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedPath = trimmedPath.lowercased()
        if isLink || lowercasedPath.hasPrefix("http://") || lowercasedPath.hasPrefix("https://") {
            return .page
        }
        if trimmedPath.hasSuffix("/") {
            return .folder
        }
        switch URL(fileURLWithPath: trimmedPath).pathExtension.lowercased() {
        case "html", "htm", "webloc", "url": return .page
        case "md", "markdown", "txt", "rtf", "doc", "docx", "pages": return .doc
        case "csv", "tsv", "xls", "xlsx", "numbers": return .sheet
        case "ppt", "pptx", "key": return .slides
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": return .image
        case "mp4", "mov", "m4v", "webm": return .video
        case "mp3", "m4a", "wav", "aac", "flac": return .audio
        default: return .file
        }
    }

    /// Button label for the chip.
    public var openVerb: String {
        switch self {
        case .page: return String(localized: "Open page")
        case .doc: return String(localized: "Open doc")
        case .sheet: return String(localized: "Open sheet")
        case .slides: return String(localized: "Open slides")
        case .pdf: return String(localized: "Open PDF")
        case .image: return String(localized: "Open image")
        case .video: return String(localized: "Play video")
        case .audio: return String(localized: "Play audio")
        case .folder: return String(localized: "Open folder")
        case .file: return String(localized: "Open")
        }
    }

    /// Sentence for a card whose single deliverable is of this kind.
    public var readySentence: String {
        switch self {
        case .page: return String(localized: "Your page is ready to open.")
        case .doc: return String(localized: "Your doc is ready to open.")
        case .sheet: return String(localized: "Your sheet is ready to open.")
        case .slides: return String(localized: "Your slides are ready to open.")
        case .pdf: return String(localized: "Your PDF is ready to open.")
        case .image: return String(localized: "Your image is ready to open.")
        case .video: return String(localized: "Your video is ready to open.")
        case .audio: return String(localized: "Your audio is ready to open.")
        case .folder: return String(localized: "Your folder is ready to open.")
        case .file: return String(localized: "Your file is ready to open.")
        }
    }

    /// Sentence for a finished card: one deliverable, several, or none.
    public static func readySentence(forArtifacts artifacts: [ClickyJobArtifactEntry]) -> String {
        switch artifacts.count {
        case 0:
            return String(localized: "It finished. Open it to see what it did.")
        case 1:
            return kind(forPath: artifacts[0].path, isLink: artifacts[0].isLink).readySentence
        default:
            return String(localized: "\(artifacts.count) files are ready")
        }
    }
}
