# WAL-removed reproduction harness

Podman-only test bench for failure modes where a returning standby can no longer catch up because the
primary has already recycled the WAL it needs. It runs the real `pgtwin` agent against a throw-away
PostgreSQL 18 primary/standby pair. The OCF and Pacemaker tools are stubbed (`ocf/`, `bin/`). It does
not touch any cluster.

Requirements: `podman`, network access for `docker.io/library/postgres:18-trixie`.

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
