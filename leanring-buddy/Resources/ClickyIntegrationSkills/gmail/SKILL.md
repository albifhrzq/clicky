---
name: gmail
description: Use when a task reads, searches, counts, drafts or replies to the user's Gmail (threads, drafts, attachments, "what came in", "reply to", "email X"). Not for Calendar, Drive or Docs.
---

# Gmail

Gmail tools run through the `composio` server. Search once for the slug, then call it with these shapes.

## Find mail
- `GMAIL_FETCH_EMAILS` `{query, max_results, include_payload, verbose, page_token}`. `max_results` defaults to 1, so always set it. Start with `include_payload: false, verbose: false` (headers and snippet only) and open the few messages you need with `GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID` or a whole conversation with `GMAIL_FETCH_MESSAGE_BY_THREAD_ID {thread_id}`.
- "Payload is too large" means ask for less: drop the payload, lower `max_results` (25–50), narrow the query, then page with `page_token` until `nextPageToken` is gone.
- Query operators: `from:`, `to:`, `subject:`, `in:sent`, `in:inbox`, `-from:me`, `has:attachment`, `is:unread`, quotes for exact phrases, `OR` in capitals.
- Dates: `after:YYYY/MM/DD` / `before:` count whole days in UTC and `before:` is exclusive. For a window in the user's local time ("last week", "yesterday"), use epoch seconds: `after:<start epoch> before:<end epoch>` (compute them with `date -j -f` or Python in the user's timezone).
- Results are not sorted; sort by `internalDate` yourself.

## Counting and totals
Never count or add by eye. Page through every result, save what matters (sender, date, thread id, amount) into a file in `tmp/` with a short script, and compute from the file. Say how many messages you covered. "Replied to" = threads where a message from the user (`in:sent` / `from:me`) is later than a message to them.

## Drafts (the default for anything outgoing)
- Reply in a thread: `GMAIL_CREATE_EMAIL_DRAFT {thread_id, recipient_email, body, is_html: false}`. Leave `subject` empty on a reply so Gmail keeps "Re: …". Get `thread_id` from the message you're answering, never invent it.
- New message: add `subject`; extra "To" people go in `extra_recipients`, not a comma list.
- Changing a draft: `GMAIL_UPDATE_DRAFT {draft_id, thread_id, recipient_email, subject, body}`. Resend every field, because an update rebuilds the message: without `thread_id` the draft drops out of its thread. Update the draft you made; don't create a second one.
- Attachments: `attachment: {name, mimetype, s3key}` where `s3key` is the absolute path of a local file (e.g. in your `output/`) or an s3key returned by a download tool. If attaching fails, still make the draft and say which file to attach.
- Only send (`GMAIL_SEND_DRAFT`) after the user approved that exact draft (recipients, subject and body). Never delete or archive their mail unless asked.

## Check before you say done
After creating or updating a draft, read it back (`GMAIL_GET_DRAFT {draft_id, format: "full"}` or `GMAIL_LIST_DRAFTS`) and confirm recipient, thread, body and attachment. Say "drafted", not "sent".

## Writing as them
Match the user's own tone and sign-off from their past sent mail or notes. Use the exact names, dates and times from the thread; if the thread offered a slot, quote it.
