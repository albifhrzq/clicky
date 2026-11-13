//
//  ClickyAppStore.swift
//  leanring-buddy
//

import Combine
import Foundation

public nonisolated struct ClickyAppWorkEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let clickySlug: String
    public var threadID: String?
    public var title: String
    public var ask: String
    public var summary: String
    public var reply: String
    public var artifactPaths: [String]
    public var folderPath: String?
    public let createdAt: Date
    public var finishedAt: Date?
    public var failed: Bool
    public var isRoutineRun: Bool

    public init(
        id: String = UUID().uuidString,
        clickySlug: String,
        threadID: String? = nil,
        title: String,
        ask: String,
        summary: String = "",
        reply: String = "",
        artifactPaths: [String] = [],
        folderPath: String? = nil,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        failed: Bool = false,
        isRoutineRun: Bool = false
    ) {
        self.id = id
        self.clickySlug = clickySlug
        self.threadID = threadID
        self.title = title
        self.ask = ask
        self.summary = summary
        self.reply = reply
        self.artifactPaths = artifactPaths
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.failed = failed
        self.isRoutineRun = isRoutineRun
    }
}

private nonisolated struct ClickyAppWorksArchive: Codable, Equatable, Sendable {
    var version: Int
    var updatedAt: Date
    var worksBySlug: [String: [ClickyAppWorkEntry]]

    init(version: Int = 1, updatedAt: Date = Date(), worksBySlug: [String: [ClickyAppWorkEntry]] = [:]) {
        self.version = version
        self.updatedAt = updatedAt
        self.worksBySlug = worksBySlug
    }
}

@MainActor
public final class ClickyAppStore: ObservableObject {
    public static let shared = ClickyAppStore()

    @Published private(set) var worksBySlug: [String: [ClickyAppWorkEntry]] = [:]
    public private(set) var loadedSlugs: Set<String> = []

    private let fileManager: FileManager
    private let baseDirectoryURL: URL

    public var worksFileURL: URL {
        baseDirectoryURL.appendingPathComponent("works.json", isDirectory: false)
    }

    public init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.baseDirectoryURL = applicationSupport.appendingPathComponent("ClickyApps", isDirectory: true)
        }
        loadAll()
    }

    public func loadAll() {
        let targetURL = worksFileURL
        guard fileManager.fileExists(atPath: targetURL.path),
              let data = try? Data(contentsOf: targetURL) else {
            worksBySlug = [:]
            loadedSlugs = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let archive = try? decoder.decode(ClickyAppWorksArchive.self, from: data) {
            worksBySlug = archive.worksBySlug
            loadedSlugs = Set(archive.worksBySlug.keys)
            return
        }

        if let flatEntries = try? decoder.decode([ClickyAppWorkEntry].self, from: data) {
            var grouped: [String: [ClickyAppWorkEntry]] = [:]
            for entry in flatEntries {
                grouped[entry.clickySlug, default: []].append(entry)
            }
            worksBySlug = grouped
            loadedSlugs = Set(grouped.keys)
            return
        }

        worksBySlug = [:]
        loadedSlugs = []
    }

    public func works(forSlug slug: String) -> [ClickyAppWorkEntry] {
        worksBySlug[slug] ?? []
    }

    public func latestWork(forSlug slug: String) -> ClickyAppWorkEntry? {
        works(forSlug: slug).first
    }

    public var allWorksNewestFirst: [ClickyAppWorkEntry] {
        worksBySlug.values
            .flatMap { entries in entries }
            .sorted { left, right in
                let leftDate = left.finishedAt ?? left.createdAt
                let rightDate = right.finishedAt ?? right.createdAt
                return leftDate > rightDate
            }
    }

    public func recordWork(_ entry: ClickyAppWorkEntry) {
        var list = worksBySlug[entry.clickySlug] ?? []
        list.removeAll { existing in existing.id == entry.id }
        list.append(entry)
        list.sort { left, right in
            let leftDate = left.finishedAt ?? left.createdAt
            let rightDate = right.finishedAt ?? right.createdAt
            return leftDate > rightDate
        }
        worksBySlug[entry.clickySlug] = list
        loadedSlugs.insert(entry.clickySlug)
        persistToDisk()
    }

    public func updateWork(
        id: String,
        clickySlug: String,
        mutate: (inout ClickyAppWorkEntry) -> Void
    ) {
        var list = worksBySlug[clickySlug] ?? []
        guard let index = list.firstIndex(where: { item in item.id == id }) else { return }
        var updated = list[index]
        mutate(&updated)
        list[index] = updated
        list.sort { left, right in
            let leftDate = left.finishedAt ?? left.createdAt
            let rightDate = right.finishedAt ?? right.createdAt
            return leftDate > rightDate
        }
        worksBySlug[clickySlug] = list
        loadedSlugs.insert(clickySlug)
        persistToDisk()
    }

    public func removeWorks(forSlug slug: String) {
        worksBySlug.removeValue(forKey: slug)
        loadedSlugs.remove(slug)
        persistToDisk()
    }

    private func persistToDisk() {
        let targetURL = worksFileURL
        let archive = ClickyAppWorksArchive(
            version: 1,
            updatedAt: Date(),
            worksBySlug: worksBySlug
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(archive) else { return }
        do {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: targetURL, options: .atomic)
        } catch {
            print("⚠️ [ClickyAppStore] Failed to write works.json: \(error)")
        }
    }
}
