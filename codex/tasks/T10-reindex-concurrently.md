# T10 — Keep an index's history across REINDEX CONCURRENTLY

**Status: done 27 Oct 2026** (native 0.9.1, with T09; library only).

## Why
`REINDEX CONCURRENTLY` builds a new index with a new OID, swaps it in under the old name and drops the old one. The native extension keys counters by OID, so routine maintenance (bloat cleanup) reset the index's history to zero, and "no recorded use" came back as if the index were new (guide limit #9).

## Spec
1. In the ProcessUtility hook, for every `ReindexStmt` (any form: INDEX, TABLE, SCHEMA, DATABASE, partitioned): before the command, flush this session's counts and record name + schema of every index tracked in the current database.
2. After the command succeeds: an index whose old OID no longer exists and whose name now resolves to a different OID was rebuilt; move its entries to the new OID (merge with entries already there: sum counts, min `first_seen`, max `last_seen`, OR column masks, AND `columns_complete`).
3. Plain `REINDEX` keeps the OID: nothing changes. `DROP INDEX` + `CREATE INDEX` with the same name is a new index: not carried over.
4. Never errors the user's command; if the REINDEX fails, nothing is moved.

## Known limits
- Other sessions' not-yet-flushed counts (≤ `flush_interval`) arrive under the old OID; the views ignore OIDs that no longer exist.
- `REINDEX SCHEMA/DATABASE CONCURRENTLY` that fails part-way commits the tables done so far, but nothing is moved for them.
- SQL edition unaffected: it matches plans by index name.

## Acceptance
Regression test `reindex`: one index, a whole table, a partitioned index (leaf indexes), column sets, counting after the move, plain REINDEX, DROP + CREATE. Tests pass on PG 15–18.
