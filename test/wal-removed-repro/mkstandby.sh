#!/bin/bash
# standby from pg_basebackup (no slot -> primary will not hold WAL), then stopped
set -euo pipefail
podman exec -u postgres pgs sh -c 'PGPASSFILE=/var/lib/postgresql/.pgpass /usr/lib/postgresql/18/bin/pg_basebackup -h pgp -U replicator -D /var/lib/pgsql/data -R -X none -c fast -d "application_name=pg_s" && chmod 700 /var/lib/pgsql/data'
echo "standby built + stopped"
