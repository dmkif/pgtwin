#!/bin/bash
# Consistent standby (base backup with its WAL), configured with primary_slot_name = ha_slot, stopped cleanly.
# The slot does NOT exist on the primary (never created, dropped by check_replication_slots(), or a rebuilt primary).
set -euo pipefail
PGBIN=/usr/lib/postgresql/18/bin
podman exec -u postgres pgs sh -c "PGPASSFILE=/var/lib/postgresql/.pgpass $PGBIN/pg_basebackup -h pgp -U replicator -D /var/lib/pgsql/data -R -X stream -c fast -d application_name=pg_s && chmod 700 /var/lib/pgsql/data"
printf "primary_slot_name = 'ha_slot'\nlogging_collector = on\nlog_directory = 'log'\nlisten_addresses = '*'\n" | podman exec -i -u postgres pgs sh -c 'cat >> /var/lib/pgsql/data/postgresql.auto.conf'
echo "consistent standby built; slot on primary: $(podman exec pgp psql -U postgres -Atc "select count(*) from pg_replication_slots where slot_name='ha_slot'")"
