# Doing more per call

Each browser call is a full round trip through the model, so the fastest run is the one with the fewest calls. Every action already returns the settled page's snapshot; `batch` goes further and runs up to 20 actions in one tab with a single snapshot at the end.

## Rules of thumb
- One batch per page state: everything you can already see and decide, in order.
- Refs in a batch come from your latest snapshot. They keep working through fills and clicks until the page navigates, so put the step that navigates last, or follow it only with steps that need no ref (`wait_for`, `press`, `scroll`, `back`).
- End with `wait_for` (text you expect, or part of the URL) when the result appears after a delay. `gone: true` waits for a "Loading…" text to disappear.
- Stop the batch where you'd need to see the page to decide the next step (which result is right, which options a dropdown now offers). The returned snapshot shows it.
- If a step fails, the batch stops there and says which steps didn't run. Continue from the snapshot it returned; never re-run the steps that already succeeded.
- Stage gate actions, don't batch past them: fill everything, and leave the send, post, buy or delete button for after the user says yes.

## Patterns
**Open and look (1 call):** `open {url}` returns the new tab's id and its snapshot. `batch` with no `tabId` and `open` as its first step opens and acts in one call.

**A form page (1 call per page):**
`[{fill, ref: name, text}, {fill, ref: email, text}, {fill, ref: country, text: "Canada"}, {click, ref: continue}, {wait_for, text: "Step 2"}]`
Dropdowns (`<select>`) take `fill` with the option's visible text; a wrong value lists the choices. Checkboxes and radio buttons take `click`.

**Search, then results (1 call):**
`[{fill, ref: search, text: "italian"}, {press, key: "Enter"}, {wait_for, text: "results"}]`

**Paging through a list:** `[{click, ref: next}, {wait_for, text: "Page 2"}]` per page, reading each returned snapshot. When the site's URLs are obvious (`?page=3`, a detail URL), one `open {tabId, url}` straight there is fine; if that single try doesn't land, go back to the page's own links instead of guessing more URLs.

**Shopping carts:** add from the search results page when each result has its own Add to cart; product pages are bigger and cost steps. After each add, check it took (the button now says "1 in cart", or the cart count or subtotal changed) before leaving the page: navigating right after the click can drop the add.

**Details hidden behind toggles:** click every "Show more" / disclosure you need in one batch, then read the one snapshot.

## Cheap checks
- The snapshot an action or batch returns is current; don't take another one straight after it.
- `wait_for` is cheaper than repeated snapshots when you're waiting for a known text.
- Once the page shows the one clear signal you need (the confirmation, the selected option, the price), answer; don't re-verify it elsewhere.
