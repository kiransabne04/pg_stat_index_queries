-- Index lab: markdown report, CSV of results and plan fixtures, written to
-- the client's current directory (run.sh runs psql from the output folder).
-- The report only quotes statements tagged /* lab:... */ (synthetic).

\echo '=== report'
-- What to do about each kind of failure; matched on case_id prefix.
CREATE TABLE lab.advice (prefix text PRIMARY KEY, advice text NOT NULL);
INSERT INTO lab.advice VALUES
 ('A-',  'Compare the plan text (fixture files) with the parser regex in index_deps.plan_index_usage; a node type or quoting form it does not handle is the usual cause.'),
 ('A-W35', 'Nested statements need pg_stat_statements.track = all (parameter group on RDS/Aurora). Document, or read nested plans when the plan source has them.'),
 ('U-',  'An index wrongly listed as unused is the worst outcome (someone drops it). Trace which query used it and why the plan text did not resolve to it.'),
 ('U-lab.life_renamed_idx_v2', 'Plan text stores names. Options: warn when a plan names an index that no longer exists ("unresolved"), and exclude indexes renamed after the plan source''s reset time from the unused list.'),
 ('U-lab_b.amb_v_idx', 'Safe direction (kept, not dropped). Could disambiguate with the table schema when the plan names a table that exists in one schema only.'),
 ('D-cancel-unhide', 'QUERY_CANCELED is not caught by WHEN OTHERS. Unhide in an outer handler that catches query_canceled and re-raises, or hide/unhide around each EXPLAIN in its own block.'),
 ('D-timeout-param', 'statement_timeout set inside a function does not re-arm the timer for statements already running. Use a per-EXPLAIN check or document that p_timeout_ms is advisory.'),
 ('D-read-only', 'The function creates a temp table, which a read-only transaction or hot standby refuses. Collect candidates into an array or CTE instead so it runs on readers.'),
 ('D-leading-comment', 'Strip leading /* ... */ and -- comments before the read-query check and before EXPLAIN.'),
 ('D-hypothetical', 'Warn (or refuse) when hypopg_list_indexes() is non-empty, or reset/skip hypothetical indexes for the duration of the call.'),
 ('D-view', 'Without a plan source the fallback matches the table name in query text; queries through views, functions or synonyms are missed. Document, or also match views that depend on the table.'),
 ('E-unprivileged', 'Grant what an analyst role needs (SELECT on index_deps.config, EXECUTE on functions) or document the minimum grants.'),
 ('Q-',  'Check index_deps.index_query_stats against pg_stat_statements for the same queryid.');

