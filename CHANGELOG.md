## [1.7.12] - 2026-10-30

### Fixed
- **Hyphenated node names never matched their `application_name` in `synchronous_standby_names`**
  - `get_safe_synchronous_standby_names()` compared the cluster node name (`pg-b`) with the connected `application_name` (`pg_b`, derived by `get_application_name()` with hyphens replaced by underscores). For every hyphenated node name the comparison failed, so each monitor of the primary logged `application_name mismatch between cluster and PG` and fell back to `synchronous_standby_names='*'`
  - Fix: compare and list the `application_name`; FQDN node names are still shortened first
  - Test: `test/test-safe-sync-names.sh` (2 of 5 cases fail without the fix)

### Changed
- Version strings brought up to date: agent header (was 1.7.5), resource-agent meta-data (was 1.6.9), `pgtwin.spec` (was 1.6.0)

## [1.7.11] - 2026-10-25

### Fixed
- **Stale standby was promoted after a staggered shutdown of both nodes**
  - `check_promotion_safety()` took the fail-open branch ("Allowing promotion") when no primary was running, even
    though the peer was a cluster member. The node that booted first (the former standby) was promoted as soon as
    the former primary joined the cluster, and the newer data of the former primary was discarded.
  - Fix: `promotion_data_state_guard()` compares (timeline, replay LSN) with the peer before the existing checks;
    the node that is ahead is promoted, the other refuses; equal states are decided by cluster name; a peer that
    gives no usable state within the new parameter `promotion_peer_wait` (default 60 s, hard limit 100 s) is
    treated as unreachable and the node is promoted with a warning. `force_promotion=true` and
    `promotion_peer_wait=0` keep the old behaviour.
  - A peer that is shutting down or in standby is not waited for (`promote-peer-leaving`), so a clean reboot of the
    primary does not delay the failover.
  - A former primary (no `standby.signal`) that starts while the peer is a cluster member and no primary runs is
    started as standby, so the same comparison applies (primary dies, standby promoted and writing, new primary
    dies, old primary boots first: 116 acknowledged commits lost before the fix).
  - Log: `promotion-by-data-state: decision=...` with both data states.
  - Tests: `test/test-promotion-data-state.sh`; see `doc/FEATURE_PROMOTION_BY_DATA_STATE.md`.

## [1.7.10] - 2026-10-11

### Fixed
- **Replication slot created at promotion did not reserve any WAL**
  - `create_replication_slot()` called `pg_create_physical_replication_slot(name)` without `immediately_reserve`, so the new slot had `restart_lsn = NULL` and kept no WAL until a standby had connected through it
  - Replication slots are not copied to the standby, therefore every failover creates a fresh, empty slot on the new primary; a standby that stays away for a while finds its WAL recycled and can never catch up (`requested WAL segment ... has already been removed`)
  - Fix: create the slot with `immediately_reserve => true`; an existing slot that is idle and has no reserved WAL is dropped and recreated, a slot that already reserves WAL or is in use is left alone
  - Reproduction: `test/wal-removed-repro/slotcheck.sh`
- **Standby start loop when the required WAL is gone from the primary**
  - A standby whose WAL was already recycled on the primary waits in `waiting for WAL to become available`; `pg_ctl -w start` times out and the agent failed with `Failed to start PostgreSQL`. Pacemaker cleared the fail-count after `failure-timeout` and retried the identical start forever, as nothing ever fell back to `pg_basebackup`
  - The timeline check did not help: with equal timelines it does not run, and after a timeline divergence `pg_rewind` can answer `no rewind required` while the redo segment is still missing
  - Fix: if the start of a standby fails and the log lines written by that attempt contain `requested WAL segment ... has already been removed`, stop PostgreSQL and rebuild the standby with `pg_basebackup` (skipping `pg_rewind`), then defer to the monitor like the existing empty-PGDATA path. Only log lines written by the failed attempt are considered, with or without `logging_collector`
  - Reproduction: `test/wal-removed-repro/`
- **Standby start did not ensure its replication slot exists on the primary**
  - `finalize_standby_config()` writes `primary_slot_name`, but only the `pg_basebackup` path created the slot. After a `pg_rewind` recovery, a dropped slot or a rebuilt primary the walreceiver failed forever with `replication slot "..." does not exist`; the standby is consistent, so the start succeeded and nothing noticed that replication was down
  - Fix: before a standby starts, the agent checks the slot on the primary and creates it with `immediately_reserve` if it is missing. Best effort: if the primary cannot be reached the start continues as before
  - Reproduction: `test/wal-removed-repro/mkstandby-stream.sh`

