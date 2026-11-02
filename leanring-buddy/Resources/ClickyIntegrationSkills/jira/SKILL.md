---
name: jira
description: Use when a task reads or changes the user's Jira issues (my open issues, what's in the sprint, file a bug, move an issue to done, comment on or assign a ticket, what changed on an issue). Not for Linear, GitHub issues or Confluence pages.
---

# Jira

Jira tools run through the `composio` server.

## Find
- `JIRA_SEARCH_ISSUES {jql, fields: ["summary","status","assignee","priority","duedate","labels"], max_results: 100}`. `max_results` defaults to 20: page with `next_page_token` (pass the returned token back alone) until none is returned. Count with `JIRA_SEARCH_APPROXIMATE_COUNT {jql}` or by paging all, never one page.
- JQL: "mine" is `assignee = currentUser()`, open is `statusCategory != Done` (status names differ per project), quote spaced values `status = "In Review"`, lists `status IN ("To Do","In Review")`, words `text ~ "login timeout"` (summary, description and comments: keep every hit). An ORDER BY with no filter is rejected. Relative dates (`-7d`, `startOfDay()`) use the Jira profile's time zone.
- One issue: `JIRA_GET_ISSUE {issue_id_or_key: "ABC-123", expand: "changelog"}` for history; comments `JIRA_LIST_ISSUE_COMMENTS {issue_id_or_key}`.
- Descriptions and comments come back as ADF JSON: read every nested `text` node (lists, tables), or `expand: "renderedFields"`.

## Names → ids
- Project name → key: `JIRA_GET_ALL_PROJECTS {query}`. Use the key (`ABC`), not the name.
- Person → `accountId`: `JIRA_FIND_USERS2 {query}`; emails can be hidden, so match display name and confirm.
- Required fields and priority names vary per site: `JIRA_GET_CREATE_METADATA_ISSUE_TYPE_FIELDS {projectIdOrKey, issueTypeId}` if a create fails, `JIRA_GET_ISSUE_EDIT_METADATA` before an edit. Custom fields are `customfield_NNNNN`, never display names.

## Write (only what was asked; assignees and watchers get emailed)
- Create: `JIRA_CREATE_ISSUE {project_key, issue_type, summary, description, due_date: "2030-03-03", labels, assignee: <accountId>}` (`assignee_name` for an email/name). Markdown description is fine. Read it back: some projects drop the assignee silently.
- Status only moves by transition: `JIRA_GET_TRANSITIONS {issue_id_or_key}` → the `id` whose `to` status matches → `JIRA_TRANSITION_ISSUE {issue_id_or_key, transition_id_or_name: "31"}`. Ids depend on the current status; never reuse one from another issue, never put `status` in an edit.
- `JIRA_EDIT_ISSUE` `labels` and `description` REPLACE. To add a label: `{issue_id_or_key, update: "{\"labels\":[{\"add\":\"triaged\"}]}"}` (a JSON string). To extend a description, read it and send old + new. Leave `notify_users` out (turning it off needs project-admin rights and fails).
- `JIRA_ADD_COMMENT {issue_id_or_key, comment}` is visible to the team and @mentions notify.
- Links: `JIRA_CREATE_ISSUE_LINK {inward_issue_key, outward_issue_key, link_type: "Blocks"}`; check the direction after.
- Done is a transition, never a delete. Don't delete, reassign or close unless asked.

## Check before you say done
`JIRA_GET_ISSUE` again: status, assignee, labels, links, due date as intended. Report keys with titles and the issue URL (`https://<site>.atlassian.net/browse/ABC-123`).
