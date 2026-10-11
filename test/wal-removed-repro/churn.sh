#!/bin/bash
# produce WAL on primary until the standby's redo segment is recycled
set -euo pipefail
REDO=$(podman exec -u postgres pgs /usr/lib/postgresql/18/bin/pg_controldata /var/lib/pgsql/data | awk -F: '/REDO WAL file/{gsub(/ /,"",$2);print $2}')
echo "standby needs WAL file: $REDO"
podman exec pgp psql -U postgres -qc "CREATE TABLE IF NOT EXISTS t(x text)"
for i in $(seq 1 12); do
  podman exec pgp psql -U postgres -qc "INSERT INTO t SELECT repeat('x',1000) FROM generate_series(1,40000); SELECT pg_switch_wal(); CHECKPOINT" >/dev/null
  if ! podman exec pgp sh -c 'ls $PGDATA/pg_wal' | grep -q "^$REDO$"; then echo "segment $REDO gone after $i rounds"; exit 0; fi
done
echo "segment still present"; exit 1
