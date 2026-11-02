---
name: linear
description: Use when a task reads or changes the user's Linear issues (what's blocking a release, status of an issue, what changed on the board, assigning or moving an issue).
---

# Linear

Linear tools run through the `composio` server. Prefer the typed tools; hand-written GraphQL (`LINEAR_RUN_QUERY_OR_MUTATION`) often fails to parse, so use it only when no typed tool fits, and keep the query small.

## Read
- Teams and ids: `LINEAR_LIST_LINEAR_TEAMS {first: 50}`. Current user: `LINEAR_GET_CURRENT_USER {}`.
- Issues: `LINEAR_LIST_LINEAR_ISSUES {first, project_id?, …}`, `LINEAR_LIST_ISSUES_BY_TEAM_ID {team_id, first}`, or `LINEAR_SEARCH_ISSUES {query, first}` for words. One issue by key: `LINEAR_GET_LINEAR_ISSUE {issue_id: "ABC-123"}`.
- Read each issue's state, assignee, priority, labels, due date, and its relations: "blocked by" / "blocks" links and a `blocker` label are what make something a blocker. Report issue keys (ABC-123) with titles.
- Projects and cycles: `LINEAR_LIST_LINEAR_PROJECTS`, then filter issues by project; check the target date.

## What changed
Linear has no "since yesterday" view. Save a snapshot (key, title, state, assignee, priority, labels) to a file in your folder, and on the next run compare against it: report only new, closed, moved, reassigned or newly blocking issues, most important first, then update the snapshot. Say plainly when nothing changed.

## Write (only when asked)
- `LINEAR_UPDATE_ISSUE {issueId: <uuid>, stateId?, assigneeId?, priority?}` takes ids, not names: get state ids from `LINEAR_LIST_LINEAR_STATES {team_id}` and user ids from the team's members.
- `LINEAR_CREATE_LINEAR_ISSUE {team_id, title, description}` for new issues. Don't close, delete or reassign issues unless asked.

## Check before you say done
Read the issue back and confirm the new state/assignee. Link issues by their URL.
