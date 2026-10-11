# pgtwin v1.7.10 Release Notes

**Release Date:** 2026-10-11
**Type:** Bug Fix Release
**Status:** Production Ready

---

## Overview

This release fixes three related failure modes that leave a returning standby without replication, found when a standby of a 2-node cluster stayed a non-working standby for 17 days after a failover. They share one theme: a standby that stays away for a while could not catch up, and nothing in the agent noticed or repaired it.

No new parameters, no changed defaults, no interface changes.

---

## What's Fixed

### 1. The replication slot created at promotion reserved no WAL

`create_replication_slot()` created the slot without `immediately_reserve`. Such a slot has `restart_lsn = NULL` and holds back no WAL until a standby has connected through it. Slots are not replicated to the standby, so every failover creates a fresh, empty slot on the new primary. A standby that was away for a while found its WAL already recycled (`requested WAL segment ... has already been removed`) and could never catch up.

The slot is now created with `immediately_reserve`. An existing slot that is idle and reserves nothing is dropped and recreated; a slot that reserves WAL or is in use is left alone.

### 2. A standby whose WAL is gone looped forever instead of being rebuilt

If the WAL a standby needs no longer exists on the primary, `pg_ctl -w start` times out. Pacemaker clears the fail-count after `failure-timeout` and retries the identical start, again and again. The timeline check only runs on divergent timelines, and `pg_rewind` can report `no rewind required` while the redo segment is still missing.

When a standby start fails and the log lines written by that attempt contain `requested WAL segment ... has already been removed`, the agent now stops PostgreSQL and rebuilds the standby with `pg_basebackup` (`pg_rewind` is skipped), then defers to the monitor like the existing empty-PGDATA path.

### 3. A standby named a replication slot that did not exist on the primary

`finalize_standby_config()` writes `primary_slot_name`, but only the `pg_basebackup` path created the slot. After `pg_rewind`, after the slot was dropped, or on a rebuilt primary the walreceiver failed forever with `replication slot "..." does not exist`. The standby was consistent, so the start succeeded and the agent reported success while nothing replicated.

Before a standby starts, the agent now checks the slot on the primary and creates it (with reserved WAL) if it is missing. Best effort: if the primary cannot be reached, the start continues as before.

---

## Upgrade Notes

- Replace the agent on both nodes, one at a time (see the node update procedure); no cluster configuration changes.
- The automatic rebuild (fix 2) uses the same code path as the existing fallbacks. With `backup_before_basebackup=true` (default) the old data directory is kept as `<pgdata>.backup.<timestamp>` and needs free disk space of about the data size. With `false` it is deleted.
- Recommended with any slot-based setup: bound slot retention with `max_slot_wal_keep_size` and alert when no standby streams for longer than a planned maintenance window.

---

## Testing

`test/wal-removed-repro/` runs the real agent against a throw-away PostgreSQL 18 primary/standby in podman (OCF and Pacemaker tools stubbed). Each scenario fails on 1.7.9 and passes on 1.7.10; see its README.
