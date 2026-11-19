//
//  ClickyWorkFolderFiles.swift
//  leanring-buddy
//

import Foundation

@MainActor
public final class ClickyWorkFolderFiles {
    public static let shared = ClickyWorkFolderFiles()

    public static let runsBlockStartMarker = "<!-- clicky:runs -->"
    public static let runsBlockEndMarker = "<!-- /clicky:runs -->"

    private let fileManager: FileManager
    private let workspacesRootURL: URL
    private let writeQueue = DispatchQueue(
        label: "com.humansongs.clicky.work-folder-files",
        qos: .utility
    )

    private var lastWrittenRunsBlockByJobID: [String: String] = [:]
    private var lastIndexLinesByPath: [String: String] = [:]
    private var reportedTurnKeys: Set<String> = []
    private var isBackfillingReports = false
    private let ownerStamp = "clicky-work-owner:"

    public var rootDirectoryURL: URL {
        workspacesRootURL
    }

    public init(
        workspacesRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let workspacesRootURL {
            self.workspacesRootURL = workspacesRootURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.workspacesRootURL = applicationSupport
                .appendingPathComponent("Clicky", isDirectory: true)
                .appendingPathComponent("Workspaces", isDirectory: true)
        }
    }

    public func workspaceURL(forSlug slug: String) -> URL {
        workspacesRootURL.appendingPathComponent(slug, isDirectory: true)
    }

    public func agentsMarkdownURL(forSlug slug: String) -> URL {
        workspaceURL(forSlug: slug).appendingPathComponent("AGENTS.md", isDirectory: false)
    }

    public func noteMarkdownURL(forSlug slug: String) -> URL {
        workspaceURL(forSlug: slug).appendingPathComponent("note.md", isDirectory: false)
    }

    public func previousNoteMarkdownURL(forSlug slug: String) -> URL {
        workspaceURL(forSlug: slug)
            .appendingPathComponent(".clicky", isDirectory: true)
            .appendingPathComponent("previous-note.md", isDirectory: false)
    }

    public func longWorkMemoryURL(forSlug slug: String) -> URL {
        workspaceURL(forSlug: slug)
            .appendingPathComponent(".clicky", isDirectory: true)
            .appendingPathComponent("memory.md", isDirectory: false)
    }

    public func reportMarkdownURL(forSlug slug: String) -> URL {
        workspaceURL(forSlug: slug).appendingPathComponent("report.md", isDirectory: false)
    }

    public func outputDirectoryURL(forSlug slug: String) -> URL {
        workspaceURL(forSlug: slug).appendingPathComponent("output", isDirectory: true)
    }

    public func tmpDirectoryURL(forSlug slug: String) -> URL {
        workspaceURL(forSlug: slug).appendingPathComponent("tmp", isDirectory: true)
    }

    public func workIndexURL() -> URL {
        workspacesRootURL.appendingPathComponent("WORK.md", isDirectory: false)
    }

    @discardableResult
    public func ensureClickyWorkspace(profile: ClickyProfile) -> URL {
        let workspaceDir = workspaceURL(forSlug: profile.slug)
        ensureDirectoryStructure(at: workspaceDir)
        ensureAgentsMarkdownIfNeeded(
            at: workspaceDir.appendingPathComponent("AGENTS.md", isDirectory: false),
            name: profile.name,
            roleText: profile.roleText,
            oneLiner: profile.oneLiner
        )
        return workspaceDir
    }

    @discardableResult
    public func ensureClickyWorkspace(slug: String) -> URL {
        if let profile = ClickyRoster.shared.clicky(forSlug: slug) {
            return ensureClickyWorkspace(profile: profile)
        }
        let workspaceDir = workspaceURL(forSlug: slug)
        ensureDirectoryStructure(at: workspaceDir)
        ensureAgentsMarkdownIfNeeded(
            at: workspaceDir.appendingPathComponent("AGENTS.md", isDirectory: false),
            name: slug,
            roleText: "Assistant",
            oneLiner: "Helps with ongoing work in this workspace."
        )
        return workspaceDir
    }

