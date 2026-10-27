#!/bin/bash
# Unit test for no_primary_in_cluster(): the check that lets a standby stay eligible for promotion
# when no primary exists anywhere (no PostgreSQL and no Pacemaker needed).
# Usage: bash test/test-cold-start-eligible.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT"; }
code=$(extract no_primary_in_cluster); [ -n "$code" ] || { echo "FAIL: no_primary_in_cluster not found in agent"; exit 1; }
eval "$code"

STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT
OCF_RESKEY_pgport=5432
PSQL="$STORE/fake-psql"; printf '#!/bin/sh\necho "$FAKE_IN_RECOVERY"\n' > "$PSQL"; chmod +x "$PSQL"
run_as_pguser() { "$@"; }
resolve_cluster_node_to_hostname() { echo "$1"; }
get_peer_member_name() { echo "$FAKE_PEER"; }

fail=0
export FAKE_IN_RECOVERY FAKE_PEER
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }

FAKE_PEER=pg-b; FAKE_IN_RECOVERY=t; no_primary_in_cluster; check "peer is a standby too -> no primary" 0 $?
FAKE_PEER=pg-b; FAKE_IN_RECOVERY=f; no_primary_in_cluster; check "peer is the primary -> veto stays"   1 $?
FAKE_PEER=pg-b; FAKE_IN_RECOVERY=;  no_primary_in_cluster; check "peer does not answer -> veto stays"  1 $?
FAKE_PEER=;     FAKE_IN_RECOVERY=t; no_primary_in_cluster; check "no peer member -> veto stays"         1 $?

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit $fail
