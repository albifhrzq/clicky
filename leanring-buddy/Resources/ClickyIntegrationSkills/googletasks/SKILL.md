---
name: googletasks
description: Use when a task reads or changes the user's Google Tasks to-dos (add a to-do for Friday, what's due or overdue, what's left, tick something off, reschedule, make a subtask, move to another list). Not for Asana, Linear or calendar events.
---

# Google Tasks

Google Tasks tools run through the `composio` server. It has no assignees, priorities, reminders or times of day, and nothing here notifies other people.

## Read
- Everything at once: `GOOGLETASKS_LIST_ALL_TASKS {showCompleted: false}` → `tasks[]`, each with `tasklist_id` and `tasklist_title`. `showCompleted` defaults to true, so "what's left" needs `false` (or filter on `status: "needsAction"`). If `truncated` is true, raise `max_tasks_total`.
- "What did I finish": `{showCompleted: true, showHidden: true, completedMin: "<UTC ISO>"}`. Tasks ticked off in Google's own apps are hidden, so without `showHidden` they're missing.
- Lists: `GOOGLETASKS_LIST_TASK_LISTS {maxResults: 100}` (default 20). One list: `GOOGLETASKS_LIST_TASKS {tasklist_id, maxResults: 100, pageToken}`; the response key is `tasks`, ordered by position, not date; follow `nextPageToken`.
- No text search: match titles yourself. Titles (of lists and tasks) can repeat; pick by id after checking due/notes.

## Dates are days, not times
`due` is a date only, stored as midnight UTC: send the calendar day the user means, `due: "2030-03-03"`. A time of day is dropped, and a late local time converted to UTC can land on the wrong day. Say so if the user gave a time. "Due on a day": `dueMin: "2030-03-03T00:00:00Z", dueMax: "2030-03-03T23:59:59Z"`. Overdue = `due` before today in the user's zone and `status: "needsAction"`.

## Write
- Every call needs the list id as well as the task id. The primary list is `"@default"`; others come from the listings.
- Add: `GOOGLETASKS_INSERT_TASK {tasklist_id, title, notes?, due?}`. It lands at the top of the list; pass `task_parent` to make it a subtask. It isn't idempotent: after a timeout, list before retrying so you don't add a duplicate. An add is a new task, never a rename of an old one.
- Change: `GOOGLETASKS_PATCH_TASK {tasklist_id, task_id, status: "completed"}` (reopen: `"needsAction"`), or `{due}` / `{title}`. `notes` is replaced whole: to add a line, read the task and send old notes + new. Don't use `GOOGLETASKS_UPDATE_TASK_FULL`: it clears every field you leave out.
- Nest, reorder or move lists: `GOOGLETASKS_MOVE_TASK {tasklist, task, parent?, previous?, destinationTasklist?}` (note the different argument names). PATCH can't change the parent.
- Never delete tasks or lists, or `GOOGLETASKS_CLEAR_TASKS`, unless asked: all are permanent.

## Check before you say done
`GOOGLETASKS_GET_TASK {tasklist_id, task_id}`: confirm title, list, `due` day, status and parent. Give the task's `webViewLink`.
