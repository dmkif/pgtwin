#!/bin/bash
# Does the slot created at promote time protect the WAL a returning standby needs?
# usage: ./slotcheck.sh <path-to-pgtwin>   (runs create_replication_slot() from that file on the primary)
set -euo pipefail
RA=${1:?path to pgtwin}
PGBIN=/usr/lib/postgresql/18/bin
./setup.sh | tail -1
# standby with a consistent backup (-X stream), connected via the slot name, then stopped cleanly
podman exec -u postgres pgs sh -c "PGPASSFILE=/var/lib/postgresql/.pgpass $PGBIN/pg_basebackup -h pgp -U replicator -D /var/lib/pgsql/data -R -X stream -c fast -d application_name=pg_s && printf \"logging_collector = on\\nlog_directory = 'log'\\nlisten_addresses = '*'\\n\" >> /var/lib/pgsql/data/postgresql.auto.conf && chmod 700 /var/lib/pgsql/data && echo \"primary_slot_name = 'ha_slot'\" >> /var/lib/pgsql/data/postgresql.auto.conf"
# promote-time slot creation, exactly the RA function (a standby cannot use a slot that does not exist yet)
podman cp "$RA" pgp:/tmp/ra
podman exec pgp bash -c '
  OCF_RESKEY_slot_name=ha_slot OCF_RESKEY_pgport=5432 OCF_RESKEY_pguser=postgres PSQL=psql
  ocf_log() { :; }; run_as_pguser() { setpriv --reuid=postgres --regid=postgres --clear-groups "$@"; }
  eval "$(sed -n "/^create_replication_slot() {/,/^}/p" /tmp/ra)"
  create_replication_slot'
podman exec pgp psql -U postgres -Atc "select 'slot restart_lsn after creation: ' || coalesce(restart_lsn::text,'NULL (nothing reserved)') from pg_replication_slots"
# standby is away, primary keeps running and recycles WAL
./churn.sh >/dev/null 2>&1 || true
podman exec pgp psql -U postgres -qc "INSERT INTO t SELECT repeat('x',1000) FROM generate_series(1,40000); SELECT pg_switch_wal(); CHECKPOINT" >/dev/null
# standby comes back
podman exec -u postgres pgs sh -c "$PGBIN/pg_ctl -D /var/lib/pgsql/data -W start >/dev/null"; sleep 8
podman exec pgp psql -U postgres -Atc "select 'primary sees: ' || coalesce((select state from pg_stat_replication limit 1),'no standby streaming')"
podman exec pgs sh -c 'grep -ho "requested WAL segment [0-9A-F]* has already been removed\|replication slot .* does not exist" /var/lib/pgsql/data/log/*.log 2>/dev/null | sort -u | head -2; tail -2 /var/lib/pgsql/data/log/*.log 2>/dev/null | cut -c1-200' || true
