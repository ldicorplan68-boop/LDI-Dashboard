SUPABASE INCREMENTAL COPIER v5.1 - INSERT ONLY
================================================

This version NEVER updates existing destination rows.

Allowed:
- CREATE missing custom schema
- CREATE missing custom table
- ADD missing column
- INSERT missing row

Forbidden:
- UPDATE existing row
- DELETE existing row
- DROP table
- DROP schema
- Replace existing row
- Replace existing values

Data matching:
1. If source and destination have the same primary key:
   - Existing PK = SKIP
   - Missing PK = INSERT
2. If no matching primary key:
   - Full-row hash comparison is used.
   - Identical rows are skipped.
   - Different/new rows are inserted.

Important:
- Existing destination rows are never changed.
- New columns are added without NOT NULL/default changes.
- Source laptop database is read-only.
- Supabase internal schemas are excluded.
- SSH password is requested once.

Run:
START_COPIER.bat
