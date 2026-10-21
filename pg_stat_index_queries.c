/*-------------------------------------------------------------------------
 *
 * pg_stat_index_queries.c
 *		Track which normalized queries (query IDs) actually use each index.
 *
 * At ExecutorEnd the executed PlanState tree is walked. Every index scan,
 * index-only scan and bitmap index scan node contributes its index OID.
 * Counters are kept in a shared hash keyed by
 * (dbid, indexrelid, queryid, toplevel), in the style of
 * pg_stat_statements.
 *
 * Supported: PostgreSQL 15, 16, 17, 18.
 *
 * Copyright (c) 2026, Kiran Sabne
 * Released under the PostgreSQL License.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/parallel.h"
#include "access/transam.h"
#include "catalog/pg_type.h"
#include "executor/executor.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/execnodes.h"
#include "nodes/nodeFuncs.h"
#include "nodes/plannodes.h"
#include "nodes/queryjumble.h"
#include "pgstat.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "storage/spin.h"
#include "tcop/utility.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/timestamp.h"

#include <unistd.h>

PG_MODULE_MAGIC;

#define PGSIQ_TRANCHE_NAME		"pg_stat_index_queries"
#define PGSIQ_DEALLOC_PERCENT	5
#define PGSIQ_MAX_INDEXES_PER_STMT	64

/* Persistence across clean restarts (same approach as pg_stat_statements). */
#define PGSIQ_DUMP_FILE		PGSTAT_STAT_PERMANENT_DIRECTORY "/pg_stat_index_queries.stat"
#define PGSIQ_FILE_HEADER	0x51495301	/* "SIQ" + format version 1 */
#define PGSIQ_PG_MAJOR		(PG_VERSION_NUM / 100)

/* ---------- shared structures ---------- */

typedef struct pgsiqHashKey
{
	Oid			dbid;
	Oid			indexrelid;
	uint64		queryid;
	bool		toplevel;
} pgsiqHashKey;

typedef struct pgsiqEntry
{
	pgsiqHashKey key;			/* must be first */
	slock_t		mutex;			/* protects counters below */
	int64		calls_executed;
	int64		calls_planned;
	TimestampTz first_seen;
	TimestampTz last_seen;
} pgsiqEntry;

typedef struct pgsiqSharedState
{
	LWLock	   *lock;			/* protects hash table search/modification */
	slock_t		mutex;			/* protects fields below */
	int64		dealloc;
	TimestampTz stats_reset;
} pgsiqSharedState;

/* One index seen in the current statement */
typedef struct pgsiqSeenIndex
{
	Oid			indexrelid;
	bool		executed;
} pgsiqSeenIndex;

typedef struct pgsiqWalkContext
{
	int			nseen;
	bool		overflow;
	pgsiqSeenIndex seen[PGSIQ_MAX_INDEXES_PER_STMT];
} pgsiqWalkContext;

/* ---------- GUCs ---------- */

typedef enum
{
	PGSIQ_TRACK_NONE,
	PGSIQ_TRACK_TOP,
	PGSIQ_TRACK_ALL
} PGSIQTrackLevel;

static const struct config_enum_entry track_options[] =
{
	{"none", PGSIQ_TRACK_NONE, false},
	{"top", PGSIQ_TRACK_TOP, false},
	{"all", PGSIQ_TRACK_ALL, false},
	{NULL, 0, false}
};

static int	pgsiq_max = 10000;
static int	pgsiq_track = PGSIQ_TRACK_TOP;
static bool pgsiq_track_catalog = false;
static bool pgsiq_save = true;

/* ---------- state ---------- */

static int	nesting_level = 0;
static pgsiqSharedState *pgsiq = NULL;
static HTAB *pgsiq_hash = NULL;

static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;
static ExecutorRun_hook_type prev_ExecutorRun = NULL;
static ExecutorFinish_hook_type prev_ExecutorFinish = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;
static ProcessUtility_hook_type prev_ProcessUtility = NULL;

#define pgsiq_enabled(level) \
	(!IsParallelWorker() && \
	 (pgsiq_track == PGSIQ_TRACK_ALL || \
	  (pgsiq_track == PGSIQ_TRACK_TOP && (level) == 0)))

/* ---------- prototypes ---------- */

void		_PG_init(void);

static void pgsiq_shmem_request(void);
static void pgsiq_shmem_startup(void);
#if PG_VERSION_NUM >= 180000
static void pgsiq_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction,
							  uint64 count);
