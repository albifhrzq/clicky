//
//  ClickyLiveNoteWatcher.swift
//  leanring-buddy
//
//  The agent runner writes note.md directly, so nothing in the app knows when it changes.
//  This polls the modification dates of every workspace note.md once a second while at
//  least one view is observing, and bumps `revision` so views that read the note re-render.
//

import Combine
import Foundation

@MainActor
public final class ClickyLiveNoteWatcher: ObservableObject {
    public static let shared = ClickyLiveNoteWatcher()

    /// Increases whenever any workspace note.md was created, changed or removed.
    @Published public private(set) var revision: Int = 0

    private let pollIntervalSeconds: TimeInterval = 1.0
    private var observerCount = 0
    private var pollTimer: Timer?
    private var lastModificationDatesByPath: [String: Date] = [:]

    private init() {}

    /// Call from `onAppear`; pair with `endObserving()` in `onDisappear`.
    public func beginObserving() {
        observerCount += 1
        guard pollTimer == nil else { return }
        lastModificationDatesByPath = currentModificationDates()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollForChanges()
            }
        }
    }

    public func endObserving() {
        observerCount = max(0, observerCount - 1)
        if observerCount == 0 {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func pollForChanges() {
        let latestModificationDates = currentModificationDates()
        if latestModificationDates != lastModificationDatesByPath {
            lastModificationDatesByPath = latestModificationDates
            revision += 1
        }
    }

    private func currentModificationDates() -> [String: Date] {
        let workspacesRootURL = ClickyWorkFolderFiles.shared.rootDirectoryURL
        let fileManager = FileManager.default
        guard let workspaceURLs = try? fileManager.contentsOfDirectory(
            at: workspacesRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var modificationDatesByPath: [String: Date] = [:]
        for workspaceURL in workspaceURLs {
            let noteURL = workspaceURL.appendingPathComponent("note.md", isDirectory: false)
            if let attributes = try? fileManager.attributesOfItem(atPath: noteURL.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                modificationDatesByPath[noteURL.path] = modificationDate
            }
        }
        return modificationDatesByPath
    }
}
