#!/usr/bin/env python3
"""Print the T08 statistics objects for one edition (from stats_objects.sql.in).

    scripts/gen_stats_objects.py native    # pg_index_table_stats, pg_index_column_stats, pg_index_hints()
    scripts/gen_stats_objects.py sql       # index_deps.index_table_stats, ..._column_stats, index_hints()

The output is pasted into the version scripts (they must be self-contained).
"""
import pathlib
import sys

edition = sys.argv[1]
text = (pathlib.Path(__file__).parent / "stats_objects.sql.in").read_text()
if edition == "native":
    text = text.replace("@P@", "pg_index_").replace("@X@", "")
elif edition == "sql":
    text = text.replace("@P@", "index_deps.index_").replace("@X@", ", 'index_deps'")
else:
    sys.exit("usage: gen_stats_objects.py native|sql")
# Drop the template's own header comment (first paragraph).
sys.stdout.write(text.split("\n\n", 1)[1])
