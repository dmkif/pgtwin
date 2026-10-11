export OCF_ROOT=/harness/ocf OCF_FUNCTIONS_DIR=/harness/ocf/lib/heartbeat
export OCF_RESOURCE_INSTANCE=pgtwin-pg:0 OCF_RESKEY_CRM_meta_clone=0
export OCF_RESKEY_pgdata=/var/lib/pgsql/data OCF_RESKEY_pg_bindir=/usr/lib/postgresql/18/bin
export OCF_RESKEY_pgport=5432 OCF_RESKEY_node_list="pgp pgs" OCF_RESKEY_rep_mode=async
export OCF_RESKEY_pgpassfile=/var/lib/postgresql/.pgpass OCF_RESKEY_application_name=pg_s
export OCF_RESKEY_backup_before_basebackup=true OCF_RESKEY_slot_name=ha_slot
export PATH=/harness/bin:$PATH
export HOME=/var/lib/postgresql
