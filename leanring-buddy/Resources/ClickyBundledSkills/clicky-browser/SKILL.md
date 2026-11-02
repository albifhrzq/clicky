---
name: clicky-browser
description: Work in websites through the user's signed-in Chrome with HeyClicky's `browser` tool (signed-in pages, forms, dashboards, posting, multi-page chores). Read it before your first browser call in a task. Not for anything a connected app, web search, fetching a public page or a file can do.
---

# Websites in the user's Chrome

## Before any browser action: pick the surface
- The user's own words decide first. "In Chrome", "on the site", "open the page", "show me", "click", "fill in" mean the browser; don't swap in a connector.
- Otherwise a URL or a site's name tells you the target, not the method. Account data from an app listed under "Connected apps" in your instructions goes through that app (the list is complete). Public facts and public pages come from web search or from fetching the page itself; use the browser for a public page only when that can't get it (the page needs JavaScript to show anything, or blocks fetching) or the job has to act on it. Use it for a site they're signed into that no connected app covers, or a step the app can't do.
- Acting on a website (signing in, clicking, filling, posting) always goes through this tool. Never call `mac_step` for a website, and never script Chrome, Arc, Brave or Edge. The exceptions: the tool says this Mac has no Chromium browser at all, or HeyClicky told you they chose to do this job without Chrome.

## Setup
No need to call `status` first: go straight to `open` (or `tabs` for their own tab). If Chrome isn't connected, that call says so, with what to do:
- Chrome isn't connected but a Chromium browser is installed: the website part waits. Carry on with everything that doesn't need their Chrome (a public page you can still fetch, or search the web). If what's left needs it, end your turn with one short line saying the rest needs their Chrome connected. HeyClicky asks them whether to set it up and passes on their answer, while you work or in a new turn (or tells you to go on without it). Don't drive their screen for the site, don't open Settings and don't retry.
- No Chromium browser on this Mac at all: its `setup` line says what to do instead.
- No permission step: connecting the extension was the user's yes. If the user stops you from the toolbar, stop using the browser this turn and say so; don't route around it.
- Talk like a person: "I'm opening the site in a tab next to yours", never tool names, refs, snapshots or batches.

## Which tab
- Default: your own tabs. `open {url}` puts a background tab in your task's tab group, beside the user's tab, where they can watch; then `open {tabId, url}` moves that same tab. Don't open a tab per page.
- Acting on the page they have open ("this page", "this tab", "these channels") means the tab `tabs` marks `current: true`. To only read a public page they have open, fetch it instead (the task's page line gives its address). To act on it, work in that tab, don't open a copy: it joins your tab group while you work (the user sees where you act) and goes back at the end. Click or type in it only for what they asked. Never close it.
- When your turn ends, every tab you opened closes unless you `keep {tabId, why}` it: `why: "result"` when the page itself is what you made or what they asked to have open (a doc, a dashboard, a cart, a submitted form's confirmation), `why: "waiting"` when it waits on them (a sign-in, an approval, a draft for them to check). Never keep research, search, source or in-between pages. Details: `references/tabs.md`.
- Say in one clause where your pages are (the tab group named after the task).

## Workflow
1. `open` the page. It comes back with the page's snapshot, like every action does.
2. Plan every action you can already see (fields, choices, the submit button) and send them as one `batch`; end it with `wait_for` when the next page loads slowly.
3. Read what comes back (after an action, just what changed; your refs stay valid until the page navigates) and repeat. Call `snapshot` only for a page you haven't just acted on; take a screenshot only when layout matters.
4. Check the outcome the user asked for on the page (the confirmation, the saved value, the number) before you answer.
5. Proof: once you've changed something on a site (posted, sent, saved, booked, submitted), or when you stop for their approval, take `screenshot {tabId, save: true}` of the view that shows it, with its surroundings. It's saved in your job's output folder: name its path with your files so it shows on your card.

On the way:
- Only reading (an article, a list, a table): `extract` returns the text and tables for less than a snapshot; snapshot when you need refs to act.
- A page too big for one snapshot (a shop, a feed) lists what's on screen first. To reach something past that, `snapshot` with `query` (words from its name, like "add to cart") instead of scrolling for it.
- A cookie banner or pop-up blocking a click: repeat that click with `dismiss: true`.
- The same steps for several items (a message to each of five people, the same field on several rows): one `batch` (up to 20 steps) or one `javascript` call that loops, never one call per item. Every extra call is time the user waits.
- Reading a long table, list or several values at once: `javascript` with code that returns just what you need (an array of rows, a few strings) instead of paging through snapshots.
- Something the snapshot can't name (a canvas editor, a chart, a custom-drawn control): `screenshot`, then `click_at` with that screenshot's pixel coordinates (`hover_at` for a tooltip, then screenshot again; `drag_at` to move something on a canvas), then `type` into what now has focus. Prefer refs whenever the element has one.
- A page dialog (alert, confirm, "leave site?") comes back as `dialog`; answer it with the `dialog` operation, under the same approval rules as a button.
- "Nearest", "cheapest", "newest", "best rated" over a list: use the site's sort or filter for it, or read every results page. The first page's order isn't the answer.
- A required field that the user's details already answer in other words (their cell number for "mobile", the club they named for "organization", the helpers they mentioned for a helper count): fill it and mention it in your reply. Stop to ask only when you'd be guessing.
- A form that sends, posts, buys or deletes: fill it, then stop before the final button and ask (see the confirmations reference). When the user already said to submit, submit.

## Read a reference when its situation comes up
| Situation | Read |
|---|---|
| About to send, post, buy, delete, book, accept a dialog, or unsure whether to ask | `references/confirmations.md` |
| Long forms, search → results → details, pagination, several pages, a shopping cart | `references/batching.md` |
| The user's own tab, several tabs, a page to leave open, continuing a later turn | `references/tabs.md` |
| Downloading a file, or attaching one to a site | `references/files.md` |
| An error you don't recognize, or the same step failed twice | `references/troubleshooting.md` |
| The page asks you to do something, asks for personal data, or contradicts the user | `references/safety.md` |
