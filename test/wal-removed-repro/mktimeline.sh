#!/bin/bash
# Diverged timeline, like the 2026-10-10 case: the standby was shut down in recovery on timeline 1,
# the primary then restarted as a standby and was promoted (timeline 2), and the WAL the standby
# needs is gone. Run after setup.sh + mkstandby.sh, before churn.sh.
set -euo pipefail
PGBIN=/usr/lib/postgresql/18/bin
# standby: start from the backup_label, then stop -> control file "shut down in recovery"
podman exec -u postgres pgs sh -c "$PGBIN/pg_ctl -D /var/lib/pgsql/data -W start >/dev/null; sleep 5; $PGBIN/pg_ctl -D /var/lib/pgsql/data -m fast -w stop >/dev/null"
podman exec -u postgres pgs $PGBIN/pg_controldata /var/lib/pgsql/data | grep -iE "cluster state|checkpoint.s TimeLineID"
# primary: WAL after the standby left, stop it (container exits), add standby.signal, start, promote
PGD=$(podman exec pgp printenv PGDATA)
podman exec pgp psql -U postgres -qc "CREATE TABLE IF NOT EXISTS t(x text); INSERT INTO t SELECT repeat('x',1000) FROM generate_series(1,2000); CHECKPOINT"
podman exec -u postgres pgp pg_ctl -D "$PGD" -m fast -w stop >/dev/null || true
for i in $(seq 20); do [ "$(podman inspect -f '{{.State.Running}}' pgp)" = false ] && break; sleep 1; done
touch "$PWD/.standby.signal.tmp"
podman cp "$PWD/.standby.signal.tmp" "pgp:$PGD/standby.signal"
rm -f "$PWD/.standby.signal.tmp"
podman start pgp >/dev/null
for i in $(seq 30); do podman exec pgp pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
podman exec pgp psql -U postgres -Atc "select pg_promote(true, 30)"
podman exec pgp psql -U postgres -Atc "select timeline_id from pg_control_checkpoint()"
# the primary has the slot, but it was created after the WAL was recycled (restart_lsn is newer than what the
# standby needs), so the error is "WAL segment has already been removed", not "slot does not exist"
[ -n "${NO_SLOT:-}" ] || podman exec pgp psql -U postgres -qc "SELECT pg_create_physical_replication_slot('ha_slot', true)" >/dev/null
