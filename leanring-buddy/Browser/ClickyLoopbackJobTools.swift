//
//  ClickyLoopbackJobTools.swift
//  leanring-buddy
//
//  Real handlers for the agent-facing `find_jobs`, `read_job` and `repeat_this_job`
//  MCP tools served by ClickyLoopbackMCPServer.
//

import Foundation

/// Identity of the agent turn that made the current MCP request. The "clicky" MCP entry sends
/// `X-Clicky-Slug` / `X-Clicky-Thread` headers; the server publishes them here for tool handlers.
nonisolated enum ClickyMCPRequestContext {
    @TaskLocal static var clickySlug: String?
    @TaskLocal static var clickyThreadID: String?
}

extension ClickyLoopbackMCPServer {
    func registerJobTools() {
        registerTool(
            name: "repeat_this_job",
            description: "Make this job repeat on a schedule, or update/pause/resume/stop its routine. schedule examples: \"every 30 minutes\", \"every hour\", \"daily at 9:00\", \"weekdays at 08:30\", \"mon,wed,fri at 17:00\". action is set (default), pause, resume or stop.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "schedule": ["type": "string"],
                    "prompt": ["type": "string"],
                    "action": ["type": "string", "enum": ["set", "pause", "resume", "stop"]],
                    "ran_now": ["type": "boolean"],
                    "job_id": ["type": "string"]
                ]
            ]
        ) { arguments in
            Self.handleRepeatThisJobToolCall(arguments)
        }

        registerTool(
            name: "find_jobs",
            description: "Search earlier Clicky jobs by topic, title, site, or file.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer"]
                ]
            ]
        ) { arguments in
            Self.handleFindJobsToolCall(arguments)
        }

        registerTool(
            name: "read_job",
            description: "Read the report or conversation of an earlier job by job_id. detail: \"report\" (default) or \"conversation\".",
            inputSchema: [
                "type": "object",
                "properties": [
                    "job_id": ["type": "string"],
                    "detail": ["type": "string"]
                ],
                "required": ["job_id"]
            ]
        ) { arguments in
            Self.handleReadJobToolCall(arguments)
        }
    }

    // MARK: - Job resolution

    /// Thread header first, then newest working job of the slug. The newest working job of any slug is
    /// only a fallback for read-only callers; mutating tools must not guess which job is meant.
    static func resolveCurrentJob(allowAnySlugFallback: Bool = false) -> ClickyJob? {
        let jobStore = ClickyJobStore.shared
        if let threadID = ClickyMCPRequestContext.clickyThreadID, let job = jobStore.job(forThreadID: threadID) {
            return job
        }
        let workingJobs = jobStore.jobs.filter { $0.outcome == .working && !$0.isArchived }
        let candidateJobs: [ClickyJob]
        if let slug = ClickyMCPRequestContext.clickySlug, workingJobs.contains(where: { $0.clickySlug == slug }) {
            candidateJobs = workingJobs.filter { $0.clickySlug == slug }
        } else if allowAnySlugFallback {
            candidateJobs = workingJobs
        } else {
            return nil
        }
        return candidateJobs.max { $0.createdAt < $1.createdAt }
    }

    private static func isoString(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return ISO8601DateFormatter().string(from: date)
    }

    // MARK: - repeat_this_job

    private static func handleRepeatThisJobToolCall(_ arguments: [String: Any]) -> ClickyMCPToolResult {
        let explicitJobID = (arguments["job_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let job: ClickyJob?
        if let explicitJobID, !explicitJobID.isEmpty {
            job = ClickyJobStore.shared.job(withID: explicitJobID)
        } else {
            job = resolveCurrentJob()
        }
        guard let job else {
            return ClickyMCPToolResult.error("I couldn't tell which job this is from the request's thread or clicky slug. Pass job_id.")
        }

        let rawAction = (arguments["action"] as? String)?.lowercased() ?? "set"
        guard let action = RepeatJobAction(rawValue: rawAction) else {
            return ClickyMCPToolResult.error("action must be one of set, pause, resume, stop.")
        }

        var everyMinutes: Int?
        var timeString: String?
        var days: [String]?
        if action == .set, let schedule = arguments["schedule"] as? String,
           !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsedSchedule = ClickyRepeatScheduleParser.parse(schedule) else {
                return ClickyMCPToolResult.error(
                    "I couldn't understand the schedule \"\(schedule)\". Try \"every 30 minutes\", \"daily at 9:00\", or \"weekdays at 08:30\"."
                )
            }
            everyMinutes = parsedSchedule.everyMinutes
            timeString = parsedSchedule.timeString
            days = parsedSchedule.days
        }

        let scheduler = ClickyRoutineScheduler.shared
        let hasExistingRoutine = scheduler.routine(forJobID: job.id) != nil
        let promptText = (arguments["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = (promptText?.isEmpty == false) ? promptText : (hasExistingRoutine ? nil : job.prompt)

        let result = scheduler.handleRepeatThisJob(
            jobID: job.id,
            clickySlug: job.clickySlug,
            action: action,
            everyMinutes: everyMinutes,
            timeString: timeString,
            days: days,
            title: hasExistingRoutine ? nil : job.title,
            task: task,
            ranNow: arguments["ran_now"] as? Bool
        )
        let structured: [String: Any] = [
            "ok": result.ok,
            "status": result.status,
            "routine_id": result.routineID ?? NSNull(),
            "next_run_at": isoString(result.nextRunAt),
            "message": result.message
        ]
        return ClickyMCPToolResult(
            content: [["type": "text", "text": result.message]],
            structuredContent: structured,
            isError: !result.ok
        )
    }

    // MARK: - find_jobs

    private static func handleFindJobsToolCall(_ arguments: [String: Any]) -> ClickyMCPToolResult {
        let query = arguments["query"] as? String ?? ""
        let requestedLimit = (arguments["limit"] as? NSNumber)?.intValue ?? 10
        let limit = min(max(1, requestedLimit), 50)
        let matchedJobs = ClickyJobStore.shared.findJobs(matchingQuery: query, limit: limit)
        let jobEntries: [[String: Any]] = matchedJobs.map { job in
            [
                "job_id": job.id,
                "title": job.title,
                "clicky": job.clickySlug,
                "status": job.outcome.rawValue,
                "created_at": isoString(job.createdAt),
                "finished_at": isoString(job.finishedAt),
                "summary": job.summary ?? NSNull(),
                "folder": job.folderPath,
                "report_path": URL(fileURLWithPath: job.folderPath).appendingPathComponent("report.md").path
            ]
        }
        return ClickyMCPToolResult(structuredContent: ["jobs": jobEntries], isError: false)
    }

    // MARK: - read_job

    private static func handleReadJobToolCall(_ arguments: [String: Any]) -> ClickyMCPToolResult {
        guard let jobID = (arguments["job_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jobID.isEmpty,
              let job = ClickyJobStore.shared.job(withID: jobID) else {
            return ClickyMCPToolResult.error("No job with that job_id. Use find_jobs to look it up.")
        }

        let workFolderFiles = ClickyWorkFolderFiles.shared
        let outputFileNames = workFolderFiles.listOutputFiles(forSlug: job.clickySlug).map(\.lastPathComponent)

        if (arguments["detail"] as? String)?.lowercased() == "conversation" {
            let runEntries: [[String: Any]] = job.runs.map { run in
                [
                    "ask": run.ask,
                    "summary": run.summary ?? NSNull(),
                    "status": run.outcome.rawValue,
                    "started_at": isoString(run.startedAt)
                ]
            }
            // ponytail: chatMessages for the slug are not exposed here (CompanionManager has no shared
            // accessor); runs carry each ask and summary.
            return ClickyMCPToolResult(
                structuredContent: [
                    "job_id": job.id,
                    "title": job.title,
                    "runs": runEntries,
                    "output_files": outputFileNames
                ],
                isError: false
            )
        }

        let reportURL = URL(fileURLWithPath: job.folderPath).appendingPathComponent("report.md")
        let reportText = (try? String(contentsOf: reportURL, encoding: .utf8))
            ?? ClickyWorkFolderFiles.renderReportDocument(
                for: job,
                runsBlock: ClickyWorkFolderFiles.renderRunsBlock(for: job)
            )
        return ClickyMCPToolResult(
            content: [["type": "text", "text": reportText]],
            structuredContent: [
                "job_id": job.id,
                "title": job.title,
                "report": reportText,
                "output_files": outputFileNames
            ],
            isError: false
        )
    }
}