\pset format unaligned
\pset tuples_only on
\o report.md
SELECT concat_ws(E'\n',
  '# Index lab report: ' || (SELECT v FROM lab.env WHERE k = 'label'),
  '',
  'Synthetic workload (schema `lab`, database `index_lab`). Ground truth: the EXPLAIN plan of each workload statement, captured in the same session right after it ran' ||
    CASE WHEN EXISTS (SELECT 1 FROM lab.env WHERE k = 'native pg_stat_index_queries (ground truth)' AND v IS NOT NULL)
         THEN ', cross-checked with the native extension''s executed counts.' ELSE '.' END,
  '',
  '## Summary',
  '',
  lab.md($q$
    SELECT status,
           count(*) AS cases,
           count(*) FILTER (WHERE severity = 'critical') AS critical,
           count(*) FILTER (WHERE severity = 'high') AS high,
           count(*) FILTER (WHERE severity = 'medium') AS medium,
           count(*) FILTER (WHERE severity IN ('low', 'info')) AS "low/info"
      FROM lab.results GROUP BY status
     ORDER BY array_position(ARRAY['FAIL','KNOWN','PASS','INFO','SKIP'], status)
  $q$),
  '## Findings (FAIL first, then KNOWN limitations)',
  '',
  lab.md($q$
    SELECT r.case_id AS "case", r.severity, r.status, r.title, r.expected, r.actual, r.detail,
           (SELECT a.advice FROM lab.advice a WHERE r.case_id LIKE a.prefix || '%'
             ORDER BY length(a.prefix) DESC LIMIT 1) AS "next step"
      FROM lab.results r
     WHERE r.status IN ('FAIL', 'KNOWN') AND r.area <> 'native'
     ORDER BY r.status, array_position(ARRAY['critical','high','medium','low','info'], r.severity), r.ord
  $q$),
  '## Environment',
  '',
  lab.md($q$ SELECT k AS setting, v AS value FROM lab.env ORDER BY k $q$),
  '## Which indexes each query used',
  '',
  'truth = EXPLAIN of the executed statements; sql_edition = `index_deps.index_dependents`; native = `pg_stat_index_queries` (self-hosted only).',
  '',
  lab.md($q$
    SELECT tag, title, match,
           array_to_string(truth_idx, ', ') AS truth,
           array_to_string(tool_idx, ', ') AS sql_edition,
           array_to_string(native_idx, ', ') AS native,
           pgss_calls AS calls, tool_calls AS "calls credited"
      FROM lab.attribution ORDER BY tag
  $q$),
  '## Drop impact rows',
  '',
  CASE WHEN to_regclass('lab.di') IS NULL THEN '_(drop-impact checks skipped)_' || E'\n' ELSE
  lab.md($q$
    SELECT target, coalesce(tag, '-') AS tag, calls, cost_ratio, uses_index_now AS now, uses_index_after AS after,
           plan_changed AS changed, left(note, 160) AS note
      FROM lab.di WHERE tag IS NOT NULL OR note LIKE '(no row%'
     ORDER BY target, calls DESC NULLS LAST
  $q$) END,
  '## All checks',
  '',
  lab.md($q$
    SELECT case_id AS "case", area, severity, status, title, expected, actual
      FROM lab.results ORDER BY ord
  $q$),
  '## Feedback',
  '',
  coalesce((
    SELECT string_agg(format('- **[%s] %s** %s: expected `%s`, got `%s`.%s',
                             r.severity, r.case_id, r.title, coalesce(r.expected, ''), coalesce(r.actual, ''),
                             coalesce(' ' || (SELECT a.advice FROM lab.advice a WHERE r.case_id LIKE a.prefix || '%'
                                               ORDER BY length(a.prefix) DESC LIMIT 1), '')),
                      E'\n' ORDER BY array_position(ARRAY['critical','high','medium','low','info'], r.severity), r.ord)
      FROM lab.results r WHERE r.status = 'FAIL' AND r.area <> 'native'),
    '- No failures.'),
  '',
  coalesce((
    SELECT 'Native extension disagreed with EXPLAIN on: ' || string_agg(case_id, ', ' ORDER BY ord) ||
           ' (see All checks; usually a plan EXPLAIN cannot reproduce, e.g. a generic plan).'
      FROM lab.results WHERE area = 'native' AND status = 'FAIL'), ''),
  ''
);
\o

-- Results as CSV.
\pset format aligned
\pset tuples_only off
\o results.csv
COPY (SELECT * FROM lab.results ORDER BY ord) TO STDOUT WITH (FORMAT csv, HEADER);
\o

-- Plan fixtures for the lab's statements (to add real plan text to the tests).
SELECT to_regprocedure('aurora_stat_plans(boolean)') IS NOT NULL AS has_asp \gset
\if :has_asp
\o aurora_stat_plans_raw.jsonl
COPY (SELECT to_jsonb(s) FROM aurora_stat_plans(true) s
       WHERE s.queryid IN (SELECT queryid FROM lab.tag_map())) TO STDOUT;
\o
\o aurora_fixture.csv
COPY (SELECT tm.tag, s.queryid, s.planid, s.calls, s.explain_plan
        FROM aurora_stat_plans(true) s JOIN lab.tag_map() tm ON tm.queryid = s.queryid
       ORDER BY tm.tag, s.planid) TO STDOUT WITH (FORMAT csv, HEADER);
\o
\echo 'wrote aurora_stat_plans_raw.jsonl and aurora_fixture.csv'
\endif
\o plan_fixture.csv
COPY (SELECT tm.tag, p.queryid, p.planid, p.calls, p.source, p.plan_text
        FROM index_deps.plan_source() p JOIN lab.tag_map() tm ON tm.queryid = p.queryid
       ORDER BY tm.tag, p.planid) TO STDOUT WITH (FORMAT csv, HEADER);
\o

\echo 'wrote report.md, results.csv, plan_fixture.csv'
SELECT status, severity, count(*) FROM lab.results GROUP BY 1, 2
 ORDER BY array_position(ARRAY['FAIL','KNOWN','PASS','INFO','SKIP'], status),
          array_position(ARRAY['critical','high','medium','low','info'], severity);
