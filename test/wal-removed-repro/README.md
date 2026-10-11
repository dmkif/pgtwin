# WAL-removed reproduction harness

Podman-only test bench for failure modes where a returning standby can no longer catch up because the
primary has already recycled the WAL it needs. It runs the real `pgtwin` agent against a throw-away
PostgreSQL 18 primary/standby pair. The OCF and Pacemaker tools are stubbed (`ocf/`, `bin/`). It does
not touch any cluster.

Requirements: `podman`, network access for `docker.io/library/postgres:18-trixie`.

## Standby that cannot start because its WAL is gone

A standby start never reaches a consistent state when the primary no longer has the WAL it needs. The
postmaster logs `waiting for WAL to become available`, `pg_ctl -w start` times out and the agent returns
an error. A retry cannot help, so the agent now rebuilds the standby with `pg_basebackup`.

    ./setup.sh && ./mkstandby.sh && ./churn.sh            # backup without WAL, WAL then recycled
    ./runra.sh <path-to-pgtwin> start                     # before: RC=1; after: RC=7 (rebuild running)
    sleep 8; ./runra.sh <path-to-pgtwin> monitor          # finalizes the rebuilt standby
    ./runra.sh <path-to-pgtwin> start                     # RC=0, standby streams

The path seen in production is a timeline divergence where `pg_rewind` answers `no rewind required` and
the start still fails, because the standby's redo segment is gone but its checkpoint record is still local:

    ./setup.sh && ./mkstandby-spread.sh && ./churn.sh && ./mktimeline.sh
    ./runra.sh <path-to-pgtwin> start

`./runra.sh <path-to-pgtwin> unit` runs the unit tests of the log scan (an old error line in the log must
not trigger a rebuild).

## Standby names a replication slot that does not exist on the primary

`finalize_standby_config()` writes `primary_slot_name`, but only the `pg_basebackup` path created the slot.
After `pg_rewind`, after the slot was dropped, or on a rebuilt primary the walreceiver then fails with
`replication slot "ha_slot" does not exist`. The standby is consistent, so `pg_ctl start` succeeds and the
agent reports success while nothing replicates.

    ./setup.sh && ./mkstandby-stream.sh                   # consistent standby, no slot on the primary
    ./runra.sh <path-to-pgtwin> start                     # before: RC=0 but pg_stat_replication is empty
                                                          # after: slot created, standby streams
    # same through the pg_rewind path:
    ./setup.sh && ./mkstandby-stream.sh && NO_SLOT=1 ./mktimeline.sh && ./runra.sh <path-to-pgtwin> start

## Slot reservation (`slotcheck.sh`)

`create_replication_slot()` runs when a node is promoted. Replication slots are not copied to the standby,
so every failover creates a fresh slot on the new primary.

    ./slotcheck.sh <path-to-pgtwin>

Expected output with the slot reserving WAL:

    slot restart_lsn after creation: 0/3000028
    primary sees: streaming

Without it:

    slot restart_lsn after creation: NULL (nothing reserved)
    primary sees: no standby streaming
    requested WAL segment ... has already been removed

To compare with an older agent: `git show <rev>:pgtwin > /tmp/pgtwin.old && ./slotcheck.sh /tmp/pgtwin.old`.

The container names are `pgp` (primary) and `pgs` (standby). Remove them with
`podman rm -f pgp pgs; podman network rm pgnet`.
