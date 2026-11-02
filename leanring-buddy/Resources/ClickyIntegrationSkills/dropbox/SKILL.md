---
name: dropbox
description: Use when a task finds, reads, saves, organizes or links files in the user's Dropbox (find the PDF from last month, what's in a folder, save a report into a folder, rename or move files, get a link). Not for Google Drive, OneDrive or files already on this Mac.
---

# Dropbox

Dropbox tools run through the `composio` server.

## Paths
- Paths start with `/`, no trailing slash; the root is `""`, not `"/"` (`DROPBOX_GET_METADATA` rejects the root). Case-insensitive but copy the case.
- Reuse `path_display` / `path_lower` / `id` (`id:…`, survives renames) exactly as returned. Hand-typed paths cause `not_found` / 409; a malformed path can list as empty.

## Find and read
- Folder: `DROPBOX_LIST_FILES_IN_FOLDER {path, recursive: false}` → `entries`; while `has_more`, `DROPBOX_LIST_FOLDER_CONTINUE {cursor}`.
- Search: `DROPBOX_SEARCH_FILE_OR_FOLDER {query, options: {path, file_extensions: ["pdf"], order_by: "last_modified_time", max_results: 100}}` (names and content); while `has_more`, call again with `{cursor}` only. No date filter: filter on `server_modified` (UTC) in the user's zone. Fresh uploads may not be indexed: list the folder instead.
- Read: `DROPBOX_READ_FILE {path}` returns a file reference or base64: save/decode it before reading. Paper and cloud docs: `DROPBOX_EXPORT_FILE {path}` (text).
- Versions: `DROPBOX_LIST_FILE_REVISIONS {path, limit}`; `DROPBOX_RESTORE_FILE {path, rev}` overwrites the current file, only when asked.

## Save, move, rename
- `DROPBOX_UPLOAD_FILE {path: "/Reports/Q3 plan.pdf", content: {name, mimetype, s3key}}` (`s3key` = absolute local path, like Gmail attachments; under 150 MiB). Default `mode: "add"` fails on a name clash (identical content is a no-op); `autorename: true` quietly saves "name (2)"; `mode: "overwrite"` only when the user asked to replace. If the name exists, say so instead of reporting a save.
- `DROPBOX_CREATE_FOLDER {path}`: `path_conflict` means it exists, so use it. Don't pass `autorename` (makes a second folder).
- Rename and move are one call: `DROPBOX_MOVE_FILE_OR_FOLDER {from_path, to_path}` with the full new path including the name. A clash fails (leave `autorename` off). `allow_shared_folder` is ignored by Dropbox. Copy: `DROPBOX_COPY_FILE_OR_FOLDER`.

## Links and sharing (visible to other people)
- "Send me a link": reuse one first with `DROPBOX_LIST_SHARED_LINKS {path, direct_only: true}`. `DROPBOX_CREATE_SHARED_LINK {path, settings: {audience: "team", access: "viewer"}}` errors if a link exists; with no `settings` the link is public, so always set `audience`, and create one only when the user explicitly asked for a link. `DROPBOX_GET_TEMPORARY_LINK` is a 4-hour download URL, not a share.
- Never add members, delete, or revoke links unless asked; a folder delete takes its contents.

## Check before you say done
`DROPBOX_GET_METADATA {path}` on the result: name, folder, `server_modified`, nothing else renamed. Give the path (and link if asked). On a 429 wait `Retry-After` and go one write at a time; in a batched execute, read each call's own result.
