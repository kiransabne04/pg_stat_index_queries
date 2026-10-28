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
 * Each backend first adds its counts to a local pending table and moves
 * them into the shared hash at most every flush_interval milliseconds
 * (without waiting for the lock), when the pending table is full, when the
 * backend exits, and before it reads the counters itself. So no statement
 * touches shared memory, and other sessions see a backend's counts up to
 * flush_interval late. flush_interval = 0 updates shared memory after
 * every statement. sample_rate < 1 records only that fraction of
 * statements and scales the counts.
 *
 * Each entry also records which index columns the query searched on
 * (Vars in indexqual) and ordered by (indexorderby, e.g. KNN), as bitmasks
 * OR'd over the scans that ran.
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
#include "access/xact.h"
#include "catalog/pg_type.h"
#include "common/pg_prng.h"
#include "executor/executor.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/execnodes.h"
#include "nodes/nodeFuncs.h"
#include "nodes/plannodes.h"
#if PG_VERSION_NUM >= 160000
#include "nodes/queryjumble.h"
#else
#include "utils/queryjumble.h"
#endif
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "storage/spin.h"
#include "tcop/utility.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"

#include <math.h>
#include <unistd.h>

PG_MODULE_MAGIC;

#define PGSIQ_TRANCHE_NAME		"pg_stat_index_queries"
#define PGSIQ_DEALLOC_PERCENT	5
#define PGSIQ_MAX_INDEXES_PER_STMT	64

/* Persistence across clean restarts (same approach as pg_stat_statements). */
#define PGSIQ_DUMP_FILE		PGSTAT_STAT_PERMANENT_DIRECTORY "/pg_stat_index_queries.stat"
/* Periodic snapshot (0.10); not in base backups. */
#define PGSIQ_SNAP_FILE		PG_STAT_TMP_DIR "/pg_stat_index_queries.snap"
#define PGSIQ_FILE_HEADER	0x51495303	/* "SIQ" + format version 3 */
#define PGSIQ_FILE_HEADER_V2	0x51495302	/* still read: no column masks */
#define PGSIQ_FILE_HEADER_V1	0x51495301	/* still read: no sampled flag */
#define PGSIQ_MAX_PENDING	512		/* local entries before a forced flush */
#define PGSIQ_PG_MAJOR		(PG_VERSION_NUM / 100)

/*
 * Index columns are recorded in a uint32 bitmask (bit n-1 = column n).
 * INDEX_MAX_KEYS is 32 unless PostgreSQL was built with a larger value;
 * columns above 32 are then not recorded.
 */
#define PGSIQ_MAX_MASK_COLS	32

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
	uint32		cond_cols;		/* index columns searched on (indexqual) */
	uint32		order_cols;		/* index columns ordered by (indexorderby) */
	bool		cols_complete;	/* false: loaded from a file without masks */
} pgsiqEntry;

typedef struct pgsiqSharedState
{
	LWLock	   *lock;			/* protects hash table search/modification */
	slock_t		mutex;			/* protects fields below */
	int64		dealloc;
	TimestampTz stats_reset;
	bool		sampled;		/* a statement was skipped by sample_rate */
	bool		dirty;			/* counters changed since the last save */
	uint64		reset_count;	/* bumped by reset; changed only under
								 * exclusive lock */
} pgsiqSharedState;

/* Counts of one (index, query) not yet moved to shared memory. */
typedef struct pgsiqPending
{
	pgsiqHashKey key;			/* must be first */
	int64		calls_executed;
	int64		calls_planned;
	TimestampTz first_seen;
	TimestampTz last_seen;
	uint32		cond_cols;
	uint32		order_cols;
} pgsiqPending;

/* One index seen in the current statement */
typedef struct pgsiqSeenIndex
{
	Oid			indexrelid;
	bool		executed;
	uint32		cond_cols;		/* from scans that ran */
	uint32		order_cols;
} pgsiqSeenIndex;

typedef struct pgsiqWalkContext
{
	int			nseen;
	bool		overflow;
	pgsiqSeenIndex seen[PGSIQ_MAX_INDEXES_PER_STMT];
} pgsiqWalkContext;

/* A tracked index as it was before a REINDEX (name and schema). */
typedef struct pgsiqReindexed
{
	Oid			oldoid;
	Oid			newoid;
	Oid			nspid;
	char	   *name;
} pgsiqReindexed;

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
static int	pgsiq_flush_interval = 1000;	/* ms */
static double pgsiq_sample_rate = 1.0;
static int	pgsiq_save_interval = 300;	/* s */

/* ---------- state ---------- */

static int	nesting_level = 0;
static pgsiqSharedState *pgsiq = NULL;
static HTAB *pgsiq_hash = NULL;

/* Backend-local pending counts (see file header). */
static HTAB *pending_hash = NULL;
static TimestampTz last_flush = 0;
static bool exit_hook_registered = false;

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
PGDLLEXPORT void pgsiq_saver_main(Datum main_arg);

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
static void pgsiq_accumulate(pgsiqWalkContext *ctx, uint64 queryid,
							 bool toplevel, int64 weight);
static void pgsiq_flush(bool force);
static void pgsiq_backend_exit(int code, Datum arg);
static void pending_discard(void);
static void entry_dealloc(void);
static void pgsiq_shmem_shutdown(int code, Datum arg);
static bool pgsiq_read_file(const char *path);
static void pgsiq_load_file(void);
static pgsiqEntry *pgsiq_snapshot(int64 *count);
static bool write_entry(FILE *file, const pgsiqEntry *entry);
static bool pgsiq_write_file(const char *path, const pgsiqEntry *entries,
							 int64 count, int64 dealloc,
							 TimestampTz stats_reset, bool sampled);