#else
static void pgsiq_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction,
							  uint64 count, bool execute_once);
#endif
static void pgsiq_ExecutorFinish(QueryDesc *queryDesc);
static void pgsiq_ExecutorEnd(QueryDesc *queryDesc);
static void pgsiq_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
								 bool readOnlyTree,
								 ProcessUtilityContext context,
								 ParamListInfo params,
								 QueryEnvironment *queryEnv,
								 DestReceiver *dest, QueryCompletion *qc);
static Size pgsiq_memsize(void);
static bool pgsiq_walker(PlanState *planstate, void *context);
static void pgsiq_store(pgsiqWalkContext *ctx, uint64 queryid, bool toplevel);
static void entry_dealloc(void);
static void pgsiq_shmem_shutdown(int code, Datum arg);
static void pgsiq_load_file(void);

PG_FUNCTION_INFO_V1(pg_stat_index_queries);
PG_FUNCTION_INFO_V1(pg_stat_index_queries_reset);
PG_FUNCTION_INFO_V1(pg_stat_index_queries_info);

/* ---------- module load ---------- */

void
_PG_init(void)
{
	/* Shared memory is only available when preloaded. */
	if (!process_shared_preload_libraries_in_progress)
		return;

	/* Make sure query IDs are computed when compute_query_id = auto. */
	EnableQueryId();

	DefineCustomIntVariable("pg_stat_index_queries.max",
							"Maximum number of (index, query) entries tracked.",
							NULL,
							&pgsiq_max,
							10000,
							100,
							INT_MAX / 2,
							PGC_POSTMASTER,
							0,
							NULL, NULL, NULL);

	DefineCustomEnumVariable("pg_stat_index_queries.track",
							 "Which statements are tracked: none, top or all (nested too).",
							 NULL,
							 &pgsiq_track,
							 PGSIQ_TRACK_TOP,
							 track_options,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_stat_index_queries.track_catalog",
							 "Also track indexes on system catalogs.",
							 NULL,
							 &pgsiq_track_catalog,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_stat_index_queries.save",
							 "Save counters across server restarts.",
							 NULL,
							 &pgsiq_save,
							 true,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	MarkGUCPrefixReserved("pg_stat_index_queries");

	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = pgsiq_shmem_request;
	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = pgsiq_shmem_startup;
	prev_ExecutorRun = ExecutorRun_hook;
	ExecutorRun_hook = pgsiq_ExecutorRun;
	prev_ExecutorFinish = ExecutorFinish_hook;
	ExecutorFinish_hook = pgsiq_ExecutorFinish;
	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = pgsiq_ExecutorEnd;
	prev_ProcessUtility = ProcessUtility_hook;
	ProcessUtility_hook = pgsiq_ProcessUtility;
}

/* ---------- shared memory ---------- */

static Size
pgsiq_memsize(void)
{
	Size		size;

	size = MAXALIGN(sizeof(pgsiqSharedState));
	size = add_size(size, hash_estimate_size(pgsiq_max, sizeof(pgsiqEntry)));
	return size;
}

static void
pgsiq_shmem_request(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();

	RequestAddinShmemSpace(pgsiq_memsize());
	RequestNamedLWLockTranche(PGSIQ_TRANCHE_NAME, 1);
}

static void
pgsiq_shmem_startup(void)
{
	bool		found;
	HASHCTL		info;

	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	pgsiq = NULL;
	pgsiq_hash = NULL;

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	pgsiq = ShmemInitStruct("pg_stat_index_queries",
							sizeof(pgsiqSharedState),
							&found);
	if (!found)
	{
		pgsiq->lock = &(GetNamedLWLockTranche(PGSIQ_TRANCHE_NAME))->lock;
		SpinLockInit(&pgsiq->mutex);
		pgsiq->dealloc = 0;
		pgsiq->stats_reset = GetCurrentTimestamp();
	}

	info.keysize = sizeof(pgsiqHashKey);
	info.entrysize = sizeof(pgsiqEntry);
	pgsiq_hash = ShmemInitHash("pg_stat_index_queries hash",
							   pgsiq_max, pgsiq_max,
							   &info,
							   HASH_ELEM | HASH_BLOBS);

	LWLockRelease(AddinShmemInitLock);

	/* The postmaster saves the counters at clean shutdown. */
	if (!IsUnderPostmaster)
		on_shmem_exit(pgsiq_shmem_shutdown, (Datum) 0);

	/* Load saved counters only when shared memory is freshly created. */
	if (!found)
		pgsiq_load_file();
}

/* ---------- persistence ---------- */

/*
 * File layout: header, PG major, entry count, dealloc, stats_reset, then
 * entry_count records of (key, calls_executed, calls_planned, first_seen,
 * last_seen). Any mismatch or short read discards the whole file.
 */
static void
pgsiq_load_file(void)
{
	FILE	   *file;
	uint32		header;
	int32		pgmajor;
	int64		count;
	int64		dealloc;
	TimestampTz stats_reset;
	int64		i;

	file = AllocateFile(PGSIQ_DUMP_FILE, PG_BINARY_R);
	if (file == NULL)
	{
		if (errno != ENOENT)
			ereport(LOG,
					(errcode_for_file_access(),
					 errmsg("could not read file \"%s\": %m", PGSIQ_DUMP_FILE)));
		return;
	}

	if (fread(&header, sizeof(uint32), 1, file) != 1 ||
		fread(&pgmajor, sizeof(int32), 1, file) != 1 ||
		fread(&count, sizeof(int64), 1, file) != 1 ||
		fread(&dealloc, sizeof(int64), 1, file) != 1 ||
		fread(&stats_reset, sizeof(TimestampTz), 1, file) != 1)
		goto bad_file;

	if (header != PGSIQ_FILE_HEADER || pgmajor != PGSIQ_PG_MAJOR || count < 0)
		goto bad_file;

	for (i = 0; i < count; i++)
	{
		pgsiqEntry	temp;
		pgsiqEntry *entry;
		bool		found;

		if (fread(&temp.key, sizeof(pgsiqHashKey), 1, file) != 1 ||
			fread(&temp.calls_executed, sizeof(int64), 1, file) != 1 ||
			fread(&temp.calls_planned, sizeof(int64), 1, file) != 1 ||
			fread(&temp.first_seen, sizeof(TimestampTz), 1, file) != 1 ||
			fread(&temp.last_seen, sizeof(TimestampTz), 1, file) != 1)
			goto bad_file;

		/* Never exceed the configured size; drop the remainder. */
		if (hash_get_num_entries(pgsiq_hash) >= pgsiq_max)
			break;

		entry = (pgsiqEntry *) hash_search(pgsiq_hash, &temp.key,
										   HASH_ENTER, &found);
		if (!found)
			SpinLockInit(&entry->mutex);
		entry->calls_executed = temp.calls_executed;
		entry->calls_planned = temp.calls_planned;
		entry->first_seen = temp.first_seen;
		entry->last_seen = temp.last_seen;
	}

	pgsiq->dealloc = dealloc;
	pgsiq->stats_reset = stats_reset;

	FreeFile(file);

	/* Remove the file so a later crash doesn't reload stale counters. */
	unlink(PGSIQ_DUMP_FILE);
	return;

bad_file:
	ereport(LOG,
			(errmsg("ignoring invalid pg_stat_index_queries file \"%s\"",
					PGSIQ_DUMP_FILE)));
	FreeFile(file);
	unlink(PGSIQ_DUMP_FILE);

	/* Start clean: drop anything partially loaded. */
	{
		HASH_SEQ_STATUS hash_seq;
		pgsiqEntry *entry;

		hash_seq_init(&hash_seq, pgsiq_hash);
		while ((entry = hash_seq_search(&hash_seq)) != NULL)
			hash_search(pgsiq_hash, &entry->key, HASH_REMOVE, NULL);
	}
}

static void
pgsiq_shmem_shutdown(int code, Datum arg)
{
	FILE	   *file;
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry *entry;
	uint32		header = PGSIQ_FILE_HEADER;
	int32		pgmajor = PGSIQ_PG_MAJOR;
	int64		count;

	/* Don't save after a crash, or if shared memory was never set up. */
	if (code != 0 || !pgsiq || !pgsiq_hash)
		return;

	if (!pgsiq_save)
	{
		unlink(PGSIQ_DUMP_FILE);
		return;
	}

	file = AllocateFile(PGSIQ_DUMP_FILE ".tmp", PG_BINARY_W);
	if (file == NULL)
		goto error;

	count = hash_get_num_entries(pgsiq_hash);

	if (fwrite(&header, sizeof(uint32), 1, file) != 1 ||
		fwrite(&pgmajor, sizeof(int32), 1, file) != 1 ||
		fwrite(&count, sizeof(int64), 1, file) != 1 ||
		fwrite(&pgsiq->dealloc, sizeof(int64), 1, file) != 1 ||
		fwrite(&pgsiq->stats_reset, sizeof(TimestampTz), 1, file) != 1)
		goto error;

	hash_seq_init(&hash_seq, pgsiq_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		if (fwrite(&entry->key, sizeof(pgsiqHashKey), 1, file) != 1 ||
			fwrite(&entry->calls_executed, sizeof(int64), 1, file) != 1 ||
			fwrite(&entry->calls_planned, sizeof(int64), 1, file) != 1 ||
			fwrite(&entry->first_seen, sizeof(TimestampTz), 1, file) != 1 ||
			fwrite(&entry->last_seen, sizeof(TimestampTz), 1, file) != 1)
		{
			hash_seq_term(&hash_seq);
			goto error;
		}
	}

	if (FreeFile(file))
	{
		file = NULL;
		goto error;
	}

	(void) durable_rename(PGSIQ_DUMP_FILE ".tmp", PGSIQ_DUMP_FILE, LOG);
	return;

error:
	ereport(LOG,
			(errcode_for_file_access(),
			 errmsg("could not write file \"%s\": %m", PGSIQ_DUMP_FILE ".tmp")));
	if (file)
		FreeFile(file);
	unlink(PGSIQ_DUMP_FILE ".tmp");
}

/* ---------- executor hooks (nesting level tracking) ---------- */

#if PG_VERSION_NUM >= 180000
static void
pgsiq_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count)
#else
static void
pgsiq_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count,
				  bool execute_once)
