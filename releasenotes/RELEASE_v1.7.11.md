# pgtwin v1.7.11 Release Notes

**Release Date:** 2026-10-25
**Type:** Bug Fix Release (data loss in a double failure)
**Status:** Tested on a two-node lab, see "Tests"

---

## Overview

After a staggered shutdown of both nodes a stale node could be promoted, and the newer data of the other node was
discarded when that node was resynchronized. Two start paths were affected. This release makes the promotion decision
depend on the data state of both nodes.

New parameter `promotion_peer_wait` (default 60 seconds). No other interface changes.

---

## What's Fixed

### 1. A stale standby was promoted when its peer joined the cluster

`check_promotion_safety()` took a fail-open branch ("Allowing promotion") when no primary was running. The single-node
guard only protected a standby while it was alone in the cluster. Sequence: standby stopped, primary writes on and stops
later, the former standby boots first, waits alone, and is promoted as soon as the former primary becomes a cluster
member. Lab result before the fix: 94-98 acknowledged commits lost per run.

### 2. A former primary skipped every promotion check

A node that was primary has no `standby.signal` and started as primary directly. Sequence: the primary dies, the
standby is promoted and keeps writing, the new primary dies too, the OLD primary boots first. Lab result before the fix:
116 acknowledged commits lost.

---

## How it works now

If the peer is a cluster member and no primary is running, a standby compares (timeline, replay LSN) with the peer
before the existing checks. The node that is ahead is promoted, the other refuses; equal states are decided by cluster
name. A former primary (no `standby.signal`) starts as standby in this situation, so the same comparison applies.

- A peer that gives no usable state within `promotion_peer_wait` seconds is treated as unreachable: the node is
  promoted with a warning that names both known states (availability over a dead peer). While the peer's position still
  advances (crash recovery) the wait is extended up to a hard limit of 100 seconds, which stays below the default promote
  timeout of 120 seconds.
- A peer that is shutting down (Pacemaker `shutdown` attribute) or in standby is not waited for, so a clean reboot of the
  primary does not delay the failover.
- `force_promotion=true` bypasses the comparison; `promotion_peer_wait=0` switches it off.
- Every decision is logged: `promotion-by-data-state: decision=<promote|refuse|promote-peer-unreachable|promote-peer-leaving> local=<tli>/<lsn> peer=<tli>/<lsn|unknown> tiebreak=<yes|no> waited=<s>s`.

Requirement: the replication user must be able to run `pg_control_checkpoint()`, `pg_is_in_recovery()`,
`pg_last_wal_replay_lsn()` and `pg_current_wal_lsn()` on the peer (it already does with the documented setup), and the
cluster node name must resolve on the peer connection.

See `doc/FEATURE_PROMOTION_BY_DATA_STATE.md`.

---

## Tests

Two-node lab with a writer that records every acknowledged commit; after every run each acknowledged commit must exist
and two writable primaries must never be observed (sampled every 5 seconds).

- Staggered shutdown matrix (standby clean/hard x primary clean/hard x gap 20 s/180 s, stale node boots first): 8/8,
  the original primary is primary again, no acknowledged commit missing.
- Reverse double failure (primary dies, standby promoted and writing, new primary dies, old primary boots first), three
  variants: no acknowledged commit missing.
- Simultaneous power loss, all start orders (9 runs): always the same node, nothing missing.
- Failover under load, corosync partition (with fence_sbd), process kills, clean reboot and standby/online: all pass; the
  failover times of patched and unpatched agent are in the same range.
- `test/test-promotion-data-state.sh` (pure functions) and `test/test-pgtwin-ha-suite.sh` (12/12; the suite now accepts
  host names, IPs and application names from the environment).

Unrelated finding, not fixed here: `set_promotion_eligibility` can leave `master-pgtwin-pg=-INFINITY` on both nodes when
no primary runs; nobody can then be promoted until the attributes are reset.
