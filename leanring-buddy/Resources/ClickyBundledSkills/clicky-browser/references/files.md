# Files: downloads and uploads

## Downloading
- `download {url}` (or `{tabId, ref}` of a link) saves an http(s) file to `Downloads/HeyClicky/<task>/` under the site's file name and returns its `path`, `bytes` and `mime` once it has finished. A file still arriving comes back with `state: "in_progress"`; a later result reports it again.
- A click that makes the page download something (an attachment, an "Export" button) needs no extra step: the file comes back as `downloads` in that call's result or the next one. Don't click again to "make sure".
- The file is on the user's Mac and your shell can read it. A deliverable goes into your workspace like any file a tool saved elsewhere (the YOUR FILES rule): copy it into `output/` and answer with that path.
- A `note` saying Chrome is holding the file as possibly harmful means only the user can keep it; tell them, don't look for a way around it. Never open or run a downloaded program or installer.

## Uploading
- `upload {tabId, ref, paths}` takes absolute paths (up to 10 files, 100 MB each) and the ref of the file field, its label, or the page's own "Upload" / "Attach" button. No file dialog appears. It also works as a batch step, so a form with an attachment is still one call.
- HeyClicky checks the paths first and refuses private places (keys, keychains, `.env` and key files, browser profiles, the app's own settings). Don't look for another route to those files.
- Whether to ask first is the approval list's call: `references/confirmations.md`.
