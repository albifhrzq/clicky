---
name: hubspot
description: Use when a task reads or changes the user's HubSpot CRM (look up a contact, company or deal, open deals closing this month, pipeline totals, log a note or call, create a follow-up task, move a deal to a stage). Not for sending email (use Gmail) or for other CRMs.
---

# HubSpot

HubSpot tools run through the `composio` server. Properties use internal names (`dealname`, `closedate`, `hubspot_owner_id`), never UI labels.

## Search (pages are small; fields are few)
- `HUBSPOT_SEARCH_CRM_OBJECTS_BY_CRITERIA {objectType: "deals", filterGroups, properties, sorts, limit: 100, after}`. The per-object wrappers (`HUBSPOT_SEARCH_DEALS` etc.) default to `limit: 5`, the generic one to 10: always set `limit` and follow `paging.next.after` until there's no `paging`. Never count or total from one page: save rows to `tmp/` and compute with a script.
- Only default properties come back; name every field you'll report (owner, custom) in `properties`.
- Filters in one group are AND; OR needs separate groups. `{propertyName, operator: "EQ"|"IN"|"BETWEEN"|"GTE"…, value | values | highValue}`. Linked: `{propertyName: "associations.contact", operator: "EQ", value: "<id>"}`. By id: `hs_object_id`.
- One record: `HUBSPOT_READ_CRM_OBJECT_BY_ID {objectType, objectId, properties, associations: ["contacts"]}`; a contact by email: `objectId: "<email>", idProperty: "email"`.
- Notes on a record: search `objectType: "notes"` with the `associations.contact` filter and `properties: ["hs_note_body","hs_timestamp"]` (the list-notes tools return ids only).

## Labels are not ids
- Stage: `HUBSPOT_RETRIEVE_ALL_PIPELINES_FOR_SPECIFIED_OBJECT_TYPE {objectType: "deals"}` → `HUBSPOT_RETRIEVE_PIPELINE_STAGES {objectType, pipelineId}`; use the stage `id` from the deal's own pipeline (labels repeat across pipelines).
- Owner: `HUBSPOT_RETRIEVE_OWNERS {}` → owner `id` for `hubspot_owner_id` (not a user id or email). Enum values: `HUBSPOT_READ_A_CRM_PROPERTY_BY_NAME` → `options[].value`.
- Dates: filters take epoch-millisecond strings. Compute "this month" in the user's time zone, convert bounds to UTC ms; date-only properties sit at midnight UTC.

## Write
- `HUBSPOT_UPDATE_DEAL {dealId, properties: {dealstage, amount, closedate}}`; other objects: `HUBSPOT_PARTIALLY_UPDATE_CRM_OBJECT_BY_ID {objectType, objectId, properties}`. Only named properties change.
- `HUBSPOT_CREATE_DEAL {dealname, pipeline, dealstage, …}` takes properties as top-level args.
- `HUBSPOT_CREATE_NOTE {hs_timestamp, hs_note_body, associations}` / `HUBSPOT_CREATE_TASK {hs_timestamp (the due date), hs_task_subject, associations: [{to__id: "<id>", types: [{associationCategory: "HUBSPOT_DEFINED", associationTypeId: 216}]}]}`. Type ids: note→contact 202, →deal 214; task→contact 204, →deal 216, →company 192. No associations = unattached.
- These log activity; they send nothing. Setting `hubspot_owner_id` to someone else can notify them: only when asked. Never archive, merge or delete records unless asked.

## Check before you say done
Search lags a few seconds: verify by reading the record by id, with the properties and associations you set. Link the record.