static void pgsiq_periodic_save(void);
static inline void mark_dirty(void);
static pgsiqReindexed *reindex_capture(int *n);
static void reindex_rekey(pgsiqReindexed *idx, int n);

PG_FUNCTION_INFO_V1(pg_stat_index_queries);
PG_FUNCTION_INFO_V1(pg_stat_index_queries_0_8);
PG_FUNCTION_INFO_V1(pg_stat_index_queries_reset);
PG_FUNCTION_INFO_V1(pg_stat_index_queries_info);
PG_FUNCTION_INFO_V1(pg_stat_index_queries_sampled);

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

	DefineCustomIntVariable("pg_stat_index_queries.flush_interval",
							"How often a backend moves its counts to shared memory.",
							"0 updates shared memory after every statement. Other sessions see a backend's counts up to this late.",
							&pgsiq_flush_interval,
							1000,
							0,
							60000,
							PGC_SUSET,
							GUC_UNIT_MS,
							NULL, NULL, NULL);

	DefineCustomRealVariable("pg_stat_index_queries.sample_rate",
							 "Fraction of statements recorded; counts are scaled up.",
							 "Below 1, counts are estimates and an index used rarely can be missed.",
							 &pgsiq_sample_rate,
							 1.0,
							 0.0,
							 1.0,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pg_stat_index_queries.save_interval",
							"How often counters are saved to disk, so a crash loses at most this much.",
							"0 saves only at clean shutdown.",
							&pgsiq_save_interval,
							300,
							0,
							86400,
							PGC_SIGHUP,
							GUC_UNIT_S,
							NULL, NULL, NULL);

	MarkGUCPrefixReserved("pg_stat_index_queries");

	/*
	 * Writes the counters every save_interval; shared memory only. Always
	 * registered (one max_worker_processes slot), so save_interval can be
	 * raised with a reload; it sleeps while save_interval = 0 or save = off.
	 */
	{
		BackgroundWorker worker;

		memset(&worker, 0, sizeof(worker));
		worker.bgw_flags = BGWORKER_SHMEM_ACCESS;
		worker.bgw_start_time = BgWorkerStart_PostmasterStart;
		worker.bgw_restart_time = 10;
		snprintf(worker.bgw_library_name, BGW_MAXLEN, "pg_stat_index_queries");
		snprintf(worker.bgw_function_name, BGW_MAXLEN, "pgsiq_saver_main");
		snprintf(worker.bgw_name, BGW_MAXLEN, "pg_stat_index_queries saver");
		snprintf(worker.bgw_type, BGW_MAXLEN, "pg_stat_index_queries saver");
		RegisterBackgroundWorker(&worker);
	}

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
		pgsiq->sampled = false;
		pgsiq->dirty = false;
		pgsiq->reset_count = 0;
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
 * File layout: header, PG major, entry count, dealloc, stats_reset, sampled
 * (version 2+), then entry_count records of (key, calls_executed,
 * calls_planned, first_seen, last_seen, and in version 3 cond_cols and
 * order_cols). Any mismatch or short read discards the whole file.
 * Version 1 (0.1-0.5) and 2 (0.6-0.7) files are still read; their entries
 * get cols_complete = false, so no column is reported as unused.
 *
 * Two files with that layout:
 * - PGSIQ_DUMP_FILE (pg_stat/): written at clean shutdown, removed after
 *   loading, as in pg_stat_statements.
 * - PGSIQ_SNAP_FILE (pg_stat_tmp/): written every save_interval by the
 *   saver worker, loaded only when there is no shutdown file (after a
 *   crash). pg_stat_tmp is left out of base backups, so a new replica
 *   doesn't start with its primary's counters.
 */
static bool
pgsiq_read_file(const char *path)
{
	FILE	   *file;
	uint32		header;
	int32		pgmajor;
	int64		count;
	int64		dealloc;
	TimestampTz stats_reset;
	bool		sampled = false;
	int64		i;

	file = AllocateFile(path, PG_BINARY_R);
	if (file == NULL)
	{
		if (errno != ENOENT)
			ereport(LOG,
					(errcode_for_file_access(),
					 errmsg("could not read file \"%s\": %m", path)));
		return false;
	}

	if (fread(&header, sizeof(uint32), 1, file) != 1 ||
		fread(&pgmajor, sizeof(int32), 1, file) != 1 ||
		fread(&count, sizeof(int64), 1, file) != 1 ||
		fread(&dealloc, sizeof(int64), 1, file) != 1 ||
		fread(&stats_reset, sizeof(TimestampTz), 1, file) != 1)
		goto bad_file;

	if ((header != PGSIQ_FILE_HEADER && header != PGSIQ_FILE_HEADER_V2 &&
		 header != PGSIQ_FILE_HEADER_V1) ||
		pgmajor != PGSIQ_PG_MAJOR || count < 0)
		goto bad_file;
	if (header != PGSIQ_FILE_HEADER_V1 &&
		fread(&sampled, sizeof(bool), 1, file) != 1)
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
		temp.cond_cols = 0;
		temp.order_cols = 0;
		temp.cols_complete = (header == PGSIQ_FILE_HEADER);
		if (temp.cols_complete &&
			(fread(&temp.cond_cols, sizeof(uint32), 1, file) != 1 ||
			 fread(&temp.order_cols, sizeof(uint32), 1, file) != 1))
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
		entry->cond_cols = temp.cond_cols;
		entry->order_cols = temp.order_cols;
		entry->cols_complete = temp.cols_complete;
	}

	pgsiq->dealloc = dealloc;
	pgsiq->stats_reset = stats_reset;
	pgsiq->sampled = sampled;

	FreeFile(file);
	return true;

