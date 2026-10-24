# Promotion by data state

## Problem

After a staggered shutdown of both nodes (standby first, primary some time later, with writes in between) the
standby that boots first stays passive while it is alone in the cluster (single-node guard). As soon as the former
primary joins the cluster, `check_promotion_safety()` found no running primary and took the fail-open branch
("Allowing promotion"). The stale standby was promoted and the newer data of the other node was discarded when that
node was resynchronized.

## Behaviour

If the peer is a cluster member and no primary is running anywhere, a standby compares its data state with the
peer's before the existing sync/async checks:

- data state = (timeline, replay LSN) of the node, read with `psql` (the peer with the replication user),
- both values must be stable (two queries two seconds apart are equal; a position that still advances means crash
  recovery is running and the comparison waits),
- the node with the higher timeline, then the higher LSN, is promoted; the other node refuses,
- equal data states: the node with the smaller cluster name is promoted, the other refuses,
- the peer gives no usable state within `promotion_peer_wait` seconds (not reachable, PostgreSQL not running):
  the node is promoted anyway with a warning (availability over a dead peer); while the peer's position still
  advances the wait is extended up to 100 seconds, which stays below the 120 s promote timeout,
- the peer is leaving in an orderly way (Pacemaker `shutdown` attribute set, or node in standby): no usable state will
  come, the node is promoted at once (`promote-peer-leaving`); a clean shutdown flushes all WAL to the standby first,
- a node without `standby.signal` (former primary) that starts while the peer is a cluster member and no primary is
  running is started as standby, so that the same comparison decides who becomes primary (covers: primary dies, standby
  is promoted and writes, new primary dies, old primary boots first),
- peer is not a cluster member: unchanged (single-node guard, then the existing checks).

A refusal returns an error from the promote action; Pacemaker then promotes the node that is ahead.
`force_promotion=true` bypasses the comparison. `promotion_peer_wait=0` disables it.

## Parameter

| Name | Default | Meaning |
|---|---|---|
| `promotion_peer_wait` | 60 | seconds to wait for a usable peer state; 0 disables the comparison |

## Log

One line per decision:

```
promotion-by-data-state: decision=<promote|refuse|promote-peer-unreachable|promote-peer-leaving> local=<tli>/<lsn> peer=<tli>/<lsn|unknown> tiebreak=<yes|no> waited=<s>s
```

Find it with `journalctl -g 'decision=(promote|refuse)'`.

## Requirements

The replication user must be able to call `pg_control_checkpoint()`, `pg_is_in_recovery()`,
`pg_last_wal_replay_lsn()` and `pg_current_wal_lsn()` on the peer; the cluster node name must resolve to a host
reachable on the PostgreSQL port (same resolution as for `discover_promoted_node`).

## Tests

`test/test-promotion-data-state.sh` (pure functions, no PostgreSQL). Cluster tests: staggered shutdown matrix
(standby/primary stopped clean or hard, gap 20 s and 180 s) and simultaneous power loss with all start orders,
checked with a writer that records acknowledged commits.
