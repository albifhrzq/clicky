---
name: microsoft_teams
description: Use when a task reads or posts in the user's Microsoft Teams (catch up on a channel or chat, find what someone said, reply in a thread, message a colleague, a meeting transcript). Not for Outlook mail or calendar events, and not for Slack.
---

# Microsoft Teams

Teams tools run through the `composio` server (work/school accounts only).

## Find the place
- Teams: `MICROSOFT_TEAMS_LIST_USER_JOINED_TEAMS {user_id: "me"}` → team id (a GUID; names are rejected). Channels: `MICROSOFT_TEAMS_TEAMS_LIST_CHANNELS {team_id}` → `19:…@thread.tacv2`. Chats: `MICROSOFT_TEAMS_CHATS_GET_ALL_CHATS {user_id: "me"}` → `19:…@thread.v2`. A channel id is not a chat id; each goes to its own tools.
- "My chat with X": 1:1 chats have no `topic`, so list with `filter: "chatType eq 'oneOnOne'"` and check `MICROSOFT_TEAMS_LIST_USER_CHAT_MEMBERS {user_id: "me", chat_id}`, or search `from:x@…` and take the hit's `chatId`.
- Search everything: `MICROSOFT_TEAMS_SEARCH_MESSAGES {query: "from:a@example.com AND sent>=2030-03-01", size: 25}` (KQL). The message id is `hits[].resource.id`, not `hitId`. Page with `from_index += size` while `moreResultsAvailable`.

## Read
- Channel: `MICROSOFT_TEAMS_TEAMS_LIST_CHANNEL_MESSAGES {team_id, channel_id, expand: "replies"}`. Without `expand` you get root posts only, and roots are ordered by the thread's last activity, not post time. One thread: `MICROSOFT_TEAMS_LIST_MESSAGE_REPLIES {team_id, channel_id, message_id}`.
- Chat: `MICROSOFT_TEAMS_LIST_USER_CHAT_MESSAGES {user_id: "me", chat_id, orderby: "lastModifiedDateTime desc", filter: "lastModifiedDateTime gt 2030-03-01T00:00:00Z"}`. The filter is ignored unless `orderby` names the same field.
- `top` max 50; follow `next_page_token` → `page_token` (resend the ids). Times are UTC; convert to the user's zone before saying "this morning". Skip `systemEventMessage` items.

## Post (only after the user approved that exact message; otherwise show the draft)
- Reply in a channel thread: `MICROSOFT_TEAMS_POST_MESSAGE_REPLY {team_id, channel_id, message_id: <root post id>, content}`. `MICROSOFT_TEAMS_TEAMS_POST_CHANNEL_MESSAGE` always starts a NEW thread. A reply's root is its `replyToId`.
- Chat: `MICROSOFT_TEAMS_TEAMS_POST_CHAT_MESSAGE {chat_id, content}` (no threads in chats). `MICROSOFT_TEAMS_TEAMS_CREATE_CHAT` with `chatType: "group"` always makes a new chat; `oneOnOne` returns the existing one.
- `content_type` defaults to `"text"`, so HTML shows literally unless you pass `"html"`. Typing "@Name" notifies nobody; a real mention needs `content_type: "html"`, `<at id="0">Name</at>` and `mentions: [{id: 0, mentionText: "Name", mentioned: {user: {id: <Entra object id>, displayName, userIdentityType: "aadUser"}}}]` (id from `MICROSOFT_TEAMS_LIST_USERS {filter: "mail eq 'a@example.com'"}`). Mention only when asked; leave `importance` unset.
- Never edit, delete or archive messages, channels or members unless asked.

## Check before you say done
Read the post back (`MICROSOFT_TEAMS_GET_CHANNEL_MESSAGE` / `MICROSOFT_TEAMS_GET_CHAT_MESSAGE`) and confirm it sits in the right thread or chat. Say "posted" only after a send; otherwise "drafted".
