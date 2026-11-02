---
name: outlook
description: Use when a task reads or changes the user's Outlook / Microsoft 365 mail or calendar (what came in, find an email, draft a reply, file or flag mail, what's on today, put a hold on the calendar). Not for Gmail or Google Calendar.
---

# Outlook

Outlook tools run through the `composio` server.

## Find mail
- Whole mailbox by words/sender/recipient: `OUTLOOK_SEARCH_MESSAGES {query: "from:a@example.com AND subject:\"Q3 plan\" AND received>=2030-03-01", size: 25}`. The id to use next is `hits[].hitId` (not `resource.id`). Page with `from_index += 25` while `moreResultsAvailable`.
- One folder: `OUTLOOK_LIST_MESSAGES {folder, top: 50, filter: "isRead eq false and receivedDateTime ge 2030-03-03T00:00:00Z"}`. `top` defaults to 10, and `from_address` / `has_attachments` / `subject_contains` only filter that page: a sender not in the first 10 looks absent. Use `filter` or SEARCH. Page with `data.next_page_token` → `page_token` until it's gone. Bodies aren't included: `OUTLOOK_GET_MESSAGE {message_id}`.
- Custom folders need ids from `OUTLOOK_LIST_MAIL_FOLDERS` (well-known: `inbox`, `sentitems`, `drafts`, `archive`). `OUTLOOK_MOVE_MESSAGE` returns a NEW message id; use it afterwards.

## Drafts (the default for anything outgoing)
- Reply to the sender: `OUTLOOK_CREATE_DRAFT_REPLY {message_id, comment}` on the latest message of the thread (a message id, not `conversationId`). Reply-all: `OUTLOOK_CREATE_ME_MESSAGE_REPLY_ALL_DRAFT {user_id: "me", message_id, comment}`.
- New mail: `OUTLOOK_CREATE_DRAFT {subject, body, to_recipients: ["a@example.com"]}`; `is_html` is false, so HTML shows as literal tags.
- `OUTLOOK_REPLY_EMAIL`, `OUTLOOK_SEND_EMAIL`, `OUTLOOK_SEND_DRAFT`, `OUTLOOK_FORWARD_MESSAGE` send at once: only after the user approved that exact draft (recipients, subject and body). Never delete mail unless asked; "trash" is a move to `deleteditems`.
- `OUTLOOK_UPDATE_EMAIL` `to_recipients` / `categories` replace the whole list: resend existing ones to add.

## Calendar and time zones
- "What's on today": `OUTLOOK_GET_CALENDAR_VIEW {start_datetime: "2030-03-03T00:00:00-05:00", end_datetime: "2030-03-04T00:00:00-05:00", timezone: "America/New_York"}`. The window uses the offset in the strings (none = UTC); `timezone` only sets how times come back (default UTC). It expands recurring meetings; `OUTLOOK_LIST_EVENTS` returns series masters unless `expand_recurring_events: true`.
- Returned `start.dateTime` has no offset; read it with `start.timeZone`. The user's zone comes from their notes, else `OUTLOOK_GET_MAILBOX_SETTINGS`.
- Hold: `OUTLOOK_CALENDAR_CREATE_EVENT {subject, start_datetime: "2030-03-03T10:00:00", end_datetime, time_zone: "America/New_York"}` (local time, no offset). Any `attendees_info` sends invites: add people only when asked.
- `OUTLOOK_UPDATE_CALENDAR_EVENT {event_id, …}` keeps unspecified fields, but `attendees` replaces the list and changes notify attendees. Deleting a meeting you organize cancels it for everyone.

## Microsoft To Do is not available
This connection can't read or change To Do lists or tasks: the `OUTLOOK_*TO_DO*` tools always answer 403 because the sign-in never grants task access. Don't call them. If the user asks about their To Do tasks, say plainly that HeyClicky can't reach Microsoft To Do yet, and offer what does work (flagged mail, a calendar hold, or a list in the chat).

## Check before you say done
Read it back (`OUTLOOK_GET_MESSAGE` / `OUTLOOK_GET_EVENT`): recipients, thread, times in the user's zone. Give its `webLink`. Say "drafted", not "sent".
