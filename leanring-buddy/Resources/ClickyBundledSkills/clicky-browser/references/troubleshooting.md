# Browser errors and what to do

Match the start of the error text. Never loop: if the fix below doesn't work once, change approach or tell the user what's blocking.

## Connection and permission
| Error | What to do |
|---|---|
| `Chrome isn't connected. …` | Do what the rest of the message says (Setup in the skill): the parts that don't need the site, one line about the one-time setup, then end your turn. Never do the site another way. |
| `Browser permission was declined or the turn ended.` / `Browser access is unavailable for this turn.` | The user said no, or the turn is over. Stop using the browser this turn; finish without it and say what you couldn't check. |
| `Another browser permission request is open. Wait for it to finish.` | Another Clicky is asking right now. Do other work first, then try once more. |
| `Browser access stopped for this turn…` / `Browser access stopped. An in-flight action may already have completed…` | The user pressed Stop. Stop all browser work, report what was done and what may have happened. |
| `Browser action timed out. Its outcome is unknown…` / `The agent turn ended.` | Browser access for this turn is over. Don't repeat the action; tell the user it may or may not have gone through, and look first next turn. |
| `The page didn't answer in time. Nothing was changed…` / `The page did not respond in time (it may be a sleeping background tab)…` | A read stalled, usually on a tab the user left in the background. Try once more; if it stalls again, `open` the same URL in your own tab and read it there. Nothing needs re-checking. |
| `Browser connection changed. Start a new turn.` / `Browser tool is unavailable outside its active agent turn.` | Chrome reconnected or the turn changed. Tell the user; continue in the next turn. |

## References and page changes
| Error | What to do |
|---|---|
| `Stale or unknown reference. Take a new snapshot.` | The ref is from an older snapshot, or a single click/fill already used it. Snapshot, then act (or batch the actions next time). |
| `The page changed after an earlier step, so this reference no longer applies.` | An earlier batch step navigated. Use the snapshot the batch returned. |
| `Page changed. Take a new snapshot.` / `Page changed during observation…` / `The page is navigating…` | The page moved while acting. Snapshot, check what happened, then continue. Don't repeat a send or submit blindly. |
| `The page is still loading. Take a snapshot in a moment…` | Use `wait_for` with text you expect, or snapshot once more. |
| `Element disappeared…` / `Element is not visible…` / `Element is outside the visible page…` / `Element is not clickable.` | The page re-rendered or the element is hidden. Snapshot; open the menu or section that holds it, or `scroll`. |
| `Element is off-screen: it is in a closed menu or panel, or is a screen-reader-only shortcut…` | You picked a hidden duplicate (a keyboard-shortcut list, a closed menu). Use the visible control; `snapshot` with `query` finds it on a long page. |
| `The editor did not take the text…` | The site's editor rejected typed input too. Snapshot; click into the editor first, or hand it to the user. |

## Blocked clicks and dialogs
| Error | What to do |
|---|---|
| `Element is obscured by <what>. Retry the click with dismiss:true…` | Repeat the same click with `dismiss: true`. |
| `…which has no close or decline button to use…` / `Element is still obscured by…` | Snapshot and deal with the layer yourself (its buttons are in the nodes). If it needs a choice only the user can make, ask. |
| `A page dialog is open (<type>: "<message>")…` | Answer with `dialog` (`accept: true` or `false`; `text` for a prompt). Accepting a delete, send or payment confirmation needs approval. |
| `No page dialog is open in this tab.` | It was already answered or closed; snapshot. |

## Typing and choosing
| Error | What to do |
|---|---|
| `Enter passwords, verification codes and payment details yourself.` | Hand this step to the user; say exactly what to enter where. |
| `No option matches. Options: …` | Use one of the listed option texts. |
| `Unsupported input type.` | Date pickers, sliders and similar: click the control and use what opens, or hand it to the user. A file field takes `upload`, not `fill`. |
| `Element is not an editable field.` / `Field is unavailable.` | Wrong ref, or the field is disabled until something else is filled. Snapshot. |
| `The page did not retain the entered text…` | The site's editor rejected the text. Snapshot; try clicking into the field first, or hand it to the user. |
| `Fill requires text of at most 20,000 characters.` | Shorten or split the text. |

## Files
| Error | What to do |
|---|---|
| `upload needs paths: 1 to 10 absolute file paths.` | Pass absolute paths (from your workspace or the user's folders); split bigger sets into several uploads. |
| `No file at <path>.` / `<path> is not a regular file; upload takes files.` / `<name> is larger than 100 MB.` | Check the path with your shell; zip a folder first; a file over 100 MB is the user's to upload. |
| `<path> is in a private place (keys, keychains, browser profiles or app settings), so it is never uploaded.` | Don't upload it or a copy of it. Tell the user if the task needs it. |
| `This file field takes one file.` | Upload one file, or one per field. |
| `No file chooser opened…` / `This is not a file field…` | Snapshot; use the file field itself, its label, or the page's own upload button. |
| `Chrome refused to give the file to the page…` | The user has to turn on "Allow access to file URLs" for HeyClicky once in `chrome://extensions`. Say so; don't retry. |
| `Only http(s) links can be downloaded…` / `This element has no link to download…` | Click the element instead; a file the page downloads comes back as `downloads`. |
| `The download failed (<reason>).` / `Chrome could not start the download…` | Say it failed and why; try once more only for a network error. |

## Waiting, tabs and calls
| Error | What to do |
|---|---|
| `Waited <n> s, but <what> did not appear` (`…The page is at <url>`) | Snapshot once to see why (an error message, a different page). Don't wait again for the same thing. |
| `There is no earlier page in this tab.` | Use `open {tabId, url}` instead. |
| `Only a tab this Clicky opened can be closed.` | It's the user's tab: leave it open. |
| `This tab belongs to another running Clicky…` | That Clicky is working there. Tell the user which one; use your own tab if the task allows. |
| `Only HTTP(S) pages without URL credentials are supported.` / `Private browsing is not supported.` | Browser settings, `chrome://`, files and incognito pages are off limits. |
| `Screenshot exceeds the transport limit. Use snapshot.` | Use the snapshot. |
| `Step N (<operation>) failed: …  Steps … did not run.` | Read the step's error above, then continue from the returned snapshot without re-running earlier steps. |
| `The batch ran out of time before step N.` | Continue from the returned snapshot with the remaining steps. |
| `Step N: a batch step can be …` / `batch needs …` / `Unsupported browser operation.` / `A tabId from tabs/open is required.` | Fix the call; nothing ran. |
