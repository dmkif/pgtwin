#!/bin/bash
# Unit tests for the data-state comparison used before promotion (no PostgreSQL needed).
# Usage: bash test/test-promotion-data-state.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"

# Load only the pure functions from the agent (no OCF environment needed).
extract() {
    awk -v name="$1" '
        $0 ~ "^"name"\\(\\) \\{" { p=1 }
        p { print }
        p && /^}/ { p=0 }
    ' "$AGENT"
}
for f in lsn_to_int data_state_compare promotion_decision; do
    eval "$(extract $f)"
done

fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

# lsn_to_int
check "lsn 0/10"              16            "$(lsn_to_int 0/10)"
check "lsn 1/0"               4294967296    "$(lsn_to_int 1/0)"
check "lsn invalid"           ""            "$(lsn_to_int garbage)"
check "lsn empty"             ""            "$(lsn_to_int '')"
check "lsn spellings equal"   "$(lsn_to_int 0/F229540)" "$(lsn_to_int 0/0F229540)"

# data_state_compare (a relative to b)
check "same tli, higher lsn"      newer "$(data_state_compare 5 0/20 5 0/10)"
check "same tli, lower lsn"       older "$(data_state_compare 5 0/10 5 0/20)"
check "equal"                     equal "$(data_state_compare 5 0/10 5 0/10)"
check "higher tli, lower lsn"     newer "$(data_state_compare 6 0/10 5 0/20)"
check "lower tli, higher lsn"     older "$(data_state_compare 5 0/20 6 0/10)"
check "segment boundary"          older "$(data_state_compare 5 0/FFFFFFF0 5 1/00000010)"
check "invalid lsn"               ""    "$(data_state_compare 5 xx 5 0/10; true)"

# promotion_decision: local_tli local_lsn peer_tli peer_lsn local_name peer_name waited limit
check "peer newer -> refuse"            refuse "$(promotion_decision 5 0/10 5 0/20 pg-a pg-b 0 60)"
check "peer older -> promote"           promote "$(promotion_decision 5 0/20 5 0/10 pg-a pg-b 0 60)"
check "peer higher tli -> refuse"       refuse "$(promotion_decision 5 0/FF 6 0/10 pg-a pg-b 0 60)"
check "equal, smaller name -> promote"  promote "$(promotion_decision 5 0/10 5 0/10 pg-a pg-b 0 60)"
check "equal, larger name -> refuse"    refuse "$(promotion_decision 5 0/10 5 0/10 pg-b pg-a 0 60)"
check "peer unknown, waiting"           wait "$(promotion_decision 5 0/10 unknown unknown pg-a pg-b 10 60)"
check "peer unknown, limit reached"     promote-peer-unreachable "$(promotion_decision 5 0/10 unknown unknown pg-a pg-b 60 60)"
check "peer unknown, hard limit"        promote-peer-unreachable "$(promotion_decision 5 0/10 unknown unknown pg-a pg-b 100 100)"
check "peer garbage lsn, waiting"       wait "$(promotion_decision 5 0/10 5 garbage pg-a pg-b 1 60)"
check "peer garbage lsn, limit"         promote-peer-unreachable "$(promotion_decision 5 0/10 5 garbage pg-a pg-b 60 60)"
check "symmetry: only one side promotes (a)" promote "$(promotion_decision 5 0/10 5 0/10 pg-a pg-b 0 60)"
check "symmetry: only one side promotes (b)" refuse "$(promotion_decision 5 0/10 5 0/10 pg-b pg-a 0 60)"

# force_promotion bypass and disabled comparison live in check_promotion_safety /
# promotion_data_state_guard; verified by static grep so a refactor cannot drop them silently.
grep -q 'force_promotion=true - BYPASSING ALL SAFETY CHECKS' "$AGENT" && \
    awk '/^check_promotion_safety\(\)/{f=1} f&&/force_promotion/{print NR; exit}' "$AGENT" | grep -q . && \
    check "force_promotion check precedes the guard" yes yes
grep -q 'promotion_data_state_guard || return 1' "$AGENT" && check "guard is wired into check_promotion_safety" yes yes

grep -q "start_as_standby_for_data_comparison; then" "$AGENT" && check "former primary start is wired to the comparison" yes yes

if [ $fail -eq 0 ]; then echo "All tests passed"; exit 0; else echo "$fail test(s) failed"; exit 1; fi
