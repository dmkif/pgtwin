#!/bin/bash
# Unit tests for the sync promote/demote gate (no PostgreSQL and no Pacemaker needed).
# Usage: bash test/test-sync-gate.sh
#
# Node names contain a hyphen ("pg-a"), their application_name an underscore ("pg_a"): get_application_name()
# maps '-' to '_'. Comparing the two directly never matches, so every test below uses hyphenated node names on
# purpose. See doc/FEATURE_SYNC_PROMOTE_DEMOTE_GATE.md.
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"

extract() {
    awk -v name="$1" '
        $0 ~ "^"name"\\(\\) \\{" { p=1 }
        p { print }
        p && /^}/ { p=0 }
    ' "$AGENT"
}
for f in update_confirmed_sync_attribute promotion_sync_state_guard peer_is_primary; do
    code=$(extract $f)
    [ -n "$code" ] || { echo "FAIL: function $f not found in agent"; exit 1; }
    eval "$code"
done
# Helpers that map application_name to node names. If an agent version lacks them, the tests that need them fail
# (instead of aborting), which is how the hyphen/underscore mismatch shows up on agents without the mapping.
for f in node_name_for_application_name confirmed_sync_standby_as_node; do
    code=$(extract $f)
    if [ -n "$code" ]; then eval "$code"; else echo "NOTE: $f is missing in this agent"; eval "$f() { return 1; }"; fi
done

# The block of pgsql_monitor() that records which standby is confirmed synchronous.
MON=$(awk '/OCF_RESKEY_rep_mode}" = "sync" \] && \[ -n "\$\{OCF_RESKEY_node_list\}" \]; then/ && !d { p=1; d=1 }
           p { print } p && /^        fi$/ { p=0 }' "$AGENT")
[ -n "$MON" ] || { echo "FAIL: confirmed-sync block not found in pgsql_monitor()"; exit 1; }
eval "monitor_sync_block() {
$MON
}"

# ---- stubs ----
STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT
ocf_log() { :; }
crm_attribute() {   # file-backed: -N node -n name [-G -q | -v value]
    local n= k= v= g=0
    while [ $# -gt 0 ]; do
        case "$1" in -N) n=$2; shift;; -n) k=$2; shift;; -v) v=$2; shift;; -G) g=1;; esac
        shift
    done
    if [ $g = 1 ]; then [ -f "$STORE/${n}__${k}" ] && cat "$STORE/${n}__${k}"; return 0; fi
    echo "$v" > "$STORE/${n}__${k}"
}
get_cluster_node_name() { echo "$FAKE_NODE"; }
hostname() { echo "$FAKE_NODE"; }
get_application_name() { APPLICATION_NAME=$(echo "$FAKE_NODE" | tr '-' '_'); }
discover_promoted_node() { echo "$FAKE_PRIMARY"; }
resolve_cluster_node_to_hostname() { echo "$1"; }
get_peer_member_name() { echo "$FAKE_PEER"; }
get_confirmed_sync_standby() { echo "$FAKE_CONFIRMED"; }
run_as_pguser() { "$@"; }
PSQL="$STORE/fake-psql"; printf '#!/bin/sh\ncase "$*" in *pg_is_in_recovery*) echo "$FAKE_IN_RECOVERY";; *) echo "$FAKE_SYNC_STATE";; esac\n' > "$PSQL"; chmod +x "$PSQL"

fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "PASS: $desc"; else echo "FAIL: $desc (expected '$expected', got '$actual')"; fail=$((fail + 1)); fi
}
reset() { rm -f "$STORE"/*__*; FAKE_PEER=pg-b; FAKE_NODE=pg-a; FAKE_PRIMARY=; FAKE_CONFIRMED=; FAKE_SYNC_STATE=
          OCF_RESKEY_node_list="pg-a pg-b"; OCF_RESKEY_rep_mode=sync; OCF_RESKEY_force_promotion=false; export FAKE_SYNC_STATE FAKE_IN_RECOVERY FAKE_PEER; }

# ---- node_name_for_application_name ----
reset
check "pg_b maps to pg-b"                       pg-b "$(node_name_for_application_name pg_b)"
check "pg_a maps to pg-a"                       pg-a "$(node_name_for_application_name pg_a)"
check "unknown name maps to nothing"            ""   "$(node_name_for_application_name other_node)"
check "empty name maps to nothing"              ""   "$(node_name_for_application_name '')"
OCF_RESKEY_node_list="psql1 psql2"
check "node name without hyphen is unchanged"   psql2 "$(node_name_for_application_name psql2)"
OCF_RESKEY_node_list="db-node-1 db-node-2"
check "several hyphens"                         db-node-2 "$(node_name_for_application_name db_node_2)"

# ---- confirmed_sync_standby_as_node (demote target) ----
reset
check "demote target is the peer"               pg-b "$(confirmed_sync_standby_as_node pg_b)"
check "demote target is never this node"        ""   "$(confirmed_sync_standby_as_node pg_a)"
check "unmappable name gives no target"         ""   "$(confirmed_sync_standby_as_node nope)"
FAKE_NODE=pg-b
check "same on the other node"                  pg-a "$(confirmed_sync_standby_as_node pg_a)"

# ---- the block in pgsql_monitor() that records the confirmed standby ----
reset; FAKE_CONFIRMED=pg_b; monitor_sync_block >/dev/null 2>&1
check "healthy sync standby is recorded as 1"   1 "$(crm_attribute -N pg-b -n pgtwin-confirmed-synced -G -q)"
reset; FAKE_CONFIRMED=; monitor_sync_block >/dev/null 2>&1
check "no sync standby is recorded as 0"        0 "$(crm_attribute -N pg-b -n pgtwin-confirmed-synced -G -q)"
reset; crm_attribute -N pg-b -n pgtwin-confirmed-synced -v 1; FAKE_CONFIRMED=; monitor_sync_block >/dev/null 2>&1
check "standby that left flips 1 to 0"          0 "$(crm_attribute -N pg-b -n pgtwin-confirmed-synced -G -q)"
reset; FAKE_CONFIRMED=pg_b; monitor_sync_block >/dev/null 2>&1
check "own node is not written"                 "" "$(crm_attribute -N pg-a -n pgtwin-confirmed-synced -G -q)"

# ---- promotion_sync_state_guard ----
reset; FAKE_NODE=pg-b
OCF_RESKEY_rep_mode=async;                       promotion_sync_state_guard; check "async mode: guard is a no-op"        0 $?
reset; FAKE_NODE=pg-b; OCF_RESKEY_force_promotion=true; promotion_sync_state_guard; check "force_promotion bypasses"     0 $?
reset; FAKE_NODE=pg-b; FAKE_PRIMARY=pg-a; FAKE_SYNC_STATE=sync;      promotion_sync_state_guard; check "live: sync -> promote"      0 $?
reset; FAKE_NODE=pg-b; FAKE_PRIMARY=pg-a; FAKE_SYNC_STATE=potential; promotion_sync_state_guard; check "live: potential -> refuse" 1 $?
reset; FAKE_NODE=pg-b; FAKE_PRIMARY=pg-a; FAKE_SYNC_STATE=;          promotion_sync_state_guard; check "live: not listed -> refuse" 1 $?
reset; FAKE_NODE=pg-b; crm_attribute -N pg-b -n pgtwin-confirmed-synced -v 1; promotion_sync_state_guard; check "no primary, cached 1 -> promote" 0 $?
reset; FAKE_NODE=pg-b; crm_attribute -N pg-b -n pgtwin-confirmed-synced -v 0; promotion_sync_state_guard; check "no primary, cached 0 -> refuse"  1 $?
reset; FAKE_NODE=pg-b;                                                        promotion_sync_state_guard; check "no primary, unset -> refuse"     1 $?

# ---- peer_is_primary (decides whether the demote needs the synchronous-standby check) ----
reset; FAKE_IN_RECOVERY=f; peer_is_primary; check "peer is the primary: stale node may demote"   0 $?
reset; FAKE_IN_RECOVERY=t; peer_is_primary; check "peer is a standby: check applies"            1 $?
reset; FAKE_IN_RECOVERY=;  peer_is_primary; check "peer does not answer: check applies"         1 $?
reset; FAKE_IN_RECOVERY=f; FAKE_PEER=;     peer_is_primary; check "no peer member: check applies" 1 $?

# ---- end to end: what the primary records must be what the standby reads after the primary is gone ----
reset; FAKE_NODE=pg-a; FAKE_CONFIRMED=pg_b; monitor_sync_block >/dev/null 2>&1   # primary pg-a observes pg-b as sync
FAKE_NODE=pg-b; FAKE_PRIMARY=; promotion_sync_state_guard                        # primary is gone, pg-b decides
check "primary recorded pg-b as synced, pg-b may promote after the crash" 0 $?

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit $fail