bad_file:
	ereport(LOG,
			(errmsg("ignoring invalid pg_stat_index_queries file \"%s\"",
					path)));
	FreeFile(file);
	unlink(path);

	/* Start clean: drop anything partially loaded. */
	{
		HASH_SEQ_STATUS hash_seq;
		pgsiqEntry *entry;

		hash_seq_init(&hash_seq, pgsiq_hash);
		while ((entry = hash_seq_search(&hash_seq)) != NULL)
			hash_search(pgsiq_hash, &entry->key, HASH_REMOVE, NULL);
	}
	return false;
}

/* Called by the postmaster when shared memory is created. */
static void
pgsiq_load_file(void)
{
	bool		periodic = pgsiq_save && pgsiq_save_interval > 0;
	bool		loaded;

	/* A clean shutdown's file is newer than any snapshot. */
	loaded = pgsiq_read_file(PGSIQ_DUMP_FILE);
	unlink(PGSIQ_DUMP_FILE);
	if (loaded || !periodic)
		unlink(PGSIQ_SNAP_FILE);
	else
		loaded = pgsiq_read_file(PGSIQ_SNAP_FILE);

	/* Let the saver write a snapshot of what was loaded. */
	if (loaded && periodic)
		pgsiq->dirty = true;
}

static void
pgsiq_shmem_shutdown(int code, Datum arg)
{
	/* Don't save after a crash, or if shared memory was never set up. */
	if (code != 0 || !pgsiq || !pgsiq_hash)
		return;

	unlink(PGSIQ_SNAP_FILE);
	if (!pgsiq_save)
	{
		unlink(PGSIQ_DUMP_FILE);
		return;
	}

	/*
	 * All other processes have exited: write straight from the hash, with
	 * no lock and no memory allocation in the postmaster.
	 */
	if (pgsiq_write_file(PGSIQ_DUMP_FILE ".tmp", NULL,
						 hash_get_num_entries(pgsiq_hash), pgsiq->dealloc,
						 pgsiq->stats_reset, pgsiq->sampled))
		(void) durable_rename(PGSIQ_DUMP_FILE ".tmp", PGSIQ_DUMP_FILE, LOG);
}

/* Copy all entries into local memory. Caller holds the lock (shared). */
static pgsiqEntry *
pgsiq_snapshot(int64 *count)
{
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry *entry;
	pgsiqEntry *entries;
	int64		n = 0;

	entries = palloc_extended(Max(hash_get_num_entries(pgsiq_hash), 1) *
							  sizeof(pgsiqEntry), MCXT_ALLOC_HUGE);
	hash_seq_init(&hash_seq, pgsiq_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		SpinLockAcquire(&entry->mutex);
		entries[n] = *entry;
		SpinLockRelease(&entry->mutex);
		n++;
	}
	*count = n;
	return entries;
}

static bool
write_entry(FILE *file, const pgsiqEntry *entry)
{
	return fwrite(&entry->key, sizeof(pgsiqHashKey), 1, file) == 1 &&
		fwrite(&entry->calls_executed, sizeof(int64), 1, file) == 1 &&
		fwrite(&entry->calls_planned, sizeof(int64), 1, file) == 1 &&
		fwrite(&entry->first_seen, sizeof(TimestampTz), 1, file) == 1 &&
		fwrite(&entry->last_seen, sizeof(TimestampTz), 1, file) == 1 &&
		fwrite(&entry->cond_cols, sizeof(uint32), 1, file) == 1 &&
		fwrite(&entry->order_cols, sizeof(uint32), 1, file) == 1;
}

/*
 * Write count entries to path and fsync it; the caller renames it into
 * place. entries = NULL writes straight from the shared hash (only when no
 * other process can touch it). Returns false (after a LOG message) on
 * failure.
 */
static bool
pgsiq_write_file(const char *path, const pgsiqEntry *entries, int64 count,
				 int64 dealloc, TimestampTz stats_reset, bool sampled)
{
	FILE	   *file;
	uint32		header = PGSIQ_FILE_HEADER;
	int32		pgmajor = PGSIQ_PG_MAJOR;
	int64		i;

	file = AllocateFile(path, PG_BINARY_W);
	if (file == NULL)
		goto error;

	if (fwrite(&header, sizeof(uint32), 1, file) != 1 ||
		fwrite(&pgmajor, sizeof(int32), 1, file) != 1 ||
		fwrite(&count, sizeof(int64), 1, file) != 1 ||
		fwrite(&dealloc, sizeof(int64), 1, file) != 1 ||
		fwrite(&stats_reset, sizeof(TimestampTz), 1, file) != 1 ||
		fwrite(&sampled, sizeof(bool), 1, file) != 1)
		goto error;

	if (entries != NULL)
	{
		for (i = 0; i < count; i++)
			if (!write_entry(file, &entries[i]))
				goto error;
	}
	else
	{
		HASH_SEQ_STATUS hash_seq;
		pgsiqEntry *entry;

		hash_seq_init(&hash_seq, pgsiq_hash);
		while ((entry = hash_seq_search(&hash_seq)) != NULL)
		{
			if (!write_entry(file, entry))
			{
				hash_seq_term(&hash_seq);
				goto error;
			}
		}
	}

	if (fflush(file) != 0 || pg_fsync(fileno(file)) != 0)
		goto error;

	if (FreeFile(file))
	{
		file = NULL;
		goto error;
	}
	return true;

error:
	ereport(LOG,
			(errcode_for_file_access(),
			 errmsg("could not write file \"%s\": %m", path)));
	if (file)
		FreeFile(file);
	unlink(path);
	return false;
}