#endif
{
	nesting_level++;
	PG_TRY();
	{
#if PG_VERSION_NUM >= 180000
		if (prev_ExecutorRun)
			prev_ExecutorRun(queryDesc, direction, count);
		else
			standard_ExecutorRun(queryDesc, direction, count);
#else
		if (prev_ExecutorRun)
			prev_ExecutorRun(queryDesc, direction, count, execute_once);
		else
			standard_ExecutorRun(queryDesc, direction, count, execute_once);
#endif
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();
}

static void
pgsiq_ExecutorFinish(QueryDesc *queryDesc)
{
	nesting_level++;
	PG_TRY();
	{
		if (prev_ExecutorFinish)
			prev_ExecutorFinish(queryDesc);
		else
			standard_ExecutorFinish(queryDesc);
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();
}

static void
pgsiq_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
					 bool readOnlyTree,
					 ProcessUtilityContext context,
					 ParamListInfo params, QueryEnvironment *queryEnv,
					 DestReceiver *dest, QueryCompletion *qc)
{
	Node	   *parsetree = pstmt->utilityStmt;
	bool		bump;

	/*
	 * Statements run inside a utility command (DO blocks, CALL, EXPLAIN
	 * ANALYZE, CREATE TABLE AS ...) count as nested, not top level. EXECUTE
	 * and PREPARE are the exception, as in pg_stat_statements: the prepared
	 * query is the user's top-level statement.
	 */
	bump = !(IsA(parsetree, ExecuteStmt) || IsA(parsetree, PrepareStmt));

	if (!bump)
	{
		if (prev_ProcessUtility)
			prev_ProcessUtility(pstmt, queryString, readOnlyTree, context,
								params, queryEnv, dest, qc);
		else
			standard_ProcessUtility(pstmt, queryString, readOnlyTree, context,
									params, queryEnv, dest, qc);
		return;
	}

	nesting_level++;
	PG_TRY();
	{
		if (prev_ProcessUtility)
			prev_ProcessUtility(pstmt, queryString, readOnlyTree, context,
								params, queryEnv, dest, qc);
		else
			standard_ProcessUtility(pstmt, queryString, readOnlyTree, context,
									params, queryEnv, dest, qc);
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();
}

/* ---------- plan walk + capture ---------- */

static void
remember_index(pgsiqWalkContext *ctx, Oid indexrelid, bool executed)
{
	int			i;

	if (!pgsiq_track_catalog && indexrelid < FirstNormalObjectId)
		return;

	for (i = 0; i < ctx->nseen; i++)
	{
		if (ctx->seen[i].indexrelid == indexrelid)
		{
			ctx->seen[i].executed |= executed;
			return;
		}
	}

	if (ctx->nseen >= PGSIQ_MAX_INDEXES_PER_STMT)
	{
		ctx->overflow = true;
		return;
	}

	ctx->seen[ctx->nseen].indexrelid = indexrelid;
	ctx->seen[ctx->nseen].executed = executed;
	ctx->nseen++;
}

static bool
pgsiq_walker(PlanState *planstate, void *context)
{
	pgsiqWalkContext *ctx = (pgsiqWalkContext *) context;

	if (planstate == NULL)
		return false;

	switch (nodeTag(planstate))
	{
		case T_IndexScanState:
			{
				IndexScanState *s = (IndexScanState *) planstate;

				/* index_beginscan() runs lazily on first fetch */
				remember_index(ctx,
							   ((IndexScan *) planstate->plan)->indexid,
							   s->iss_ScanDesc != NULL);
				break;
			}
		case T_IndexOnlyScanState:
			{
				IndexOnlyScanState *s = (IndexOnlyScanState *) planstate;

				remember_index(ctx,
							   ((IndexOnlyScan *) planstate->plan)->indexid,
							   s->ioss_ScanDesc != NULL);
				break;
			}
		case T_BitmapIndexScanState:
			{
				/*
				 * The scan descriptor is created at executor init, so we
				 * cannot tell whether it actually ran. Counted as executed;
				 * documented as approximate.
				 */
				remember_index(ctx,
							   ((BitmapIndexScan *) planstate->plan)->indexid,
							   true);
				break;
			}
		default:
			break;
	}

	return planstate_tree_walker(planstate, pgsiq_walker, context);
}

static void
pgsiq_store(pgsiqWalkContext *ctx, uint64 queryid, bool toplevel)
{
	TimestampTz now = GetCurrentTimestamp();
	int			i;

	LWLockAcquire(pgsiq->lock, LW_SHARED);

	for (i = 0; i < ctx->nseen; i++)
	{
		pgsiqHashKey key;
		pgsiqEntry *entry;

		memset(&key, 0, sizeof(key));
		key.dbid = MyDatabaseId;
		key.indexrelid = ctx->seen[i].indexrelid;
		key.queryid = queryid;
		key.toplevel = toplevel;

		entry = (pgsiqEntry *) hash_search(pgsiq_hash, &key, HASH_FIND, NULL);

		if (!entry)
		{
			bool		found;

			/* Need exclusive lock to insert. */
			LWLockRelease(pgsiq->lock);
			LWLockAcquire(pgsiq->lock, LW_EXCLUSIVE);

			if (hash_get_num_entries(pgsiq_hash) >= pgsiq_max)
				entry_dealloc();

			entry = (pgsiqEntry *) hash_search(pgsiq_hash, &key,
											   HASH_ENTER, &found);
			if (!found)
			{
				SpinLockInit(&entry->mutex);
				entry->calls_executed = 0;
				entry->calls_planned = 0;
				entry->first_seen = now;
				entry->last_seen = now;
			}

			LWLockRelease(pgsiq->lock);
			LWLockAcquire(pgsiq->lock, LW_SHARED);

			/* Re-find: the entry may have been evicted meanwhile. */
			entry = (pgsiqEntry *) hash_search(pgsiq_hash, &key,
											   HASH_FIND, NULL);
			if (!entry)
				continue;
		}

		SpinLockAcquire(&entry->mutex);
		entry->calls_planned++;
		if (ctx->seen[i].executed)
			entry->calls_executed++;
		entry->last_seen = now;
		SpinLockRelease(&entry->mutex);
	}

	LWLockRelease(pgsiq->lock);
}

static void
pgsiq_ExecutorEnd(QueryDesc *queryDesc)
{
	uint64		queryid = (uint64) queryDesc->plannedstmt->queryId;

	if (pgsiq && queryid != UINT64CONST(0) &&
		queryDesc->planstate != NULL &&
		pgsiq_enabled(nesting_level))
	{
		pgsiqWalkContext ctx;

		ctx.nseen = 0;
		ctx.overflow = false;

		/* planstate_tree_walker() skips the root node; visit it ourselves. */
		pgsiq_walker(queryDesc->planstate, &ctx);

		if (ctx.nseen > 0)
			pgsiq_store(&ctx, queryid, nesting_level == 0);
	}

	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
}

/* ---------- eviction ---------- */

static int
entry_cmp(const void *lhs, const void *rhs)
{
	TimestampTz l = (*(pgsiqEntry *const *) lhs)->last_seen;
	TimestampTz r = (*(pgsiqEntry *const *) rhs)->last_seen;

	if (l < r)
		return -1;
	if (l > r)
		return 1;
	return 0;
}

/* Caller must hold an exclusive lock. Evicts least recently seen entries. */
static void
entry_dealloc(void)
{
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry **entries;
	pgsiqEntry *entry;
	int			nentries;
	int			nvictims;
	int			i;

	entries = palloc(hash_get_num_entries(pgsiq_hash) * sizeof(pgsiqEntry *));

	i = 0;
	hash_seq_init(&hash_seq, pgsiq_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
		entries[i++] = entry;
	nentries = i;

	qsort(entries, nentries, sizeof(pgsiqEntry *), entry_cmp);

	nvictims = Max(10, nentries * PGSIQ_DEALLOC_PERCENT / 100);
	nvictims = Min(nvictims, nentries);

	for (i = 0; i < nvictims; i++)
		hash_search(pgsiq_hash, &entries[i]->key, HASH_REMOVE, NULL);

	pfree(entries);

	SpinLockAcquire(&pgsiq->mutex);
	pgsiq->dealloc++;
	SpinLockRelease(&pgsiq->mutex);
}

/* ---------- SQL-callable functions ---------- */

static void
check_loaded(void)
{
	if (!pgsiq || !pgsiq_hash)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("pg_stat_index_queries must be loaded via \"shared_preload_libraries\"")));
}

#define PG_STAT_INDEX_QUERIES_COLS 8

Datum
pg_stat_index_queries(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry *entry;

	check_loaded();

	InitMaterializedSRF(fcinfo, 0);

	LWLockAcquire(pgsiq->lock, LW_SHARED);

	hash_seq_init(&hash_seq, pgsiq_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		Datum		values[PG_STAT_INDEX_QUERIES_COLS];
		bool		nulls[PG_STAT_INDEX_QUERIES_COLS];
		int64		calls_executed;
		int64		calls_planned;
		TimestampTz first_seen;
		TimestampTz last_seen;
		int			i = 0;

		memset(nulls, 0, sizeof(nulls));

		SpinLockAcquire(&entry->mutex);
		calls_executed = entry->calls_executed;
		calls_planned = entry->calls_planned;
		first_seen = entry->first_seen;
		last_seen = entry->last_seen;
		SpinLockRelease(&entry->mutex);

		values[i++] = ObjectIdGetDatum(entry->key.dbid);
		values[i++] = ObjectIdGetDatum(entry->key.indexrelid);
		values[i++] = Int64GetDatumFast((int64) entry->key.queryid);
		values[i++] = BoolGetDatum(entry->key.toplevel);
		values[i++] = Int64GetDatumFast(calls_executed);
		values[i++] = Int64GetDatumFast(calls_planned);
		values[i++] = TimestampTzGetDatum(first_seen);
		values[i++] = TimestampTzGetDatum(last_seen);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
							 values, nulls);
	}

	LWLockRelease(pgsiq->lock);

	return (Datum) 0;
}

