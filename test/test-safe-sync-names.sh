#!/bin/bash
# Unit test for get_safe_synchronous_standby_names() with hyphenated node names (no PostgreSQL, no Pacemaker needed).
# Usage: bash test/test-safe-sync-names.sh
#
# The cluster reports the node "pg-b"; the standby connects with application_name "pg_b" (get_application_name()
# maps '-' to '_'). The function has to match the two and return the application_name, otherwise it logs a mismatch
# warning on every monitor and falls back to '*'.
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"

code=$(awk '/^get_safe_synchronous_standby_names\(\) \{/ { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT")
[ -n "$code" ] || { echo "FAIL: get_safe_synchronous_standby_names not found in agent"; exit 1; }
eval "$code"

# ---- stubs ----
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
ocf_log() { echo "$1 $2" >> "$LOG"; }
crm_mon() { echo "<xml/>"; }
xmllint() {   # first call asks for the clone id, second for the Unpromoted node names
    case "$*" in *"string("*) echo "pgtwin-ms";; *) echo "name=\"$EXPECTED\"";; esac
}
run_as_pguser() { printf '%s' "$CONNECTED"; }
PSQL=psql
OCF_RESOURCE_INSTANCE="pgtwin-pg:0"; OCF_RESKEY_pgport=5432

pass=0; fail=0
check() {   # description expected-output expected-warning(0|1)
    : > "$LOG"
    got=$(get_safe_synchronous_standby_names)
    warned=0; grep -q "mismatch" "$LOG" && warned=1
    if [ "$got" = "$2" ] && [ "$warned" = "$3" ]; then pass=$((pass+1)); echo "PASS: $1"
    else fail=$((fail+1)); echo "FAIL: $1 (got '$got', mismatch warning=$warned; wanted '$2', $3)"; fi
}

EXPECTED="pg-b";            CONNECTED="pg_b";       check "hyphenated node, underscore application_name" "pg_b" 0
EXPECTED="pg-b.example.org"; CONNECTED="pg_b";      check "FQDN node name" "pg_b" 0
EXPECTED="psql1";           CONNECTED="psql1";      check "plain node name unchanged" "psql1" 0
EXPECTED="pg-b";            CONNECTED="other_host"; check "streaming standby with an unrelated name still falls back to '*'" "*" 1
EXPECTED="pg-b";            CONNECTED="";           check "no standby connected: async" "" 0

echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