/*
 * Save the counters if they changed since the last save. Entries are copied
 * under the shared lock; the file is written and fsynced without it. The
 * rename happens under the shared lock again, and only if no reset ran in
 * between (a reset takes the exclusive lock and removes the snapshot), so a
 * crash never brings back counters from before a reset. Backends never wait
 * for the disk.
 */
static void
pgsiq_periodic_save(void)
{
	pgsiqEntry *entries;
	int64		count;
	int64		dealloc;
	TimestampTz stats_reset;
	bool		sampled;
	uint64		reset_count;
	bool		saved = false;
	bool		renamed = false;

	LWLockAcquire(pgsiq->lock, LW_SHARED);
	SpinLockAcquire(&pgsiq->mutex);
	if (!pgsiq->dirty)
	{
		SpinLockRelease(&pgsiq->mutex);
		LWLockRelease(pgsiq->lock);
		return;
	}
	/* Cleared before copying: a change made during the copy marks it again. */
	pgsiq->dirty = false;
	dealloc = pgsiq->dealloc;
	stats_reset = pgsiq->stats_reset;
	sampled = pgsiq->sampled;
	SpinLockRelease(&pgsiq->mutex);
	reset_count = pgsiq->reset_count;
	entries = pgsiq_snapshot(&count);
	LWLockRelease(pgsiq->lock);

	if (pgsiq_write_file(PGSIQ_SNAP_FILE ".tmp", entries, count, dealloc,
						 stats_reset, sampled))
	{
		LWLockAcquire(pgsiq->lock, LW_SHARED);
		if (pgsiq->reset_count == reset_count)
		{
			if (rename(PGSIQ_SNAP_FILE ".tmp", PGSIQ_SNAP_FILE) == 0)
				saved = renamed = true;
			else
				ereport(LOG,
						(errcode_for_file_access(),
						 errmsg("could not rename file \"%s\": %m",
								PGSIQ_SNAP_FILE ".tmp")));
		}
		else
		{
			unlink(PGSIQ_SNAP_FILE ".tmp");
			saved = true;		/* the reset marked the state dirty */
		}
		LWLockRelease(pgsiq->lock);
		if (!renamed)
			unlink(PGSIQ_SNAP_FILE ".tmp");
	}
	pfree(entries);

	/* Make the rename durable; outside the lock. */
	if (renamed)
		(void) fsync_fname_ext(PG_STAT_TMP_DIR, true, false, LOG);

	if (!saved)
		mark_dirty();
}

/* Background worker: save every save_interval seconds. */
void
pgsiq_saver_main(Datum main_arg)
{
	MemoryContext cxt;
	TimestampTz last_save;

	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	pqsignal(SIGTERM, SignalHandlerForShutdownRequest);
	BackgroundWorkerUnblockSignals();

	if (!pgsiq || !pgsiq_hash)
		proc_exit(0);

	cxt = AllocSetContextCreate(TopMemoryContext,
								"pg_stat_index_queries saver",
								ALLOCSET_DEFAULT_SIZES);
	last_save = GetCurrentTimestamp();

	for (;;)
	{
		int			flags = WL_LATCH_SET | WL_EXIT_ON_PM_DEATH;
		long		timeout = -1;

		if (ShutdownRequestPending)
			proc_exit(0);

		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
			/* No snapshot to reload after a crash (as at startup). */
			if (!pgsiq_save || pgsiq_save_interval == 0)
				unlink(PGSIQ_SNAP_FILE);
		}

		if (pgsiq_save && pgsiq_save_interval > 0)
		{
			TimestampTz now = GetCurrentTimestamp();
			TimestampTz next = TimestampTzPlusMilliseconds(last_save,
														   pgsiq_save_interval * 1000L);

			if (now >= next)
			{
				MemoryContext old = MemoryContextSwitchTo(cxt);

				pgsiq_periodic_save();
				MemoryContextSwitchTo(old);
				MemoryContextReset(cxt);
				last_save = now;
				continue;
			}
			flags |= WL_TIMEOUT;
			timeout = TimestampDifferenceMilliseconds(now, next);
		}

		(void) WaitLatch(MyLatch, flags, timeout, PG_WAIT_EXTENSION);
		ResetLatch(MyLatch);
	}
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
	 * A cursor's query gets no query ID (only the DECLARE statement itself
	 * is jumbled), so it would never be recorded. Give it the ID the same
	 * query gets when run on its own.
	 */
	if (pgsiq && IsA(parsetree, DeclareCursorStmt) && IsQueryIdEnabled())
	{
		DeclareCursorStmt *cstmt = (DeclareCursorStmt *) parsetree;

		if (cstmt->query != NULL && IsA(cstmt->query, Query) &&
			((Query *) cstmt->query)->queryId == UINT64CONST(0))
		{
			if (readOnlyTree)
			{
				pstmt = copyObject(pstmt);
				readOnlyTree = false;
				parsetree = pstmt->utilityStmt;
				cstmt = (DeclareCursorStmt *) parsetree;
			}
#if PG_VERSION_NUM >= 160000
			(void) JumbleQuery((Query *) cstmt->query);
#else
			(void) JumbleQuery((Query *) cstmt->query, queryString);
#endif
		}
	}

	/*
	 * Statements run inside a utility command (DO blocks, CALL, EXPLAIN
	 * ANALYZE, CREATE TABLE AS ...) count as nested, not top level. EXECUTE
	 * and PREPARE are the exception, as in pg_stat_statements: the prepared
	 * query is the user's top-level statement. So are CLOSE and DISCARD:
	 * closing a cursor ends its query (ExecutorEnd), which the user ran at
	 * top level.
	 */
	bump = !(IsA(parsetree, ExecuteStmt) || IsA(parsetree, PrepareStmt) ||
			 IsA(parsetree, ClosePortalStmt) || IsA(parsetree, DiscardStmt));

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
		pgsiqReindexed *reindexed = NULL;
		int			nreindexed = 0;

		/* REINDEX CONCURRENTLY gives indexes new OIDs; carry history over. */
		if (IsA(parsetree, ReindexStmt))
			reindexed = reindex_capture(&nreindexed);

		if (prev_ProcessUtility)
			prev_ProcessUtility(pstmt, queryString, readOnlyTree, context,
								params, queryEnv, dest, qc);
		else
			standard_ProcessUtility(pstmt, queryString, readOnlyTree, context,
									params, queryEnv, dest, qc);

		if (reindexed)
			reindex_rekey(reindexed, nreindexed);
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();
}

