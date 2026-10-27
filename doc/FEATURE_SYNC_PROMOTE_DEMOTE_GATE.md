# Sync promote/demote gate (`rep_mode=sync`)

Two checks that only apply with `rep_mode=sync`. With `rep_mode=async` the comparison of
[promotion by data state](FEATURE_PROMOTION_BY_DATA_STATE.md) and the lag check stay as they are.

## What it does

**Demote gate (`pgsql_demote()`).** A primary only demotes if a standby is currently confirmed synchronous on its own
`pg_stat_replication` (`sync_state='sync'`, `state='streaming'`). Otherwise the demote fails (`OCF_ERR_GENERIC`) and
the log says `Refusing to demote`. `force_demote=true` skips the check. The confirmed standby is also the replication
target of the demoted node.

The check is skipped when the peer answers and is already a primary (`peer_is_primary()`). That is the old primary
coming back after a failover: it has no synchronous standby because it is the stale one, it is started as a primary
(no `standby.signal`), Pacemaker sees two promoted instances and asks it to demote. Refusing there keeps two primaries
running and the node never rejoins; measured on a two-node cluster by killing the primary and restarting it.

**Promote gate (`promotion_sync_state_guard()`).** A standby may become primary if either
1. a primary is reachable and reports this node as `sync` (live), or
2. no primary is reachable and the attribute `pgtwin-confirmed-synced` of this node is `1` (cached).

If neither holds the promotion is refused (`promotion-sync-guard: no live or cached confirmation`). `force_promotion=true`
bypasses it. The gate runs after the data-state comparison in `check_promotion_safety()`.

**The attribute.** The primary records for every peer, on every `Promoted` monitor, whether it is currently a confirmed
synchronous standby: `crm_attribute -N <peer> -n pgtwin-confirmed-synced` is `1` or `0`. It is a persistent node attribute (it must
survive a reboot of the node that wrote it) and is only written when the value changes, because every write is a CIB
configuration change. Read it with `crm_attribute -N <node> -n pgtwin-confirmed-synced -G -q`.

## Node names and `application_name`

`pg_stat_replication.application_name` is derived from the hostname with every `-` replaced by `_`
(`get_application_name()`; hyphens are not allowed in an application name), so node `pg-b` appears as `pg_b`.
`node_list` and the Pacemaker node names keep the hyphen. `node_name_for_application_name()` maps back; comparing the two
directly never matches on hyphenated node names, which silently records `0` for a healthy standby and makes every
cached promotion decision refuse. `test/test-sync-gate.sh` covers this with hyphenated names on purpose.

## Operating notes

- **Check the standby before a planned hand-off.** `crm node standby <primary>` first stops the VIP (the ordering
  constraint `vip-stop-before-demote`) and then demotes. If the demote is refused, the primary is left without its VIP, and
  Pacemaker treats the failed demote as a resource failure: with the node going to standby it plans to stop the
  instance on that node and to promote the other one, whose promotion is checked by the gate again. A refusal therefore
  stops the planned hand-off and does not keep the primary serving. Run this on the primary first:
  `SELECT application_name, state, sync_state FROM pg_stat_replication;`
- **Double failure / cold start.** The cached value is what the last primary observed. A standby that was not
  synchronous then (for example one that had just been rebuilt) refuses to promote until it is, or until
  `force_promotion=true` is set. That is the intended trade-off of this gate: it prefers no primary to a primary that
  may lack acknowledged commits.
- **The value of the current primary is not maintained.** It keeps what was written while the node was a standby.
  After a full outage the node that was primary last is therefore decided by the data-state comparison and by that old
  value; a node with value `0` that was the last primary needs `force_promotion=true`.
- **Cost.** One local `psql` query and one `crm_attribute -G` per peer in every `Promoted` monitor (about 40 ms and 30 ms
  on a small VM, measured). A `crm_attribute` write happens only when the state of a standby changes.

## Cold start

With `rep_mode=sync` the cached attribute decides after a full outage as well. A node that has been primary since the
cluster was created has no value until it has been a standby once. The data-state comparison runs first, so the node
with the newer data is the candidate, but a candidate with a `0` or no value still needs `force_promotion=true`. Check
`crm_attribute -N <node> -n pgtwin-confirmed-synced -G -q` on both nodes before a planned stop of the whole cluster.

## Tests

`bash test/test-sync-gate.sh` (no PostgreSQL, no Pacemaker): name mapping, demote target, recording of the confirmed
standby and the promote gate in all its branches, including the end-to-end case "primary records the standby, primary is gone,
standby promotes".
