---
name: salesforce
description: Use when a task reads or changes the user's Salesforce (pipeline and deal totals, an account's contacts or open tasks, move a deal's stage, log a call, add a follow-up task or note, create a lead). Not for Gmail/Calendar mail or meetings outside Salesforce.
---

# Salesforce

Salesforce tools run through the `composio` server.

## Read with SOQL
- `SALESFORCE_RUN_SOQL_QUERY {query}`: `SELECT Id, Name, StageName, Amount, CloseDate, Owner.Name, Account.Name FROM Opportunity WHERE IsClosed = false AND CloseDate = THIS_QUARTER`. API names, not labels (custom end `__c`, their lookups `__r.Name`); unsure → `SALESFORCE_GET_ALL_FIELDS_FOR_OBJECT {object_name}`. Strings and ids in single quotes (`O\'Brien`), `LIKE '%plan%'`; dates unquoted. No `AS`: `SUM(Amount) total, COUNT(Id) n ... GROUP BY StageName`. Children: `(SELECT LastName, Email FROM Contacts)`. Read `composio_execution_message` (notes any rewrite of your query).
- Paging: `done: false` → `SALESFORCE_QUERY_MORE {next_records_url}` (pass `nextRecordsUrl` as returned) until `done: true`. The `SALESFORCE_SEARCH_*` tools return 50 by default and partial-match names (look-alikes); set `limit` and confirm the one record. Never count or total by eye: page to the end, save rows to `tmp/`, compute with a script, say how many you covered.
- Empty can mean the user can't see those records.

## Dates and time zones
Date literals (`TODAY`, `THIS_WEEK`, `THIS_QUARTER`, `LAST_N_DAYS:7` incl. today, `NEXT_N_DAYS:n`) resolve in the Salesforce user's time zone; datetimes come back UTC. `CloseDate`/`ActivityDate` are dates (`= 2030-03-03`); `CreatedDate`/`LastModifiedDate` need a full datetime with offset (`>= 2030-03-03T00:00:00-05:00`) built from the user's zone, not bare UTC midnight. Convert returned datetimes before saying "yesterday".

## Write (only what was asked)
- Deal: `SALESFORCE_UPDATE_OPPORTUNITY {opportunity_id, stage_name?, amount?, close_date?, next_step?}`. `stage_name` is the stored value valid for that record's record type: check `SALESFORCE_GET_PICKLIST_VALUES_BY_RECORD_TYPE {sobject_api_name, record_type_id}` (its `RecordTypeId`). `""` means "unchanged", so to clear a field use `SALESFORCE_SOBJECT_ROWS_UPDATE {sobject_api_name, record_id, fields: {NextStep: null}}`.
- Task: `SALESFORCE_CREATE_TASK {subject, who_id, what_id, activity_date: "2030-03-03"}`. `who_id` = person (Contact `003`, Lead `00Q`); `what_id` = Account `001`, Opportunity `006`, Case `500`. Call done: `SALESFORCE_LOG_CALL {who_id, what_id, comments, call_date}`. Note: `SALESFORCE_CREATE_NOTE {parent_id, title, body}` (no dedupe: don't retry blindly).
- Lead: `SALESFORCE_CREATE_LEAD {LastName, Company, ...}` (PascalCase); contact: `SALESFORCE_CREATE_CONTACT {last_name, account_id}`.
- Email: `SALESFORCE_SEND_EMAIL` sends at once, only after the user approved that exact draft (recipients, subject and body); otherwise draft the text. `SALESFORCE_LOG_EMAIL_ACTIVITY` only records one. Never delete, reassign owners or add to campaigns unless asked.

## Check before you say done
Read back by id (`SALESFORCE_GET_OPPORTUNITY {opportunity_id}` or `SELECT ... WHERE Id = '...'`) and confirm the field, links (WhoId/WhatId) and date.
