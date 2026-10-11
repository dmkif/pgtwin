#!/bin/bash
# Like mkstandby.sh, but the base backup's checkpoint record lands in a LATER WAL segment than its redo
# point (spread checkpoint + WAL switches meanwhile, as pg-b had: redo 18/97440A58, checkpoint 18/985134C0).
# The segment holding the redo point is then deleted locally. Result: the standby cannot start
# (redo segment missing) but pg_rewind can still read the checkpoint record -> "no rewind required".
set -euo pipefail
PGBIN=/usr/lib/postgresql/18/bin
podman exec pgp psql -U postgres -qc "ALTER SYSTEM SET checkpoint_timeout='30s'" -qc "ALTER SYSTEM SET checkpoint_completion_target=0.9" -qc "SELECT pg_reload_conf()" >/dev/null
podman exec pgp psql -U postgres -qc "CREATE TABLE IF NOT EXISTS t(x text)"
podman exec -u postgres pgs sh -c "PGPASSFILE=/var/lib/postgresql/.pgpass $PGBIN/pg_basebackup -h pgp -U replicator -D /var/lib/pgsql/data -R -X stream -c spread -d application_name=pg_s" &
BB=$!
sleep 3
for i in $(seq 1 7); do   # ~25 s of WAL + segment switches while the spread checkpoint runs
  podman exec pgp psql -U postgres -qc "INSERT INTO t SELECT repeat('x',1000) FROM generate_series(1,20000); SELECT pg_switch_wal()" >/dev/null
  sleep 3
done
wait $BB
podman exec -u postgres pgs chmod 700 /var/lib/pgsql/data
printf "logging_collector = on\nlog_directory = 'log'\nlisten_addresses = '*'\n" | podman exec -i -u postgres pgs sh -c 'cat >> /var/lib/pgsql/data/postgresql.auto.conf'
CD=$(podman exec -u postgres pgs $PGBIN/pg_controldata /var/lib/pgsql/data)
echo "$CD" | grep -E "Latest checkpoint location|REDO location|REDO WAL file"
REDO=$(echo "$CD" | awk -F: '/REDO WAL file/{gsub(/ /,"",$2);print $2}')
podman exec -u postgres pgs rm -f "/var/lib/pgsql/data/pg_wal/$REDO"
echo "removed local redo segment $REDO; local pg_wal:"; podman exec pgs ls /var/lib/pgsql/data/pg_wal