Datum
pg_stat_index_queries_reset(PG_FUNCTION_ARGS)
{
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry *entry;

	check_loaded();

	LWLockAcquire(pgsiq->lock, LW_EXCLUSIVE);

	hash_seq_init(&hash_seq, pgsiq_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
		hash_search(pgsiq_hash, &entry->key, HASH_REMOVE, NULL);

	SpinLockAcquire(&pgsiq->mutex);
	pgsiq->dealloc = 0;
	pgsiq->stats_reset = GetCurrentTimestamp();
	SpinLockRelease(&pgsiq->mutex);

	LWLockRelease(pgsiq->lock);

	PG_RETURN_VOID();
}

Datum
pg_stat_index_queries_info(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	Datum		values[3];
	bool		nulls[3] = {false, false, false};
	int64		dealloc;
	TimestampTz stats_reset;

	check_loaded();

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	SpinLockAcquire(&pgsiq->mutex);
	dealloc = pgsiq->dealloc;
	stats_reset = pgsiq->stats_reset;
	SpinLockRelease(&pgsiq->mutex);

	LWLockAcquire(pgsiq->lock, LW_SHARED);
	values[0] = Int64GetDatum((int64) hash_get_num_entries(pgsiq_hash));
	LWLockRelease(pgsiq->lock);

	values[1] = Int64GetDatum(dealloc);
	values[2] = TimestampTzGetDatum(stats_reset);

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}
