# pgtwin v1.7.13 Release Notes

**Release Date:** 2026-11-07
**Type:** Bug Fix Release
**Status:** Production Ready

---

## Overview

Fixes a deadlock after the cold start of both nodes. No new parameters, no changed defaults, no interface changes.

---

## What's Fixed

### Cold start of both nodes could end without a primary

The standby monitor sets the permanent node attribute `master-pgtwin-pg=-INFINITY` (promotion forbidden) as soon as the replication of a standby looks unhealthy. When both nodes start without a primary, no standby can replicate from anything, so each of them looks unhealthy and vetoes itself. The promotion by data state (1.7.11) then picks one node by data state or, for equal data, by cluster name. If that node has already withdrawn its own eligibility and the other node correctly refuses, nobody is promoted:

- observed once in six cold starts of 1.7.11 (no primary after 333 s), not at all in four cold starts of 1.7.10,
- the cluster does not recover by itself; the way out is `maintenance-mode`, a manual `pg_ctl promote` and resetting the attribute.

**Fix:** `no_primary_in_cluster()`. If the peer answers and is a standby itself, the monitor keeps the node eligible, resets the failure counter and returns success. Every other case is unchanged: a peer that does not answer, a peer that is the primary, no peer.

**Check:** forbid promotion by a location constraint on both nodes and restart both cluster stacks. Scores after 70 s: without the fix `-INFINITY` on both nodes (the cluster stays stopped after the constraints are removed), with the fix `10` on both nodes and a primary is elected once the constraints are gone.

**Tests:** `test/test-cold-start-eligible.sh`; lab: both nodes power-cut and started together or one after the other, 0 acknowledged commits missing.

---

## Upgrade

Replace the agent file on the standby first, then on the primary. No restart, no `crm resource refresh` needed.
