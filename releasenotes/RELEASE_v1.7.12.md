# pgtwin v1.7.12 Release Notes

**Release Date:** 2026-10-30
**Type:** Bug Fix Release
**Status:** Production Ready

---

## Overview

Fixes the `synchronous_standby_names` fallback for hyphenated node names. No new parameters, no changed defaults, no interface changes.

---

## What's Fixed

### Hyphenated node names never matched their application_name

`get_application_name()` derives the standby's `application_name` from the host name with hyphens replaced by underscores, so the node `pg-b` connects as `pg_b`. `get_safe_synchronous_standby_names()` compared the node name with the connected `application_name` directly. For every hyphenated node name this failed on every monitor of the primary:

- the log filled with `application_name mismatch between cluster and PG` (about every 4 s on a 3 s monitor),
- `synchronous_standby_names` fell back to `'*'` instead of naming the standby.

Replication itself was healthy (`streaming/sync`); the fallback is also the reason this went unnoticed for a long time. Synchronous replication now names the standby (`synchronous_standby_names = 'pg_b'`).

**Test:** `test/test-safe-sync-names.sh` (5 cases: hyphenated node, FQDN, plain name, unrelated `application_name` still falls back to `*`, no standby connected). Without the fix 2 of 5 fail.

### Version strings

The agent header (1.7.5), the resource-agent meta-data (1.6.9) and `pgtwin.spec` (1.6.0) lagged behind `VERSION`; all three now say 1.7.12.

---

## Upgrade

Replace the agent file on the standby first, then on the primary. No restart, no `crm resource refresh` needed. The log line `Safe synchronous standbys (cluster + connected): <name>` confirms the fix.
