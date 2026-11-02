---
name: clickup
description: Use when a task reads or changes the user's ClickUp tasks (what's on my plate, what's overdue, add a task to a list, move a task to review or close it, re-date it, comment on it, add a checklist). Not for Asana, Todoist or Jira.
---

# ClickUp

ClickUp tools run through the `composio` server.

## Find
- Workspace id: `CLICKUP_GET_AUTHORIZED_TEAMS_WORKSPACES {}` → `teams[].id`. The user: `CLICKUP_GET_AUTHORIZED_USER {}` → `user.id` (an integer) and `user.timezone`.
- List by name: walk `CLICKUP_GET_SPACES {team_id}` → `CLICKUP_GET_FOLDERS {space_id}` → `CLICKUP_GET_LISTS {folder_id}`, and also `CLICKUP_GET_FOLDERLESS_LISTS {space_id}`. A task is created in a `list_id` (the number after `/li/` in a URL).
- Workspace-wide: `CLICKUP_GET_FILTERED_TEAM_TASKS {team_Id, assignees: [<user id>], due_date_lt, include_closed, subtasks: true, page: 0}` (capital I). One list: `CLICKUP_GET_TASKS {list_id, page: 0}`; ≤100 per page, raise `page` until `last_page`. No text search: match names yourself.
- Defaults hide closed tasks, subtasks, archived tasks and (per list) tasks homed in another List. Before "not found", retry with `include_closed: true, subtasks: true`. A filter value that doesn't match exactly returns empty, not an error.
- One task: `CLICKUP_GET_TASK {task_id}` (from `/t/<id>`). A custom id like `ABC-123` needs `custom_task_ids: true` plus `team_id`. Comments: `CLICKUP_GET_TASK_COMMENTS {task_id}`.

## Statuses, priority, dates
- Statuses are per List, case-sensitive: read `CLICKUP_GET_LIST {list_id}` → `statuses[].status`. "Close it" = the status whose `type` is `"closed"`; "done" may not exist by name.
- Priority: 1 Urgent, 2 High, 3 Normal, 4 Low.
- Dates are Unix milliseconds. With `due_date_time` false the date is all-day and lands on the calendar day of that instant in the user's zone: send the target day's local noon, never midnight UTC. Returned dates are UTC ms: convert.

## Write (only what was asked; assignees and watchers are notified)
- `CLICKUP_CREATE_TASK {list_id, name, description, priority, due_date: <ms>, due_date_time: false, assignees: [<int user id>]}`. People → ids: `CLICKUP_GET_LIST_MEMBERS {list_id}`. `description` is plain text here.
- `CLICKUP_UPDATE_TASK {task_id, status?, due_date?, priority?, description?}`: sent fields replace (read the description first to extend it). Assignees change only via `assignees__add` / `assignees__rem`.
- Comment: `CLICKUP_CREATE_TASK_COMMENT {task_id, comment_text, assignee: <own id>, notify_all: false}`, all required; `assignee` assigns the comment.
- Checklist: `CLICKUP_CREATE_CHECKLIST {task_id, name}`, then `CLICKUP_CREATE_CHECKLIST_ITEM {checklist_id, name}`.
- Custom fields: `CLICKUP_SET_CUSTOM_FIELD_VALUE {task_id, field_id, value}`.
- Close by status, never `CLICKUP_DELETE_TASK`; no delete, archive or reassign unless asked.

## Check before you say done
`CLICKUP_GET_TASK` again: status, due date in the user's zone, assignees, list; give the task `url`. In a batched execute, read each call's own result.