/* ---------- REINDEX CONCURRENTLY (0.10) ---------- */

static int
oid_cmp_reindexed(const void *lhs, const void *rhs)
{
	Oid			l = ((const pgsiqReindexed *) lhs)->oldoid;
	Oid			r = ((const pgsiqReindexed *) rhs)->oldoid;

	return (l < r) ? -1 : (l > r) ? 1 : 0;
}

/*
 * Before a REINDEX: the name and schema of every index tracked in this
 * database, sorted by OID. Allocated in PortalContext when there is one,
 * because REINDEX CONCURRENTLY commits transactions while it runs.
 * Returns NULL when nothing is tracked.
 */
static pgsiqReindexed *
reindex_capture(int *n)
{
	MemoryContext old;
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry *entry;
	pgsiqReindexed *idx;
	int			nall;
	int			i;
	int			j;

	*n = 0;
	if (!pgsiq || !pgsiq_hash)
		return NULL;

	/* This session's counts must be under the old OIDs too. */
	pgsiq_flush(true);

	old = MemoryContextSwitchTo(PortalContext ? PortalContext : CurrentMemoryContext);

	LWLockAcquire(pgsiq->lock, LW_SHARED);
	idx = palloc_extended(Max(hash_get_num_entries(pgsiq_hash), 1) *
						  sizeof(pgsiqReindexed), MCXT_ALLOC_HUGE);
	nall = 0;
	hash_seq_init(&hash_seq, pgsiq_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
		if (entry->key.dbid == MyDatabaseId)
			idx[nall++].oldoid = entry->key.indexrelid;
	LWLockRelease(pgsiq->lock);

	qsort(idx, nall, sizeof(pgsiqReindexed), oid_cmp_reindexed);

	/* Distinct OIDs that still exist, with their names. */
	j = 0;
	for (i = 0; i < nall; i++)
	{
		char	   *name;

		if (j > 0 && idx[j - 1].oldoid == idx[i].oldoid)
			continue;
		name = get_rel_name(idx[i].oldoid);
		if (name == NULL)
			continue;
		idx[j].oldoid = idx[i].oldoid;
		idx[j].newoid = InvalidOid;
		idx[j].nspid = get_rel_namespace(idx[i].oldoid);
		idx[j].name = name;
		j++;
	}

	MemoryContextSwitchTo(old);

	if (j == 0)
	{
		pfree(idx);
		return NULL;
	}
	*n = j;
	return idx;
}

/*
 * After a REINDEX: an index whose old OID is gone and whose name now
 * belongs to a different OID was rebuilt concurrently. Move its entries to
 * the new OID, merging with any the new index already has. Other sessions'
 * not yet flushed counts still arrive under the old OID, which the views
 * ignore.
 */
static void
reindex_rekey(pgsiqReindexed *idx, int n)
{
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry *entry;
	pgsiqEntry *moved;
	int			nmoved = 0;
	int			nchanged = 0;
	int			i;

	for (i = 0; i < n; i++)
	{
		Oid			newoid = get_relname_relid(idx[i].name, idx[i].nspid);
		char	   *oldname = get_rel_name(idx[i].oldoid);

		if (oldname == NULL && OidIsValid(newoid) && newoid != idx[i].oldoid)
		{
			idx[i].newoid = newoid;
			nchanged++;
		}
		if (oldname)
			pfree(oldname);
	}

	if (nchanged > 0)
	{
		pgsiq_flush(true);

		LWLockAcquire(pgsiq->lock, LW_EXCLUSIVE);

		moved = palloc_extended(Max(hash_get_num_entries(pgsiq_hash), 1) *
								sizeof(pgsiqEntry), MCXT_ALLOC_HUGE);
		hash_seq_init(&hash_seq, pgsiq_hash);
		while ((entry = hash_seq_search(&hash_seq)) != NULL)
		{
			pgsiqReindexed key;
			pgsiqReindexed *r;

			if (entry->key.dbid != MyDatabaseId)
				continue;
			key.oldoid = entry->key.indexrelid;
			r = bsearch(&key, idx, n, sizeof(pgsiqReindexed), oid_cmp_reindexed);
			if (r == NULL || !OidIsValid(r->newoid))
				continue;
			moved[nmoved] = *entry;
			moved[nmoved].key.indexrelid = r->newoid;
			nmoved++;
			/* Removing the element just returned is allowed during a scan. */
			hash_search(pgsiq_hash, &entry->key, HASH_REMOVE, NULL);
		}

		/* Exclusive lock held: no spinlocks needed. */
		for (i = 0; i < nmoved; i++)
		{
			pgsiqEntry *m = &moved[i];
			bool		found;

			entry = (pgsiqEntry *) hash_search(pgsiq_hash, &m->key,
											   HASH_ENTER, &found);
			if (!found)
			{
				SpinLockInit(&entry->mutex);
				entry->calls_executed = m->calls_executed;
				entry->calls_planned = m->calls_planned;
				entry->first_seen = m->first_seen;
				entry->last_seen = m->last_seen;
				entry->cond_cols = m->cond_cols;
				entry->order_cols = m->order_cols;
				entry->cols_complete = m->cols_complete;
				continue;
			}
			entry->calls_executed += m->calls_executed;
			entry->calls_planned += m->calls_planned;
			if (m->first_seen < entry->first_seen)
				entry->first_seen = m->first_seen;
			if (m->last_seen > entry->last_seen)
				entry->last_seen = m->last_seen;
			entry->cond_cols |= m->cond_cols;
			entry->order_cols |= m->order_cols;
			entry->cols_complete = entry->cols_complete && m->cols_complete;
		}

		LWLockRelease(pgsiq->lock);
		pfree(moved);
		if (nmoved > 0)
			mark_dirty();
	}

	for (i = 0; i < n; i++)
		pfree(idx[i].name);
	pfree(idx);
}

/* ---------- plan walk + capture ---------- */

/*
 * Set the bit of every index column referenced in an index qual or order-by
 * list. Those expressions refer to index columns as Vars with varno
 * INDEX_VAR and varattno = index column number.
 */
static bool
index_cols_walker(Node *node, void *context)
{
	if (node == NULL)
		return false;
	if (IsA(node, Var))
	{
		Var		   *var = (Var *) node;

		if (var->varno == INDEX_VAR && var->varattno >= 1 &&
			var->varattno <= PGSIQ_MAX_MASK_COLS)
			*(uint32 *) context |= ((uint32) 1) << (var->varattno - 1);
		return false;
	}
	return expression_tree_walker(node, index_cols_walker, context);
}

static uint32
index_cols(List *exprs)
{
	uint32		mask = 0;

	(void) index_cols_walker((Node *) exprs, &mask);
	return mask;
}

/* Column masks are only collected for scans that ran. */
static void
remember_index(pgsiqWalkContext *ctx, Oid indexrelid, bool executed,
			   List *indexqual, List *indexorderby)
{
	uint32		cond_cols = 0;
	uint32		order_cols = 0;
	int			i;

	if (!pgsiq_track_catalog && indexrelid < FirstNormalObjectId)
		return;

	if (executed)
	{
		cond_cols = index_cols(indexqual);
		order_cols = index_cols(indexorderby);
	}

	for (i = 0; i < ctx->nseen; i++)
	{
		if (ctx->seen[i].indexrelid == indexrelid)
		{
			ctx->seen[i].executed |= executed;
			ctx->seen[i].cond_cols |= cond_cols;
			ctx->seen[i].order_cols |= order_cols;
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
	ctx->seen[ctx->nseen].cond_cols = cond_cols;
	ctx->seen[ctx->nseen].order_cols = order_cols;
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
				IndexScan  *plan = (IndexScan *) planstate->plan;

				/* index_beginscan() runs lazily on first fetch */
				remember_index(ctx, plan->indexid, s->iss_ScanDesc != NULL,
							   plan->indexqual, plan->indexorderby);
				break;
			}
		case T_IndexOnlyScanState:
			{
				IndexOnlyScanState *s = (IndexOnlyScanState *) planstate;
				IndexOnlyScan *plan = (IndexOnlyScan *) planstate->plan;

				remember_index(ctx, plan->indexid, s->ioss_ScanDesc != NULL,
							   plan->indexqual, plan->indexorderby);
				break;
			}
		case T_BitmapIndexScanState:
			{
				/*
				 * The scan descriptor is created at executor init, so we
				 * cannot tell whether it actually ran. Counted as executed;
				 * documented as approximate.
				 */
				BitmapIndexScan *plan = (BitmapIndexScan *) planstate->plan;

				remember_index(ctx, plan->indexid, true, plan->indexqual, NIL);
				break;
			}
		default:
			break;
	}

	return planstate_tree_walker(planstate, pgsiq_walker, context);
}

/*
 * Add one statement's indexes to the backend-local pending table, then move
 * the pending counts to shared memory if it's time. Timestamps are the
 * statement start (cached, no clock call per statement).
 */
static void
pgsiq_accumulate(pgsiqWalkContext *ctx, uint64 queryid, bool toplevel,
				 int64 weight)
{
	TimestampTz now = GetCurrentStatementStartTimestamp();
	int			i;

	if (pending_hash == NULL)
	{
		HASHCTL		info;

		info.keysize = sizeof(pgsiqHashKey);
		info.entrysize = sizeof(pgsiqPending);
		info.hcxt = TopMemoryContext;
		pending_hash = hash_create("pg_stat_index_queries pending",
								   64, &info,
								   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
		last_flush = now;
	}
	if (!exit_hook_registered)
	{
		before_shmem_exit(pgsiq_backend_exit, (Datum) 0);
		exit_hook_registered = true;
	}

	for (i = 0; i < ctx->nseen; i++)
	{
		pgsiqHashKey key;
		pgsiqPending *p;
		bool		found;

		memset(&key, 0, sizeof(key));
		key.dbid = MyDatabaseId;
		key.indexrelid = ctx->seen[i].indexrelid;
		key.queryid = queryid;
		key.toplevel = toplevel;

		p = (pgsiqPending *) hash_search(pending_hash, &key, HASH_ENTER, &found);
		if (!found)
		{
			p->calls_executed = 0;
			p->calls_planned = 0;
			p->first_seen = now;
			p->cond_cols = 0;
			p->order_cols = 0;
		}
		p->calls_planned += weight;
		if (ctx->seen[i].executed)
			p->calls_executed += weight;
		p->last_seen = now;
		p->cond_cols |= ctx->seen[i].cond_cols;
		p->order_cols |= ctx->seen[i].order_cols;
	}

	if (pgsiq_flush_interval == 0 ||
		hash_get_num_entries(pending_hash) >= PGSIQ_MAX_PENDING)
		pgsiq_flush(true);
	else if (TimestampDifferenceExceeds(last_flush, now, pgsiq_flush_interval))
		pgsiq_flush(false);
}

/* Tell the saver there is something new. Unlocked read first. */
static inline void
mark_dirty(void)
{
	if (!pgsiq->dirty)
	{
		SpinLockAcquire(&pgsiq->mutex);
		pgsiq->dirty = true;
		SpinLockRelease(&pgsiq->mutex);
	}
}

/*
 * Move pending counts into the shared hash. force = false gives up if the
 * lock is busy (the counts stay pending and are retried later); force =
 * true waits for it. Existing entries are updated under the shared lock
 * (per-entry spinlock); new ones are inserted under the exclusive lock.
 */
static void
pgsiq_flush(bool force)
{
	HASH_SEQ_STATUS hash_seq;
	pgsiqPending *p;
	bool		need_insert = false;

	if (pending_hash == NULL || pgsiq == NULL || pgsiq_hash == NULL ||
		hash_get_num_entries(pending_hash) == 0)
		return;

	if (force)
		LWLockAcquire(pgsiq->lock, LW_SHARED);
	else if (!LWLockConditionalAcquire(pgsiq->lock, LW_SHARED))
		return;

	hash_seq_init(&hash_seq, pending_hash);
	while ((p = hash_seq_search(&hash_seq)) != NULL)
	{
		pgsiqEntry *entry;

		entry = (pgsiqEntry *) hash_search(pgsiq_hash, &p->key, HASH_FIND, NULL);
		if (!entry)
		{
			need_insert = true;
			continue;
		}
		SpinLockAcquire(&entry->mutex);
		entry->calls_executed += p->calls_executed;
		entry->calls_planned += p->calls_planned;
		if (p->last_seen > entry->last_seen)
			entry->last_seen = p->last_seen;
		entry->cond_cols |= p->cond_cols;
		entry->order_cols |= p->order_cols;
		SpinLockRelease(&entry->mutex);
		/* Removing the element just returned is allowed during a scan. */
		hash_search(pending_hash, &p->key, HASH_REMOVE, NULL);
	}
	LWLockRelease(pgsiq->lock);
	mark_dirty();

	if (need_insert)
	{
		if (force)
			LWLockAcquire(pgsiq->lock, LW_EXCLUSIVE);
		else if (!LWLockConditionalAcquire(pgsiq->lock, LW_EXCLUSIVE))
			return;

		hash_seq_init(&hash_seq, pending_hash);
		while ((p = hash_seq_search(&hash_seq)) != NULL)
		{
			pgsiqEntry *entry;
			bool		found;

			if (hash_get_num_entries(pgsiq_hash) >= pgsiq_max)
				entry_dealloc();

			entry = (pgsiqEntry *) hash_search(pgsiq_hash, &p->key,
											   HASH_ENTER, &found);
			if (!found)
			{
				SpinLockInit(&entry->mutex);
				entry->calls_executed = 0;
				entry->calls_planned = 0;
				entry->first_seen = p->first_seen;
				entry->last_seen = p->last_seen;
				entry->cond_cols = 0;
				entry->order_cols = 0;
				entry->cols_complete = true;
			}
			/* Exclusive lock held: no spinlock needed. */
			entry->calls_executed += p->calls_executed;
			entry->calls_planned += p->calls_planned;
			if (p->last_seen > entry->last_seen)
				entry->last_seen = p->last_seen;
			entry->cond_cols |= p->cond_cols;
			entry->order_cols |= p->order_cols;
			hash_search(pending_hash, &p->key, HASH_REMOVE, NULL);
		}
		LWLockRelease(pgsiq->lock);
		mark_dirty();
	}

	last_flush = GetCurrentStatementStartTimestamp();
}

/* Don't lose a session's last counts when it disconnects. */
static void
pgsiq_backend_exit(int code, Datum arg)
{
	pgsiq_flush(true);
}

static void
pending_discard(void)
{
	if (pending_hash != NULL)
	{
		hash_destroy(pending_hash);
		pending_hash = NULL;
	}
}

static void
pgsiq_ExecutorEnd(QueryDesc *queryDesc)
{
	uint64		queryid = (uint64) queryDesc->plannedstmt->queryId;

	/* Plain EXPLAIN (no ANALYZE) runs nothing: not a use. */
	if (pgsiq && queryid != UINT64CONST(0) &&
		queryDesc->planstate != NULL &&
		!(queryDesc->estate->es_top_eflags & EXEC_FLAG_EXPLAIN_ONLY) &&
		pgsiq_enabled(nesting_level))
	{
		int64		weight = 1;
		bool		skip = false;

		if (pgsiq_sample_rate < 1.0)
		{
			if (pgsiq_sample_rate <= 0.0 ||
				pg_prng_double(&pg_global_prng_state) >= pgsiq_sample_rate)
			{
				skip = true;
				/* Unlocked read first: no shared write on every statement. */
				if (!pgsiq->sampled)
				{
					SpinLockAcquire(&pgsiq->mutex);
					pgsiq->sampled = true;
					SpinLockRelease(&pgsiq->mutex);
				}
			}
			else
			{
				/* Clamped: a tiny rate must not overflow int64. */
				double		w = rint(1.0 / pgsiq_sample_rate);

				weight = (w > 1e9) ? (int64) 1000000000 : (int64) w;
			}
		}

		if (!skip)
		{
			pgsiqWalkContext ctx;

			ctx.nseen = 0;
			ctx.overflow = false;

			/* planstate_tree_walker() skips the root node; visit it ourselves. */
			pgsiq_walker(queryDesc->planstate, &ctx);

			if (ctx.nseen > 0)
				pgsiq_accumulate(&ctx, queryid, nesting_level == 0, weight);
		}
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

/*
 * Result shapes of pg_stat_index_queries(), as in pg_stat_statements: each
 * SQL version binds its own C symbol, so an older SQL definition keeps
 * working with a newer library until ALTER EXTENSION UPDATE.
 */
typedef enum pgsiqVersion
{
	PGSIQ_V0_1,					/* 8 columns */
	PGSIQ_V0_8					/* + cond_columns, order_columns, columns_complete */
} pgsiqVersion;

#define PG_STAT_INDEX_QUERIES_COLS_V0_1	8
#define PG_STAT_INDEX_QUERIES_COLS_V0_8	11
#define PG_STAT_INDEX_QUERIES_COLS		11	/* maximum of the above */

/* Index column numbers set in a mask, as int2[] (ascending). */
static Datum
cols_to_array(uint32 mask)
{
	Datum		elems[PGSIQ_MAX_MASK_COLS];
	int			n = 0;
	int			i;

	for (i = 0; i < PGSIQ_MAX_MASK_COLS; i++)
	{
		if (mask & (((uint32) 1) << i))
			elems[n++] = Int16GetDatum(i + 1);
	}
	return PointerGetDatum(construct_array(elems, n, INT2OID, sizeof(int16),
										   true, TYPALIGN_SHORT));
}

static void
pg_stat_index_queries_internal(FunctionCallInfo fcinfo, pgsiqVersion api)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry *entry;

	check_loaded();

	/* This backend's own counts are always visible to itself. */
	pgsiq_flush(true);

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
		uint32		cond_cols;
		uint32		order_cols;
		bool		cols_complete;
		int			i = 0;

		memset(nulls, 0, sizeof(nulls));

		SpinLockAcquire(&entry->mutex);
		calls_executed = entry->calls_executed;
		calls_planned = entry->calls_planned;
		first_seen = entry->first_seen;
		last_seen = entry->last_seen;
		cond_cols = entry->cond_cols;
		order_cols = entry->order_cols;
		cols_complete = entry->cols_complete;
		SpinLockRelease(&entry->mutex);

		values[i++] = ObjectIdGetDatum(entry->key.dbid);
		values[i++] = ObjectIdGetDatum(entry->key.indexrelid);
		values[i++] = Int64GetDatumFast((int64) entry->key.queryid);
		values[i++] = BoolGetDatum(entry->key.toplevel);
		values[i++] = Int64GetDatumFast(calls_executed);
		values[i++] = Int64GetDatumFast(calls_planned);
		values[i++] = TimestampTzGetDatum(first_seen);
		values[i++] = TimestampTzGetDatum(last_seen);
		if (api >= PGSIQ_V0_8)
		{
			values[i++] = cols_to_array(cond_cols);
			values[i++] = cols_to_array(order_cols);
			values[i++] = BoolGetDatum(cols_complete);
		}

		Assert(i == (api == PGSIQ_V0_1 ? PG_STAT_INDEX_QUERIES_COLS_V0_1 :
					 PG_STAT_INDEX_QUERIES_COLS_V0_8));

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
							 values, nulls);
	}

	LWLockRelease(pgsiq->lock);
}

Datum
pg_stat_index_queries(PG_FUNCTION_ARGS)
{
	pg_stat_index_queries_internal(fcinfo, PGSIQ_V0_1);
	return (Datum) 0;
}

Datum
pg_stat_index_queries_0_8(PG_FUNCTION_ARGS)
{
	pg_stat_index_queries_internal(fcinfo, PGSIQ_V0_8);
	return (Datum) 0;
}

Datum
pg_stat_index_queries_reset(PG_FUNCTION_ARGS)
{
	HASH_SEQ_STATUS hash_seq;
	pgsiqEntry *entry;

	check_loaded();

	/*
	 * Drops this backend's pending counts too. Other backends' pending
	 * counts (at most flush_interval old) still arrive after the reset.
	 */
	pending_discard();

	LWLockAcquire(pgsiq->lock, LW_EXCLUSIVE);

	hash_seq_init(&hash_seq, pgsiq_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
		hash_search(pgsiq_hash, &entry->key, HASH_REMOVE, NULL);

	SpinLockAcquire(&pgsiq->mutex);
	pgsiq->dealloc = 0;
	pgsiq->stats_reset = GetCurrentTimestamp();
	pgsiq->sampled = false;
	pgsiq->dirty = true;
	SpinLockRelease(&pgsiq->mutex);

	/* A crash after a reset must not bring back the old counters. */
	pgsiq->reset_count++;
	unlink(PGSIQ_SNAP_FILE);
	unlink(PGSIQ_DUMP_FILE);

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
	pgsiq_flush(true);

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

/* True if sample_rate < 1 skipped any statement since the last reset. */
Datum
pg_stat_index_queries_sampled(PG_FUNCTION_ARGS)
{
	bool		sampled;

	check_loaded();

	SpinLockAcquire(&pgsiq->mutex);
	sampled = pgsiq->sampled;
	SpinLockRelease(&pgsiq->mutex);

	PG_RETURN_BOOL(sampled);
}