    public func readAgentsMarkdown(forSlug slug: String) -> String {
        let url = agentsMarkdownURL(forSlug: slug)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func readLiveNote(forSlug slug: String) -> String {
        let url = noteMarkdownURL(forSlug: slug)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func writeLiveNote(_ content: String, forSlug slug: String) {
        let workspaceDir = ensureClickyWorkspace(slug: slug)
        let targetURL = workspaceDir.appendingPathComponent("note.md", isDirectory: false)
        enqueueWrite(content: content, to: targetURL)
    }

    /// Moves `note.md` to `.clicky/previous-note.md` when starting a fresh scheduled routine run.
    @discardableResult
    public func rotateNoteToPrevious(forSlug slug: String) -> Bool {
        let workspaceDir = ensureClickyWorkspace(slug: slug)
        let noteURL = workspaceDir.appendingPathComponent("note.md", isDirectory: false)
        let previousURL = workspaceDir
            .appendingPathComponent(".clicky", isDirectory: true)
            .appendingPathComponent("previous-note.md", isDirectory: false)

        guard fileManager.fileExists(atPath: noteURL.path) else {
            return false
        }

        do {
            try fileManager.createDirectory(at: previousURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: previousURL.path) {
                try fileManager.removeItem(at: previousURL)
            }
            try fileManager.moveItem(at: noteURL, to: previousURL)
            return true
        } catch {
            print("⚠️ [ClickyWorkFolderFiles] Could not rotate note.md for \(slug): \(error)")
            return false
        }
    }

    public func readLongWorkMemory(forSlug slug: String) -> String {
        let url = longWorkMemoryURL(forSlug: slug)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func writeLongWorkMemory(_ content: String, forSlug slug: String) {
        let workspaceDir = ensureClickyWorkspace(slug: slug)
        let targetURL = workspaceDir
            .appendingPathComponent(".clicky", isDirectory: true)
            .appendingPathComponent("memory.md", isDirectory: false)
        enqueueWrite(content: content, to: targetURL)
    }

    public func syncJobArtifactsAndReport(for job: ClickyJob) {
        let workspaceDir = URL(fileURLWithPath: job.folderPath, isDirectory: true)
        ensureDirectoryStructure(at: workspaceDir)

        let ownerFileURL = workspaceDir
            .appendingPathComponent(".clicky", isDirectory: true)
            .appendingPathComponent("owner", isDirectory: false)
        enqueueWrite(content: "\(ownerStamp) \(job.clickySlug)\njob_id: \(job.id)\n", to: ownerFileURL)

        let reportURL = workspaceDir.appendingPathComponent("report.md", isDirectory: false)
        let renderedRunsBlock = Self.renderRunsBlock(for: job)
        if lastWrittenRunsBlockByJobID[job.id] != renderedRunsBlock {
            lastWrittenRunsBlockByJobID[job.id] = renderedRunsBlock
            let reportContent = Self.renderReportDocument(for: job, runsBlock: renderedRunsBlock)
            enqueueWrite(content: reportContent, to: reportURL)
        }

        updateWorkIndex()
    }

    public func updateWorkIndex(jobs: [ClickyJob]? = nil) {
        let resolvedJobs = jobs ?? ClickyJobStore.shared.visibleJobs
        let indexURL = workIndexURL()
        let rendered = Self.renderWorkIndexMarkdown(jobs: resolvedJobs)

        if lastIndexLinesByPath[indexURL.path] == rendered {
            return
        }
        lastIndexLinesByPath[indexURL.path] = rendered
        enqueueWrite(content: rendered, to: indexURL)
    }

    public func listOutputFiles(forSlug slug: String) -> [URL] {
        let outputURL = outputDirectoryURL(forSlug: slug)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: outputURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.sorted { left, right in
            left.lastPathComponent.localizedCaseInsensitiveCompare(right.lastPathComponent) == .orderedAscending
        }
    }

    private func ensureDirectoryStructure(at workspaceDir: URL) {
        let subdirectories = [
            workspaceDir,
            workspaceDir.appendingPathComponent(".clicky", isDirectory: true),
            workspaceDir.appendingPathComponent("output", isDirectory: true),
            workspaceDir.appendingPathComponent("tmp", isDirectory: true)
        ]
        for directory in subdirectories {
            if !fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    print("⚠️ [starter-agent] workspace creation failed for \(directory.path): \(error)")
                }
            }
        }
    }

    private func ensureAgentsMarkdownIfNeeded(
        at agentsURL: URL,
        name: String,
        roleText: String,
        oneLiner: String
    ) {
        guard !fileManager.fileExists(atPath: agentsURL.path) else { return }
        let template = """
        You are \(name), the user's persistent \(roleText) agent in HeyClicky.
        What you do: \(oneLiner).

        This folder is YOUR workspace: your notes live in this file and the
        files you produce belong here. You are not a one-off task runner —
        the user returns to you, and you remember.

        ## Identity
        - Name: \(name)
        - Role: \(roleText)
        - Speak as \(name) — consistent voice, first person.

        ## Standing preferences
        (Durable instructions the user has given you. Keep each to one line.)

        ## Notes
        (Your working memory. After any turn where you learn something durable
        about this job — accounts, structures, the user's taste, decisions
        made, ongoing threads of work — update this section: add the fact,
        dated, and prune anything stale or superseded. Keep it curated and
        short; this file is read before every turn. Never store secrets,
        passwords, or tokens here.)
        """
        enqueueWrite(content: template + "\n", to: agentsURL)
    }

    private func enqueueWrite(content: String, to targetURL: URL) {
        writeQueue.async {
            Self.writeAtomically(content: content, to: targetURL)
        }
    }

    private nonisolated static func writeAtomically(content: String, to targetURL: URL) {
        guard let data = content.data(using: .utf8) else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: targetURL, options: .atomic)
        } catch {
            print("⚠️ [ClickyWorkFolderFiles] Failed writing \(targetURL.path): \(error)")
        }
    }

    static func renderRunsBlock(for job: ClickyJob) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = [
            runsBlockStartMarker,
            "## Runs (HeyClicky keeps this list, newest last)"
        ]

        for run in job.runs {
            let timestamp = formatter.string(from: run.startedAt)
            let statusText: String
            switch run.outcome {
            case .working: statusText = "working now"
            case .done: statusText = "done"
            case .failed: statusText = "failed"
            case .stopped: statusText = "stopped by the user"
            }
            lines.append("## \(timestamp) · \(statusText)")
            lines.append("Asked: \(run.ask)")
            if let summary = run.summary, !summary.isEmpty {
                lines.append("Reported: \(summary)")
            } else if run.outcome != .working {
                lines.append("Reported: (no report)")
            }
            lines.append("")
        }

        if !job.artifactEntries.isEmpty {
            lines.append("Files:")
            for artifact in job.artifactEntries {
                lines.append("- \(artifact.path)")
            }
        }

        lines.append(runsBlockEndMarker)
        return lines.joined(separator: "\n")
    }

    static func renderReportDocument(for job: ClickyJob, runsBlock: String) -> String {
        let header = """
        # \(job.title)

        HeyClicky's record of this job (job_id \(job.id)): what each run was asked and what it reported, oldest first.

        """
        return header + "\n" + runsBlock + "\n"
    }

    private static func renderWorkIndexMarkdown(jobs: [ClickyJob]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = [
            "# Work HeyClicky has done for the user",
            "",
            "One folder per piece of work, newest first. In each: report.md (what each run was asked and what it reported) and output/ (the files it made).",
            ""
        ]

        let sortedJobs = jobs.sorted { left, right in
            let leftDate = left.finishedAt ?? left.createdAt
            let rightDate = right.finishedAt ?? right.createdAt
            return leftDate > rightDate
        }

        for job in sortedJobs {
            let dateString = formatter.string(from: job.finishedAt ?? job.createdAt)
            let status = job.outcome.rawValue
            lines.append("- \(dateString) · \(job.title) [\(status)] · clicky: \(job.clickySlug) · job_id: \(job.id) · folder: \(job.folderPath)")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
