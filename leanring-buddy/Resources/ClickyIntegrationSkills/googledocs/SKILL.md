---
name: googledocs
description: Use when a task reads, creates or edits one of the user's Google Docs (read a doc, add text under a paragraph, create a new doc, fix wording in place). For local .docx files, use the shell instead.
---

# Google Docs

Docs tools run through the `composio` server.

## Find and read
- The doc id is the part of the URL between `/document/d/` and the next `/`. Don't pass the whole URL to tools that ask for `document_id`.
- Find by title: `GOOGLEDOCS_SEARCH_DOCUMENTS {query: "name contains 'words'"}`.
- Text only: `GOOGLEDOCS_GET_DOCUMENT_PLAINTEXT {document_id}`. With positions (needed before any edit): `GOOGLEDOCS_GET_DOCUMENT_BY_ID {id}`, whose `body.content[]` paragraphs each carry `startIndex` and `endIndex`.

## Add text without touching what's there
- To put new text right after a paragraph: find that paragraph in `GET_DOCUMENT_BY_ID`, then `GOOGLEDOCS_INSERT_TEXT_ACTION {document_id, insertion_index: <that paragraph's endIndex − 1>, text_to_insert: "\n\n<your text>"}`. Inserting at `endIndex − 1` (just before the paragraph's own newline) and starting with line breaks makes a new paragraph under it; use "\n\n" when the doc separates paragraphs with an empty line (most do), "\n" when it doesn't. Any other index lands inside someone else's sentence.
- To add at the end: `INSERT_TEXT_ACTION {document_id, append_to_end: true, text_to_insert}`.
- Don't use `GOOGLEDOCS_UPDATE_DOCUMENT_SECTION_MARKDOWN` for an insert: with a start index it can replace the existing text. Use it only when the user asked to replace a section, with both `start_index` and `end_index`.
- Changing wording in place: `GOOGLEDOCS_REPLACE_ALL_TEXT` for an exact phrase, or delete-and-insert a precise range. Never rewrite the whole doc to change one part.

## New doc
`GOOGLEDOCS_CREATE_DOCUMENT_MARKDOWN {title, markdown_text}`. The body goes in `markdown_text`, not `markdown`. A success response can still be a title-only doc, so check.

## Check before you say done
Read the doc back (`GET_DOCUMENT_PLAINTEXT`) and confirm your text is there, in the right place, and that the text around it is unchanged. Give the doc's link.
