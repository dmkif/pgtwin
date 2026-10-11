#!/bin/bash
# builds: primary (pgp) + standby container (pgs) with a standby whose needed WAL is gone
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
IMG=docker.io/library/postgres:18-trixie
podman rm -f pgp pgs >/dev/null 2>&1 || true
podman network exists pgnet || podman network create pgnet >/dev/null
podman run -d --name pgp --hostname pgp --network pgnet -e POSTGRES_PASSWORD=pw $IMG \
  -c wal_level=replica -c max_wal_senders=10 -c max_replication_slots=10 -c hot_standby=on \
  -c wal_keep_size=0 -c min_wal_size=32MB -c max_wal_size=48MB -c listen_addresses='*' >/dev/null
for i in $(seq 30); do podman exec pgp pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
podman exec pgp psql -U postgres -qc "CREATE ROLE replicator REPLICATION LOGIN PASSWORD 'secret'"
# as in docs/pgtwin-sbd-pacemaker-setup.md: without these pg_rewind always fails and pgtwin silently uses a basebackup
podman exec pgp psql -U postgres -qc "GRANT EXECUTE ON FUNCTION pg_read_binary_file(text) TO replicator; GRANT EXECUTE ON FUNCTION pg_read_binary_file(text, bigint, bigint, boolean) TO replicator; GRANT EXECUTE ON FUNCTION pg_stat_file(text) TO replicator; GRANT EXECUTE ON FUNCTION pg_stat_file(text, boolean) TO replicator; GRANT EXECUTE ON FUNCTION pg_ls_dir(text) TO replicator; GRANT EXECUTE ON FUNCTION pg_ls_dir(text, boolean, boolean) TO replicator"
podman exec pgp sh -c 'printf "host all postgres all trust\nhost replication all all scram-sha-256\n" | cat - $PGDATA/pg_hba.conf > /tmp/h && cat /tmp/h > $PGDATA/pg_hba.conf'
podman exec pgp psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null
podman run -d --init --name pgs --hostname pgs --network pgnet -v $H:/harness:ro,z --entrypoint sleep $IMG infinity >/dev/null
podman exec pgs sh -c 'mkdir -p /var/lib/pgsql && chown postgres:postgres /var/lib/pgsql && printf "pgp:5432:replication:replicator:secret\npgp:5432:postgres:replicator:secret\n" > /var/lib/postgresql/.pgpass && chown postgres:postgres /var/lib/postgresql/.pgpass && chmod 600 /var/lib/postgresql/.pgpass'
echo "setup done"