### Documentation
- **NEW**: `test/wal-removed-repro/` - podman bench that reproduces all three failure modes against the real agent
- **NEW**: `releasenotes/RELEASE_v1.7.10.md` - Release notes with upgrade notes

---

## [1.7.6 - 1.7.9] - 2026-08 / 2026-09

Not recorded at release time; reconstructed from the git history (tag `v1.7.9`).

### Fixed (pgtwin)
- `discover_promoted_node()`: VIP-based discovery no longer breaks on `/32` VIPs (the VIP itself is the connectable identity) (#1)
- `parse_pgpass()`: default `.pgpass` path resolved from the real home directory of `pguser`, consistent with `ensure_pgpass()` (#2)
- `pgsql_demote()`: a self-discovered primary is rejected, so `primary_conninfo` can no longer point at the node itself (#4); the `node_list` fallback is verified before it is trusted
- `pgsql_start()`: after `recover_standby()` the start defers to the monitor while an asynchronous basebackup is running (#5)
- `set_promotion_eligibility()`: the promotion score is written to `master-<resource>` (the attribute Pacemaker reads) with a positive floor, so a recovering node does not contest promotion and a lone healthy primary is not demoted (#3)
- `start_async_basebackup()`: `pg_basebackup -c fast`, so a rejoining standby does not wait for a spread checkpoint

### Fixed (pgtwin-migrate)
- `setup_subscription()`: `copy_data` is configurable and defaults to `false` for the reverse direction (#6)
- `pgtwin_migrate_prepare_cutover_v2()`: checks the return code of `swap_vip_addresses` (#8)
- README: parameter names and required list match the script (#9)

---

## [1.7.5] - 2026-04-29

### Fixed
- **REGRESSION: New clusters stuck in async mode (introduced in v1.7.4)**
  - `get_safe_synchronous_standby_names()` returned `''` when Pacemaker node names didn't match `pg_stat_replication.application_name`
  - Affects new clusters and manually-configured standbys where `primary_conninfo` lacks an explicit `application_name`
  - Fix: name-mismatch case now returns `'*'` (sync with any standby) instead of `''`, with a log warning to help admin fix the `application_name`
  - The v1.7.4 fix (no standbys connected at all → `''`) is preserved

### Documentation
- **NEW**: `releasenotes/RELEASE_v1.7.5.md` - Release notes with decision table and upgrade guide

---

## [1.7.4] - 2026-03-30

### Fixed
- **CRITICAL: `get_safe_synchronous_standby_names()` caused write blocking on standby loss**
  - All four "no standby available" code paths returned `'*'` instead of `''` (empty)
  - `synchronous_standby_names = '*'` with no connected standbys blocks all PostgreSQL writes
  - Fix: return `''` (async mode) whenever no standbys are available; sync resumes automatically when standby reconnects
  - Affected scenarios: clone resource lookup failure, no Unpromoted nodes in cluster, no standbys streaming to PostgreSQL, Unpromoted nodes present but not yet streaming

### Documentation
- **NEW**: `releasenotes/RELEASE_v1.7.4.md` - Release notes with upgrade instructions

---

## [1.7.3] - 2026-01-19

### Added
- **NEW: pgtwin-migrate-setup v1.0.0** - Interactive setup wizard for migration configuration
  - Guided step-by-step configuration collection
  - Configuration file generation (reusable `.conf` files)
  - CRM snippet generation (ready-to-use Pacemaker configuration)
  - Validation of cluster connectivity, database access, VIP resources
  - Template support: load existing configs with `--config FILE`

### Added (pgtwin-migrate v2.0.0 EXPERIMENTAL)
- **Bidirectional Failover**: New `production_cluster` parameter replaces `cutover_ready`
  - Change `production_cluster` to switch which cluster is production
  - Supports failback (cutover → source) in addition to cutover (source → target)
  - Clean transition: old direction DELETED, new direction CREATED fresh
- **Dynamic Database Discovery**: Discovers databases at runtime from production cluster
  - No explicit `databases` parameter needed (auto-discover)
  - New databases detected automatically every 10th monitor cycle
  - Replication set up automatically for new databases
- **Direction-Aware Start Function**: Correctly handles both forward and reverse directions
  - Checks for publications matching current `production_cluster`
  - Sets up replication for the correct direction
  - Sets CIB state appropriately (`FORWARD_REPLICATION` or `CUTOVER_COMPLETE`)
- **New Database Auto-Setup**: Monitor detects databases without replication
  - Creates database on subscriber if it doesn't exist
  - Copies schema from publisher to subscriber
  - Creates publication and subscription with `copy_data=true`
  - Sets up DDL trigger

### Changed (pgtwin-migrate v2.0.0 EXPERIMENTAL)
- **Parameter Changes**:
  - `production_cluster` (NEW) - Which cluster should be production
  - `finalize_replication` (NEW) - When true, stop cleans up all replication infrastructure
  - `stability_timeout` (NEW) - Seconds to wait for cluster stability before cutover
  - `cutover_ready` (REMOVED) - Replaced by `production_cluster`
- Version bumped to 2.0.0 due to breaking parameter changes

### Changed (pgtwin v1.7.3)
- Version bump for release coordination (no functional changes from v1.7.2)
- For v1.7.2 changes (FQDN hostname mismatch bugfix), see RELEASE_v1.7.2.md

### Documentation
- **NEW**: `releasenotes/RELEASE_v1.7.3.md` - Complete release notes
- **NEW**: `README-pgtwin-migrate-setup.md` - Setup wizard documentation (planned)
- **UPDATED**: `CHANGELOG.md` - This entry

### Migration
- **pgtwin**: No changes required from v1.7.2
- **pgtwin-migrate v1.x → v2.0**:
  1. Complete any in-progress migrations
  2. Stop and delete old migration resource
  3. Deploy pgtwin-migrate v2.0
  4. Use pgtwin-migrate-setup to generate new configuration
  5. Test with non-production data first
- **WARNING**: pgtwin-migrate v2.0 parameter changes are breaking - requires reconfiguration

### Known Limitations (pgtwin-migrate v2.0)
- `max_logical_replication_workers` limit - PostgreSQL default is 4 workers, increase for many databases
- Initial sync for new databases uses `copy_data=true` (database must exist on subscriber)
- Complex schema changes during migration may need manual coordination

---

## [1.7.1] - 2026-01-05

### Added
- **EXPERIMENTAL: pgtwin-migrate v1.0.8** - Zero-downtime PostgreSQL migration agent
  - Orchestrates PostgreSQL cluster migrations via logical replication
  - Use cases: Major version upgrades, vendor migrations, hosting provider changes
  - Features: Bidirectional DDL replication, self-healing, cluster-wide state management, **multi-database migration**
  - Status: EXPERIMENTAL - test thoroughly before production use
  - Documentation: README-pgtwin-migrate.md, MIGRATION_DOCUMENTATION_INDEX.md

### Added (pgtwin-migrate v1.0.8)
- **Multi-Database Migration Support** - Migrate multiple databases in a single operation
  - New `databases` parameter: comma-separated list of databases to migrate
  - Example: `databases="postgres,myapp_prod,analytics,reporting"`
  - Per-database publications, subscriptions, replication slots, and DDL triggers
  - Per-database state tracking and lag monitoring
  - Atomic cutover for all databases together (single VIP swap)
  - Backward compatible with legacy `pgdatabase` parameter
  - Tested with 1-10 databases, scales linearly
  - Documentation: FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md

### Fixed (pgtwin-migrate v1.0.7)
- **Auto-stop after cutover completion**
  - Bug: Resource set target-role=Stopped in monitor, but if migration-state attribute was deleted before monitor ran, auto-stop never triggered
  - Fix: Set target-role=Stopped immediately in check_cutover_progress() when cutover completes (lines 2263-2270)
  - Impact: Resource automatically stops when migration completes, prevents restart loops
  - Kept monitor auto-stop as safety net for edge cases (manual restart, old version migration)

### Fixed (pgtwin v1.6.18)
- **CRITICAL**: Synchronous standby names handling (v1.6.18)
  - Bug: `update_application_name_in_config()` unconditionally wrote sync setting
  - Fix: Only write sync setting when rep_mode=sync
  - Impact: Prevents async clusters from being forced to sync mode
- **CRITICAL**: VIP colocation during failover (v1.6.16)
  - Bug: VIP started on demoting node instead of promoting node
  - Fix: Added colocation constraint check
  - Impact: Ensures VIP always on promoted (primary) node
- **CRITICAL**: XML cluster discovery during failover (v1.6.15)
  - Bug: CIB XML parsing incorrectly identified standby as primary
  - Fix: Enhanced XML parsing with proper Promoted role detection
  - Impact: Prevents operations on read-only nodes
- Configuration detection using postgres -C (v1.6.14)
- Parallel cluster discovery race condition (v1.6.13)
- Timeline check breaking cluster discovery (v1.6.13)
- Replication slot conflict handling (v1.6.9)
- Double-failure detection (v1.6.8)

### Changed
- Updated to version 1.7.0
- Enhanced logging and error messages throughout
- Improved synchronous replication handling (v1.6.17)
- Better single-node scenario handling (v1.6.13)

### Documentation
- Added README-pgtwin-migrate.md - Complete migration agent guide
- Added MIGRATION_DOCUMENTATION_INDEX.md - Full migration workflow
- Updated PGTWIN_CONCEPTS.md - Added pgtwin-migrate overview
- Enhanced QUICKSTART.md with migration references

# Changelog

All notable changes to pgtwin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.7] - 2025-12-23

### Fixed
- **CRITICAL**: Replication failure counter stuck at 1/5 (QA fix)
  - Bug: Counter read using `ocf_run` wrapper which captures stdout, counter always reset to 1
  - Fix: Removed `ocf_run` wrapper from counter read operation (line 1576)
  - Impact: Automatic recovery now triggers correctly after 5 consecutive failures
  - Code: `crm_attribute -G` now properly returns counter value
- **CRITICAL**: PGDATA permissions causing PostgreSQL startup failures (QA fix)
  - Bug: pg_basebackup creates PGDATA with 751 permissions, PostgreSQL requires 700 or 750
  - Fix: Added `chmod 750` at three PGDATA creation points (lines 1893, 2740, 3067)
  - Impact: Eliminates "data directory has invalid permissions" errors after basebackup
- **CRITICAL**: Replication slot creation before pg_basebackup (prevents WAL recycling race)
  - Bug: WAL segments could be recycled before standby retrieved them during long pg_basebackup
  - Fix: Create replication slot BEFORE starting pg_basebackup (lines 2678-2709)
  - Impact: Eliminates "requested WAL segment already removed" failures
  - Affects: Large databases, slow networks, or high WAL generation rates
- **Configuration Validation**: False wal_sender_timeout warnings (QA fix)
  - Bug: Code parsed `SHOW wal_sender_timeout` returning "30s", stripped to "30", compared as integer
  - Fix: Query `pg_settings` which returns milliseconds directly (lines 1162-1175)
  - Impact: Eliminates false warnings when timeout correctly set (e.g., 30s = 30000ms)
- **Log Noise**: Excessive PAM session logging from runuser (QA fix)
  - Bug: Every PostgreSQL operation logged 2 PAM entries (138 entries per 30 seconds)
  - Fix: Created `run_as_pguser()` helper using `setpriv` instead of `runuser` (lines 48-61)
  - Impact: 98% reduction in log noise (0-2 entries vs 138 per 30 seconds)
  - Changed: All 76 `runuser` calls replaced with `run_as_pguser`
- **Documentation**: Fixed duplicate order constraint in QUICKSTART.md
  - Bug: Two order constraints named "promote-before-vip" (Pacemaker rejects duplicate names)
  - Bug: Second constraint had wrong semantics: `postgres-clone:demote vip:start`
  - Fix: Renamed to `vip-stop-before-demote` with correct order: `vip:stop postgres-clone:demote`
  - Impact: QUICKSTART.md instructions now work correctly (previously would fail at crm configure)

### Added
- **Performance**: Automatic resource cleanup after basebackup completion
  - Self-triggered `crm_resource --cleanup` when pg_basebackup finishes
  - Uses `crm_node -n` to determine cluster node name (lines 2726-2768)
  - Performance: 98.4% faster for small databases (5s vs 5m 5s)
  - Eliminates 5-minute failure-timeout wait for administrators
  - Falls back to failure-timeout if cleanup command fails

### Changed
- Updated version to 1.6.7 and release date to 2025-12-23
- Enhanced description includes slot creation sequencing and auto-cleanup
- Consolidated multiple development versions (v1.6.8-v1.6.11) into single stable release
- **Container Mode**: Downgraded "container library not available" from warning to info level (QA fix)
  - Container mode is experimental, missing library should not generate warnings
  - Code change: `ocf_log warn` → `ocf_log info` (line 1782)
- **Privilege Dropping**: Replaced all `runuser` calls with `setpriv` for cleaner logging
  - New `run_as_pguser()` helper function provides consistent privilege dropping
  - Eliminates PAM session logging for PostgreSQL operations

### Testing
- ✅ Automated test suite: 12/12 tests passed (100%)
- ✅ Failover performance: ~4.5 seconds
- ✅ Initialization speedup: 98.4% improvement
- ✅ Zero data loss in all scenarios
- New test suite v1.1 with fixed application_name, pg_rewind timeout, and slot detection checks

### Documentation
- **NEW**: `RELEASE_v1.6.7.md` - Consolidated release notes with all improvements
- **NEW**: `test/test-pgtwin-ha-suite.sh` - Comprehensive automated test suite (12 tests)
- **NEW**: `doc/TEST_SUITE_FIXES.md` - Test suite accuracy improvements documentation
- **NEW**: `QUICKSTART_DUAL_RING_HA.md` - ⚠️ Experimental dual-ring Corosync guide (alternative to SBD)
- **NEW**: `postgresql.custom.conf` - Sample PostgreSQL configuration for HA clusters
  - Minimal required settings for pgtwin resource agent
  - Includes critical `restart_after_crash = off` setting
  - Ready-to-use template for new deployments
- **UPDATED**: `pgsql-resource-config.crm` - Enhanced cluster configuration
  - Added resource-stickiness=100 to prevent unnecessary failback
  - Added failure-timeout=5m and migration-threshold=5
  - Added ping-gateway resource for network connectivity monitoring
  - Added location constraint to prefer nodes with working network connectivity
- **UPDATED**: `QUICKSTART.md` - Added PostgreSQL binary linking instructions (section 1.1)
  - Manual symlink creation for postgresql17-server binaries
  - Two-tier structure via /etc/alternatives for easy version switching
  - Verification commands included
- **UPDATED**: `QUICKSTART.md` - Container mode sections marked as ⚠️ experimental
- **UPDATED**: `README.md` - Added reference to dual-ring experimental guide
- **UPDATED**: `CHANGELOG.md` - This entry

### Migration
- Fully backward compatible with v1.6.6
- No cluster configuration changes required
- Recommended: Run test suite after upgrade to validate functionality
- See RELEASE_v1.6.7.md for complete upgrade instructions

**Note**: This release consolidates critical bug fixes for production deployments. Immediate upgrade recommended for clusters experiencing basebackup failures or long administrator wait times.

## [1.6.6] - 2025-12-09

### Fixed
- **CRITICAL**: Fixed pg_basebackup configuration finalization bug that created empty `primary_conninfo` values
  - Bug caused 100% replication failure after pg_basebackup recovery (affects v1.6.0-v1.6.5)
  - Root cause: Code attempted to read values from file after deleting it
  - Fix: Read values before deletion in `check_basebackup_progress()`
  - New unified `finalize_standby_config()` function ensures correct config (lines 1838-1912)
  - Prefers direct file update when PostgreSQL stopped, falls back to ALTER SYSTEM
  - Safety check in `pgsql_start()` detects and auto-fixes broken configurations
  - Used in all recovery paths: pg_rewind, pg_basebackup (async), manual recovery

### Added
- **Automatic Standby Initialization**: Zero-touch deployment from empty PGDATA
  - New `is_valid_pgdata()` function detects empty/missing/invalid PGDATA (lines 1483-1506)
  - Auto-init logic in `pgsql_start()` triggers pg_basebackup automatically (lines 1530-1590)
  - Updated `pgsql_validate()` to allow empty PGDATA (lines 2360-2375)
  - Prerequisites: Only `.pgpass` file with replication credentials required
  - Use cases: Fresh deployment, disk replacement, corrupted data recovery
  - Disk replacement simplified: 10+ steps → 3 steps
- **Pacemaker Notify Support**: Dynamic synchronous replication management
  - New `pgsql_notify()` action handler (lines 2393-2429)
  - `enable_sync_replication()` - enables sync when standby starts (lines 2383-2391)
  - `disable_sync_replication()` - disables sync when standby stops (lines 2373-2381)
  - Prevents write blocking when standby fails
  - Automatically switches between sync and async based on cluster state
  - Requires `notify="true"` in clone meta configuration
  - Handles post-start, post-stop, post-promote, pre-demote events

### Changed
- Updated version to 1.6.6 and release date to 2025-12-09
- Enhanced description includes automatic standby initialization and notify support
- Configuration finalization now unified across all recovery methods
- PGDATA validation more lenient to support auto-initialization

### Documentation
- **NEW**: `doc/BUGFIX_PG_BASEBACKUP_FINALIZATION.md` - Critical bug fix analysis
- **NEW**: `doc/FEATURE_AUTO_INITIALIZATION.md` - Complete auto-init guide
- **NEW**: `doc/FEATURE_NOTIFY_SUPPORT.md` - Complete notify support guide
- **UPDATED**: `MAINTENANCE_GUIDE.md` - Simplified disk replacement procedure
- **UPDATED**: `CHANGELOG.md` - This entry
- **NEW**: `RELEASE_v1.6.6.md` - Complete release notes

### Migration
- **CRITICAL**: Immediate upgrade recommended to fix configuration bug
- Fully backward compatible with v1.6.x
- No cluster configuration changes required
- Optional: Enable notify support by adding `notify="true"` to clone meta
- See RELEASE_v1.6.6.md for complete upgrade instructions

## [1.6.5] - 2025-11-10

### Added
- **Container Mode Support**: Seamless Podman/Docker container deployment (Phase 1)
  - New container library: `pgtwin-container-lib.sh`
  - Automatic container runtime detection (Podman primary, Docker fallback)
  - Transparent PostgreSQL command wrappers (pg_ctl, psql, pg_basebackup, etc.)
  - Container lifecycle management (start, stop, cleanup)
  - New OCF parameters: `container_mode`, `container_name`, `container_image`, `pg_major_version`
  - Container mode validation in `pgsql_validate()`
  - No code changes needed in main agent for container vs bare-metal operation

### Changed
- Added container mode support throughout all PostgreSQL operations
- Enhanced metadata with container-specific parameters
- Installation now includes container library deployment

### Documentation
- **NEW**: `CONTAINER_MODE_IMPLEMENTATION.md` - Container mode technical guide
- **NEW**: `RELEASE_v1.6.5_SUMMARY.md` - Container mode release summary
- **UPDATED**: Installation instructions include container library

## [1.6.4] - 2025-11-07

### Changed
- Prepared release package for GitHub distribution
- Updated documentation and version tracking
- All files synchronized with latest v1.6.3 codebase

### Status
- Stable release ready for production deployment
- Includes all fixes from v1.6.1, v1.6.2, and v1.6.3
- No functional changes from v1.6.3

## [1.6.3] - 2025-11-05

### Fixed
- **CRITICAL**: Fixed cluster node name handling - resource agent now correctly uses Pacemaker cluster node name instead of system hostname
  - Added `get_cluster_node_name()` helper function using `crm_node -n`
  - Fixed 6 locations using `hostname -s` for `crm_attribute` calls
  - Prevents UUID mapping errors when cluster node names differ from hostnames
  - Critical for VM/cloud environments with generic hostnames
- **QUICKSTART.md**: Fixed PostgreSQL startup sequence - PostgreSQL must be running before creating replication user
- **QUICKSTART.md**: Added replication slot creation step before `pg_basebackup`
- **QUICKSTART.md**: Simplified ocf-tester verification instructions

### Changed
- All `crm_attribute` operations now use cluster node name from `crm_node -n`
- Node list comparisons use cluster node name for accuracy

### Impact
- Fixes crm_attribute failures in environments where cluster node name ≠ hostname
- Backward compatible - falls back to `hostname -s` if `crm_node` unavailable
- No configuration changes required for existing clusters

## [1.6.2] - 2025-11-03

### Documentation
- **README.md**: Added "Expected Timing" section with detailed performance metrics
  - Automatic failover: 30-60 seconds breakdown
  - Manual failover: 15-30 seconds
  - Node recovery timing (pg_rewind vs pg_basebackup)
  - Replication lag expectations (sync/async modes)
- **QUICKSTART.md**: Integrated complete inline Production Checklist
  - PostgreSQL configuration checklist
  - Replication configuration checklist
  - Cluster configuration checklist
  - Testing verification checklist
  - Monitoring setup checklist
- **PROJECT_SUMMARY.md**: Cleaned up parent repository references

### Changed
- All documentation now self-contained within pgtwin repository
- Focus on operational timing metrics instead of synthetic benchmarks
- No code changes - documentation-only release

## [1.6.1] - 2025-11-03

### Fixed
- **CRITICAL**: Fixed replication failure counter not incrementing (removed `ocf_run` wrapper from GET operations)
- **CRITICAL**: Added missing `passfile` parameter to `primary_conninfo` in 3 locations
  - `pgsql_demote()` function
  - `recover_standby()` after pg_rewind
  - `check_basebackup_progress()` after pg_basebackup
- **CRITICAL**: Fixed CIB parsing returning "*" instead of hostname (improved `crm_mon` parsing)
- **CRITICAL**: Added missing `PGPASSFILE` environment variable for pg_rewind and pg_basebackup
- **CRITICAL**: Fixed `pg_basebackup` exit code handling (accepts exit code 1 as success with warnings)
- **CRITICAL**: Prevented replication slot recreation when slot already exists

### Impact
- Automatic recovery feature from v1.6.0 now fully functional
- Replication reconnection after demote now works correctly
- pg_rewind and pg_basebackup authentication fixed
- All 6 critical bugs preventing v1.6.0 from working are resolved

## [1.6.0] - 2025-11-03

### Added
- **Automatic Replication Recovery**: Monitor function now detects replication failures and automatically triggers recovery
  - Tracks replication health on standby nodes
  - Incremental failure counter with configurable threshold (`replication_failure_threshold` parameter, default: 5)
  - Automatically triggers `pg_rewind`/`pg_basebackup` when threshold exceeded
- **Dynamic Promoted Node Discovery**: New `discover_promoted_node()` function finds current primary using multiple methods:
  - Method 1: Query VIP directly (fastest, most reliable)
  - Method 2: Scan all nodes in `node_list`
  - Method 3: Parse Pacemaker CIB (fallback)
- **Enhanced Monitor Function**: Standby nodes now actively monitor WAL receiver status
- **Enhanced Demote Function**: Uses dynamic discovery to find promoted node for replication setup
- **New Parameters**:
  - `vip`: Virtual IP address for promoted node discovery (optional but recommended)
  - `replication_failure_threshold`: Number of monitor cycles before triggering automatic recovery (default: 5)

### Known Issues
- Replication failure counter may not increment correctly in some scenarios (FIXED in v1.6.1)
- Missing `passfile` parameter in `primary_conninfo` when using `.pgpass` authentication (FIXED in v1.6.1)

### Technical Details
- All v1.6 features are backwards compatible - clusters can upgrade without configuration changes
- Dynamic discovery significantly improves demote reliability in complex failure scenarios
- Automatic recovery reduces manual intervention for timeline divergence issues

## [1.5.0] - 2025-11-02

### Added
- **Enhanced Configuration Validation**: 6 new PostgreSQL configuration checks on startup
  - **CRITICAL**: `restart_after_crash` must be `off` (prevents split-brain)
  - **WARNING**: `wal_sender_timeout` < 10s (prevents false disconnections)
  - **WARNING**: `max_standby_streaming_delay` = -1 (prevents unbounded lag)
  - **WARNING**: `archive_command` error handling validation
  - **NOTICE**: `listen_addresses` security review
- **Runtime Archive Monitoring**: Continuous monitoring for archive failures on primary
  - Detects accumulating archive failures during monitor operations
  - Logs warnings with failure counts and timestamps
  - Prevents silent archive failures that could block writes
- **Comprehensive PostgreSQL Configuration Guide**: New `README.postgres.md` with:
  - Complete configuration reference
  - "Getting Started with HA PostgreSQL" tutorial
  - Critical and dangerous configuration options explained
  - Performance tuning and security considerations
  - Troubleshooting guide

### Changed
- Configuration validation now blocks startup on CRITICAL errors
- Archive failure monitoring runs on every primary monitor cycle (interval: 3s)

## [1.4.0] - 2025-11-01

### Fixed
- **CRITICAL**: Fixed promotion failure - `pg_ctl promote` now handles `standby.signal` removal automatically
  - Removed manual `rm -f standby.signal` which caused permission errors
  - PostgreSQL properly manages `standby.signal` during promotion
- **CRITICAL**: Added dual location constraints for proper failover migration
  - Both nodes now have `role=Promoted` score assignments
  - Enables bidirectional failover (psql1 ↔ psql2)

### Added
- **Automatic application_name Management**: Resource agent updates `application_name` in `postgresql.auto.conf`
  - On start: Updates to configured value or sanitized hostname
  - On promote: Ensures consistency between primary and standby
  - Eliminates manual synchronous_standby_names mismatches
- **STONITH/SBD Configuration**: Cluster now includes proper fencing
  - `stonith-enabled=true` with SBD device
  - `have-watchdog=true` for split-brain protection
  - `priority-fencing-delay=60s` for safer fencing

### Changed
- Promotion process now relies entirely on `pg_ctl promote` for file management
- Location constraints now explicitly include `role=Promoted` qualifier
- Default cluster configuration includes STONITH device

## [1.3.0] - 2025-10-31

### Added
- **Configuration Validation Framework**: 8 comprehensive checks run on every PostgreSQL start
  - PostgreSQL version compatibility check (17.x)
  - Critical replication settings validation (`wal_level`, `max_wal_senders`, `hot_standby`)
  - Archive mode configuration check
  - Listen addresses validation
  - Replication user existence verification
  - Replication slot configuration check
  - VIP parameter validation
  - Synchronous replication mode verification
- Early startup blocking for critical misconfigurations
- Detailed error messages for each validation failure
- Prevents cluster startup with unsafe configurations

## [1.2.0] - 2025-10-30

### Changed
- **Disk Space Calculation Refactoring**: Switched from logical database size to actual filesystem usage
  - Now uses `du -sb $PGDATA` for accurate total space requirements
  - Includes all data files, WAL, logs, temp files, and metadata
  - Backup mode: `(actual_usage × 2) + 10% safety margin`
  - No-backup mode: `(actual_usage × 1) + 10% safety margin`
- More accurate disk space safety margin calculations
- Improved error messages showing required vs available space

### Removed
- `pg_database_size()` based disk calculations (too narrow, missed critical space usage)

## [1.1.0] - 2025-10-29

### Added
- **Application Name Validation**: Enforces `[a-zA-Z0-9_]` character set
  - Automatic sanitization (hyphens → underscores) when using hostname fallback
  - Validation prevents PostgreSQL replication parsing issues
- **Disk Space Pre-Check**: Validates sufficient space before `pg_basebackup`
  - Checks available space on PGDATA filesystem
  - Accounts for backup mode (2× space) vs no-backup mode (1× space)
  - Prevents failed basebackups due to insufficient space
- **Backup Mode Semantics**: Clear distinction between backup and no-backup modes
  - `backup_before_basebackup=true`: Moves data to `.backup.<timestamp>` (recoverable)
  - `backup_before_basebackup=false`: Immediate permanent deletion (50% space savings)
- **Asynchronous pg_basebackup**: Long-running basebackups execute in background
  - Prevents Pacemaker monitor timeouts
  - Progress tracking in `${PGDATA}/.basebackup.log`
  - State file: `${PGDATA}/.basebackup_in_progress`
  - Configurable timeout via `basebackup_timeout` parameter (default: 3600s)
- **Enhanced .pgpass Support**: Automatic credential extraction
  - Parses `pgpassfile` parameter for replication credentials
  - Extracts host, port, user, password for `pg_basebackup` and `pg_rewind`
  - Fallback logic for credential discovery

### Parameters Added
- `basebackup_timeout` (default: 3600s): Maximum time for basebackup operation
- `pgpassfile` (optional): Path to .pgpass file for credential management
- `backup_before_basebackup` (default: false): Enable/disable backup mode

## [1.0.0] - 2025-10-28

### Initial Release
- PostgreSQL 17 High Availability support
- Physical streaming replication with replication slots
- Automatic failover with Pacemaker
- Virtual IP (VIP) management
- `pg_rewind` support for timeline reconciliation
- Synchronous and asynchronous replication modes
- Basic configuration validation
- WAL archiving support
- Comprehensive logging and error handling

[1.6.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.6.0
[1.5.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.5.0
[1.4.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.4.0
[1.3.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.3.0
[1.2.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.2.0
[1.1.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.1.0
[1.0.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.0.0
