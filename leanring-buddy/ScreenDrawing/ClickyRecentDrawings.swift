//
//  ClickyRecentDrawings.swift
//  leanring-buddy
//
//  Library of finished drawings (Home → Drawings). Each record keeps the full JS
//  drawing program so it can be replayed from the chat or from Home. Stored as JSON
//  in Application Support, newest first, capped so the file stays small.
//

import AppKit
import Foundation
import Combine

nonisolated struct ClickyRecentDrawing: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let code: String
    let createdAt: Date
}

@MainActor
final class ClickyRecentDrawings: ObservableObject {
    static let shared = ClickyRecentDrawings()

    nonisolated static let maximumStoredDrawingCount = 30

    @Published private(set) var entries: [ClickyRecentDrawing] = []

    private let storageFileURL: URL

    init(storageFileURL: URL = ClickyRecentDrawings.defaultStorageFileURL()) {
        self.storageFileURL = storageFileURL
        entries = Self.loadEntries(from: storageFileURL)
    }

    // MARK: - Pure helpers (unit tested)

    /// Puts `newDrawing` first and drops the oldest entries beyond `maximumCount`.
    nonisolated static func insertingNewest(
        _ newDrawing: ClickyRecentDrawing,
        into existingEntries: [ClickyRecentDrawing],
        maximumCount: Int = maximumStoredDrawingCount
    ) -> [ClickyRecentDrawing] {
        let entriesWithoutDuplicate = existingEntries.filter { $0.id != newDrawing.id }
        return Array(([newDrawing] + entriesWithoutDuplicate).prefix(maximumCount))
    }

    // MARK: - API

    /// Stores a finished drawing and returns its record, or nil when the program is empty.
    @discardableResult
    func record(title: String, code: String, createdAt: Date = Date()) -> ClickyRecentDrawing? {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newDrawing = ClickyRecentDrawing(
            id: UUID(),
            title: trimmedTitle.isEmpty ? String(localized: "Drawing") : trimmedTitle,
            code: trimmedCode,
            createdAt: createdAt
        )
        entries = Self.insertingNewest(newDrawing, into: entries)
        persist()
        return newDrawing
    }

    func drawing(id: UUID) -> ClickyRecentDrawing? {
        entries.first { $0.id == id }
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    nonisolated static func defaultStorageFileURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return applicationSupportURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("recent-drawings.json")
    }

    nonisolated private static func loadEntries(from fileURL: URL) -> [ClickyRecentDrawing] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([ClickyRecentDrawing].self, from: data)
        } catch {
            print("⚠️ ClickyRecentDrawings: could not decode \(fileURL.lastPathComponent): \(error)")
            return []
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageFileURL, options: .atomic)
        } catch {
            print("⚠️ ClickyRecentDrawings: could not save: \(error)")
        }
    }
}

// MARK: - Playback

enum ClickyDrawingPlaybackMode: String, CaseIterable, Sendable {
    /// Over the user's screen, like the original answer.
    case fullScreen
    /// Inside its own movable window.
    case window
    /// Over the screen on an opaque white board.
    case whiteboard
}

@MainActor
enum ClickyDrawingPlayer {
    /// Replays a stored drawing in the chosen mode.
    static func play(drawingID: UUID, mode: ClickyDrawingPlaybackMode) {
        guard let storedDrawing = ClickyRecentDrawings.shared.drawing(id: drawingID) else { return }
        switch mode {
        case .fullScreen:
            ScreenAnnotationManager.shared.clearAll()
            ScreenAnnotationManager.shared.executeDrawingProgram(storedDrawing.code)
        case .whiteboard:
            ScreenAnnotationManager.shared.clearAll()
            ScreenAnnotationManager.shared.executeDrawingProgram(storedDrawing.code)
            ScreenAnnotationManager.shared.showWhiteboardBehindDrawing()
        case .window:
            ClickyDrawingWindowViewer.open(title: storedDrawing.title, code: storedDrawing.code)
        }
    }
}
