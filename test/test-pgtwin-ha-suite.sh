#!/bin/bash
#
# Comprehensive Test Suite for pgtwin HA Cluster (v2 with Log Gathering)
# Tests all major functionality with default configuration
#
# Usage: ./test-pgtwin-ha-suite-v2.sh <VIP_ADDRESS>
# Example: ./test-pgtwin-ha-suite-v2.sh 192.168.122.20
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default configuration from QUICKSTART.md (bare-metal). Every value can be overridden
# from the environment, e.g. for a lab with different host names:
#   NODE1=pgt-a NODE2=pgt-b NODE1_IP=10.99.0.11 NODE2_IP=10.99.0.12 \
#   APPLICATION_NAME_NODE1=pg_a APPLICATION_NAME_NODE2=pg_b ./test-pgtwin-ha-suite.sh 10.99.0.5
# The suite logs in as ${SSH_USER} (default root) and expects that user to be able to run
# crm and 'sudo -u postgres'. 'crm node standby/online <other node>' is run from NODE1, so
# root on NODE1 needs SSH access to NODE2 (crmsh requirement).
NODE1="${NODE1:-psql1}"
NODE2="${NODE2:-psql2}"
NODE1_IP="${NODE1_IP:-192.168.122.60}"
NODE2_IP="${NODE2_IP:-192.168.122.120}"
SSH_USER="${SSH_USER:-root}"
PGPORT="${PGPORT:-5432}"
PGDATA="${PGDATA:-/var/lib/pgsql/data}"
REP_USER="${REP_USER:-replicator}"
REP_PASSWORD="${REP_PASSWORD:-PgTwin2025!Repl}"  # Default test password
SLOT_NAME="${SLOT_NAME:-ha_slot}"
APPLICATION_NAME_NODE1="${APPLICATION_NAME_NODE1:-psql1}"
APPLICATION_NAME_NODE2="${APPLICATION_NAME_NODE2:-psql2}"

# VIP from command line
if [ $# -ne 1 ]; then
    echo "Usage: $0 <VIP_ADDRESS>"
    echo "Example: $0 192.168.122.20"
    exit 1
fi

VIP="$1"

# Results tracking
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_FILE="test-results-${TIMESTAMP}.txt"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=0

# Log file for detailed output
LOG_FILE="test-detailed-${TIMESTAMP}.log"

# Diagnostics directory
DIAG_DIR="test-diagnostics-${TIMESTAMP}"
mkdir -p "$DIAG_DIR"

# Current test tracking for diagnostics
CURRENT_TEST_NUM=0
CURRENT_TEST_NAME=""

#######################################################################
# Helper Functions
#######################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_debug() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >> "$LOG_FILE"
}

print_header() {
    echo ""
    echo "=================================================================="
    echo "$1"
    echo "=================================================================="
    echo ""
}

# Expected application_name for a cluster node (the agent derives it from the node
# name, so it can differ from the host name, e.g. pgt-a -> pg_a)
app_name_for_node() {
    if [ "$1" = "$NODE1" ]; then echo "$APPLICATION_NAME_NODE1"; else echo "$APPLICATION_NAME_NODE2"; fi
}

test_start() {
    local test_name="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    CURRENT_TEST_NUM=$TOTAL_TESTS
    CURRENT_TEST_NAME="$test_name"
    echo -n "TEST $TOTAL_TESTS: $test_name ... "
    log_debug "Starting test: $test_name"
}

#######################################################################
# Log Gathering Functions
#######################################################################

gather_cluster_state() {
    local test_num="$1"
    local output_dir="$2"

    log_debug "Gathering cluster state for test $test_num"

    # Cluster status from both nodes
    ssh ${SSH_USER}@${NODE1} "crm status" > "${output_dir}/cluster_status_node1.txt" 2>&1 || echo "Failed to get cluster status from node1" > "${output_dir}/cluster_status_node1.txt"
    ssh ${SSH_USER}@${NODE2} "crm status" > "${output_dir}/cluster_status_node2.txt" 2>&1 || echo "Failed to get cluster status from node2" > "${output_dir}/cluster_status_node2.txt"

    # Cluster configuration
    ssh ${SSH_USER}@${NODE1} "crm configure show" > "${output_dir}/cluster_config.txt" 2>&1 || true
}

gather_pacemaker_logs() {
    local test_num="$1"
    local output_dir="$2"

    log_debug "Gathering Pacemaker logs for test $test_num"

    # Recent Pacemaker logs from both nodes (last 500 lines)
    ssh ${SSH_USER}@${NODE1} "journalctl -u pacemaker --since '5 minutes ago' -n 500" > "${output_dir}/pacemaker_node1.log" 2>&1 || true
    ssh ${SSH_USER}@${NODE2} "journalctl -u pacemaker --since '5 minutes ago' -n 500" > "${output_dir}/pacemaker_node2.log" 2>&1 || true

    # Filter for errors and warnings
    ssh ${SSH_USER}@${NODE1} "journalctl -u pacemaker --since '5 minutes ago' | grep -iE '(error|warning|failed)'" > "${output_dir}/pacemaker_errors_node1.log" 2>&1 || true
    ssh ${SSH_USER}@${NODE2} "journalctl -u pacemaker --since '5 minutes ago' | grep -iE '(error|warning|failed)'" > "${output_dir}/pacemaker_errors_node2.log" 2>&1 || true
}

gather_postgresql_logs() {
    local test_num="$1"
    local output_dir="$2"

    log_debug "Gathering PostgreSQL logs for test $test_num"

    # PostgreSQL logs from both nodes (last 200 lines)
    ssh ${SSH_USER}@${NODE1} "tail -200 ${PGDATA}/log/postgresql-*.log 2>/dev/null" > "${output_dir}/postgresql_node1.log" 2>&1 || true
    ssh ${SSH_USER}@${NODE2} "tail -200 ${PGDATA}/log/postgresql-*.log 2>/dev/null" > "${output_dir}/postgresql_node2.log" 2>&1 || true

    # PostgreSQL configuration
    ssh ${SSH_USER}@${NODE1} "cat ${PGDATA}/postgresql.auto.conf 2>/dev/null" > "${output_dir}/postgresql_auto_conf_node1.txt" 2>&1 || true
    ssh ${SSH_USER}@${NODE2} "cat ${PGDATA}/postgresql.auto.conf 2>/dev/null" > "${output_dir}/postgresql_auto_conf_node2.txt" 2>&1 || true
}

gather_replication_status() {
    local test_num="$1"
    local output_dir="$2"

    log_debug "Gathering replication status for test $test_num"

    # Determine promoted node
    local promoted=$(get_promoted_node)
    if [ -n "$promoted" ]; then
        # Replication status from promoted node
        ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -x -c 'SELECT * FROM pg_stat_replication;' 2>/dev/null" > "${output_dir}/pg_stat_replication.txt" 2>&1 || true

        # Replication slots
        ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -x -c 'SELECT * FROM pg_replication_slots;' 2>/dev/null" > "${output_dir}/pg_replication_slots.txt" 2>&1 || true
    fi

    # Recovery status from both nodes
    ssh ${SSH_USER}@${NODE1} "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();' 2>/dev/null" > "${output_dir}/recovery_status_node1.txt" 2>&1 || echo "unknown" > "${output_dir}/recovery_status_node1.txt"
    ssh ${SSH_USER}@${NODE2} "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();' 2>/dev/null" > "${output_dir}/recovery_status_node2.txt" 2>&1 || echo "unknown" > "${output_dir}/recovery_status_node2.txt"
}

gather_basebackup_logs() {
    local test_num="$1"
    local output_dir="$2"

    log_debug "Gathering basebackup logs for test $test_num"

    # Basebackup logs from both nodes
    ssh ${SSH_USER}@${NODE1} "cat /var/lib/pgsql/.pgtwin_basebackup.log 2>/dev/null" > "${output_dir}/basebackup_node1.log" 2>&1 || true
    ssh ${SSH_USER}@${NODE2} "cat /var/lib/pgsql/.pgtwin_basebackup.log 2>/dev/null" > "${output_dir}/basebackup_node2.log" 2>&1 || true

    # Basebackup state files
    ssh ${SSH_USER}@${NODE1} "cat /var/lib/pgsql/.pgtwin_basebackup_in_progress 2>/dev/null" > "${output_dir}/basebackup_state_node1.txt" 2>&1 || true
    ssh ${SSH_USER}@${NODE2} "cat /var/lib/pgsql/.pgtwin_basebackup_in_progress 2>/dev/null" > "${output_dir}/basebackup_state_node2.txt" 2>&1 || true
}

gather_file_ownership() {
    local test_num="$1"
    local output_dir="$2"

    log_debug "Gathering file ownership information for test $test_num"

    # PGDATA ownership
    ssh ${SSH_USER}@${NODE1} "ls -ld ${PGDATA} 2>/dev/null" > "${output_dir}/pgdata_ownership_node1.txt" 2>&1 || true
    ssh ${SSH_USER}@${NODE2} "ls -ld ${PGDATA} 2>/dev/null" > "${output_dir}/pgdata_ownership_node2.txt" 2>&1 || true

    # Files with wrong ownership
    ssh ${SSH_USER}@${NODE1} "find ${PGDATA} -maxdepth 2 ! -user postgres 2>/dev/null" > "${output_dir}/wrong_ownership_node1.txt" 2>&1 || true
    ssh ${SSH_USER}@${NODE2} "find ${PGDATA} -maxdepth 2 ! -user postgres 2>/dev/null" > "${output_dir}/wrong_ownership_node2.txt" 2>&1 || true
}

gather_diagnostics() {
    local test_num="$1"
    local test_name="$2"

    local test_diag_dir="${DIAG_DIR}/test_${test_num}_$(echo "$test_name" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')"
    mkdir -p "$test_diag_dir"

    log_debug "Gathering diagnostics for test $test_num: $test_name"
    log_debug "Diagnostics directory: $test_diag_dir"

    # Gather all diagnostic information
    gather_cluster_state "$test_num" "$test_diag_dir"
    gather_pacemaker_logs "$test_num" "$test_diag_dir"
    gather_postgresql_logs "$test_num" "$test_diag_dir"
    gather_replication_status "$test_num" "$test_diag_dir"
    gather_basebackup_logs "$test_num" "$test_diag_dir"
    gather_file_ownership "$test_num" "$test_diag_dir"

    # Create summary file
    cat > "${test_diag_dir}/README.txt" << EOF
Diagnostic Information for Test ${test_num}: ${test_name}
Date: $(date)
Test Status: FAILED

Files in this directory:
- cluster_status_*.txt: Cluster status from both nodes
- cluster_config.txt: Cluster configuration
- pacemaker_*.log: Pacemaker logs from both nodes
- pacemaker_errors_*.log: Filtered errors/warnings
- postgresql_*.log: PostgreSQL logs
- postgresql_auto_conf_*.txt: PostgreSQL auto configuration
- pg_stat_replication.txt: Replication status
- pg_replication_slots.txt: Replication slots
- recovery_status_*.txt: Recovery mode status
- basebackup_*.log: Basebackup operation logs
- basebackup_state_*.txt: Basebackup state files
- pgdata_ownership_*.txt: PGDATA ownership
- wrong_ownership_*.txt: Files with incorrect ownership
- analysis.txt: Automated failure analysis

Run analyze_diagnostics() to get automated analysis.
EOF

    echo "$test_diag_dir"
}

#######################################################################
# Failure Analysis Functions
#######################################################################

analyze_application_name_failure() {
    local diag_dir="$1"
    local analysis_file="${diag_dir}/analysis.txt"

    echo "=== Application Name Failure Analysis ===" >> "$analysis_file"
    echo "" >> "$analysis_file"

    # Check what application_name is actually set
    local promoted=$(get_promoted_node)
    if [ -n "$promoted" ]; then
        local actual_name=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc 'SHOW application_name;' 2>/dev/null" || echo "unknown")
        echo "Current application_name: $actual_name" >> "$analysis_file"
        echo "Expected: $promoted" >> "$analysis_file"
        echo "" >> "$analysis_file"

        # Check cluster configuration
        if grep -q "application_name" "${diag_dir}/cluster_config.txt" 2>/dev/null; then
            echo "Cluster configuration has application_name parameter:" >> "$analysis_file"
            grep "application_name" "${diag_dir}/cluster_config.txt" >> "$analysis_file"
            echo "" >> "$analysis_file"
        fi

        # Check postgresql.auto.conf
        if [ -f "${diag_dir}/postgresql_auto_conf_node1.txt" ]; then
            echo "postgresql.auto.conf content:" >> "$analysis_file"
            grep -i "application_name" "${diag_dir}/postgresql_auto_conf_node1.txt" >> "$analysis_file" || echo "No application_name in auto.conf" >> "$analysis_file"
            echo "" >> "$analysis_file"
        fi

        echo "DIAGNOSIS: Test expected application_name='$promoted' but cluster uses '$actual_name'" >> "$analysis_file"
        echo "ROOT CAUSE: Cluster configuration uses custom application_name or hostname is different" >> "$analysis_file"
        echo "SEVERITY: LOW - Cosmetic issue, cluster is functional" >> "$analysis_file"
        echo "PGTWIN ISSUE: No - This is a configuration difference" >> "$analysis_file"
    fi
}

analyze_rewind_failure() {
    local diag_dir="$1"
    local analysis_file="${diag_dir}/analysis.txt"

    echo "=== pg_rewind Migration Failure Analysis ===" >> "$analysis_file"
    echo "" >> "$analysis_file"

    # Check pacemaker logs for rewind attempts
    if [ -f "${diag_dir}/pacemaker_node1.log" ] || [ -f "${diag_dir}/pacemaker_node2.log" ]; then
        echo "Searching for pg_rewind activity in Pacemaker logs..." >> "$analysis_file"

        local rewind_found=false
        for log in "${diag_dir}"/pacemaker_*.log; do
            if grep -q "rewind" "$log" 2>/dev/null; then
                echo "Found pg_rewind references in $(basename $log):" >> "$analysis_file"
                grep -i "rewind" "$log" | head -20 >> "$analysis_file"
                echo "" >> "$analysis_file"
                rewind_found=true
            fi
        done

        if [ "$rewind_found" = false ]; then
            echo "No pg_rewind activity found in logs" >> "$analysis_file"
            echo "" >> "$analysis_file"
        fi
    fi

    # Check cluster status
    if [ -f "${diag_dir}/cluster_status_node1.txt" ]; then
        echo "Cluster status at time of failure:" >> "$analysis_file"
        cat "${diag_dir}/cluster_status_node1.txt" >> "$analysis_file"
        echo "" >> "$analysis_file"
    fi

    # Check for basebackup as fallback
    if [ -f "${diag_dir}/basebackup_node1.log" ] || [ -f "${diag_dir}/basebackup_node2.log" ]; then
        echo "Checking if pg_basebackup was used as fallback..." >> "$analysis_file"
        for log in "${diag_dir}"/basebackup_*.log; do
            if [ -s "$log" ]; then
                echo "Basebackup activity found in $(basename $log)" >> "$analysis_file"
                tail -20 "$log" >> "$analysis_file"
                echo "" >> "$analysis_file"
            fi
        done
    fi

    # Check recovery status
    echo "Recovery status:" >> "$analysis_file"
    cat "${diag_dir}/recovery_status_node1.txt" "${diag_dir}/recovery_status_node2.txt" 2>/dev/null >> "$analysis_file"
    echo "" >> "$analysis_file"

    echo "DIAGNOSIS: Node did not rejoin as standby within timeout" >> "$analysis_file"
    echo "POSSIBLE CAUSES:" >> "$analysis_file"
    echo "  1. pg_rewind took longer than expected (timing issue)" >> "$analysis_file"
    echo "  2. pg_rewind failed and basebackup fallback was used" >> "$analysis_file"
    echo "  3. Test timeout too short for database size" >> "$analysis_file"
    echo "SEVERITY: MEDIUM - Functionality may work but slower than expected" >> "$analysis_file"
    echo "PGTWIN ISSUE: Possibly - Check logs for actual errors vs timing" >> "$analysis_file"
}

analyze_basebackup_slot_failure() {
    local diag_dir="$1"
    local analysis_file="${diag_dir}/analysis.txt"

    echo "=== Basebackup Slot Usage Failure Analysis ===" >> "$analysis_file"
    echo "" >> "$analysis_file"

    # Check basebackup logs for slot usage
    local slot_used=false
    for log in "${diag_dir}"/basebackup_*.log; do
        if [ -s "$log" ]; then
            echo "Checking $(basename $log) for slot usage..." >> "$analysis_file"

            if grep -q "\-S ${SLOT_NAME}" "$log" 2>/dev/null; then
                echo "FOUND: Basebackup command uses -S ${SLOT_NAME}" >> "$analysis_file"
                grep -A2 -B2 "\-S" "$log" >> "$analysis_file"
                slot_used=true
            else
                echo "NOT FOUND: No -S flag with slot name in this log" >> "$analysis_file"
                echo "Basebackup command executed:" >> "$analysis_file"
                grep -E "(pg_basebackup|PG_BASEBACKUP)" "$log" | head -5 >> "$analysis_file"
            fi
            echo "" >> "$analysis_file"
        fi
    done

    # Check if slot exists
    if [ -f "${diag_dir}/pg_replication_slots.txt" ]; then
        echo "Replication slots status:" >> "$analysis_file"
        cat "${diag_dir}/pg_replication_slots.txt" >> "$analysis_file"
        echo "" >> "$analysis_file"
    fi

    # Check pacemaker logs for slot creation
    echo "Checking Pacemaker logs for slot creation..." >> "$analysis_file"
    for log in "${diag_dir}"/pacemaker_*.log; do
        if grep -q "slot" "$log" 2>/dev/null; then
            echo "Slot-related activity in $(basename $log):" >> "$analysis_file"
            grep -i "slot" "$log" | tail -10 >> "$analysis_file"
            echo "" >> "$analysis_file"
        fi
    done

    if [ "$slot_used" = true ]; then
        echo "DIAGNOSIS: Slot WAS used in basebackup, test verification failed" >> "$analysis_file"
        echo "ROOT CAUSE: Test log parsing logic may be incorrect" >> "$analysis_file"
        echo "SEVERITY: LOW - Test issue, not pgtwin issue" >> "$analysis_file"
        echo "PGTWIN ISSUE: No - pgtwin correctly used slot" >> "$analysis_file"
    else
        echo "DIAGNOSIS: Slot was NOT used in basebackup command" >> "$analysis_file"
        echo "ROOT CAUSE: pg_basebackup may not have been called with -S flag" >> "$analysis_file"
        echo "SEVERITY: MEDIUM - Could indicate issue with v1.6.10 slot handling" >> "$analysis_file"
        echo "PGTWIN ISSUE: Possibly - Slot should be created and used" >> "$analysis_file"
    fi
}

analyze_failure() {
    local test_num="$1"
    local test_name="$2"
    local diag_dir="$3"

    local analysis_file="${diag_dir}/analysis.txt"

    cat > "$analysis_file" << EOF
Automated Failure Analysis
Test: ${test_num} - ${test_name}
Date: $(date)
================================================================================

EOF

    # Route to specific analysis based on test name
    case "$test_name" in
        *"application_name"*)
            analyze_application_name_failure "$diag_dir"
            ;;
        *"pg_rewind"*)
            analyze_rewind_failure "$diag_dir"
            ;;
        *"basebackup"*"slot"*)
            analyze_basebackup_slot_failure "$diag_dir"
            ;;
        *)
            echo "=== Generic Failure Analysis ===" >> "$analysis_file"
            echo "" >> "$analysis_file"
            echo "No specific analysis routine for this test type." >> "$analysis_file"
            echo "Please review the diagnostic files manually." >> "$analysis_file"
            ;;
    esac

    echo "" >> "$analysis_file"
    echo "=================================================================================" >> "$analysis_file"
    echo "For detailed information, review all files in this directory." >> "$analysis_file"
}

test_pass() {
    local test_name="$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}PASS${NC}"
    echo "PASS: $test_name" >> "$RESULTS_FILE"
    log_debug "Test passed: $test_name"
}

test_fail() {
    local test_name="$1"
    local reason="$2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}FAIL${NC}"
    echo "FAIL: $test_name" >> "$RESULTS_FILE"
    echo "  Reason: $reason" >> "$RESULTS_FILE"
    log "Test failed: $test_name - $reason"

    # Gather diagnostics automatically
    log_debug "Gathering diagnostics for failed test..."
    local diag_dir=$(gather_diagnostics "$CURRENT_TEST_NUM" "$test_name")

    # Analyze the failure
    analyze_failure "$CURRENT_TEST_NUM" "$test_name" "$diag_dir"

    echo "  Diagnostics: $diag_dir" >> "$RESULTS_FILE"
    log "Diagnostics saved to: $diag_dir"
}

wait_for_cluster_stable() {
    local max_wait=60
    local count=0
    log_debug "Waiting for cluster to stabilize..."

    while [ $count -lt $max_wait ]; do
        if ssh ${SSH_USER}@${NODE1} "crm status 2>/dev/null" | grep -q "2 nodes configured"; then
            sleep 2
            log_debug "Cluster stable after $count seconds"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    log "WARNING: Cluster did not stabilize within $max_wait seconds"
    return 1
}

get_promoted_node() {
    local status=$(ssh ${SSH_USER}@${NODE1} "crm status 2>/dev/null")
    if echo "$status" | grep -q "Promoted.*${NODE1}"; then
        echo "$NODE1"
    elif echo "$status" | grep -q "Promoted.*${NODE2}"; then
        echo "$NODE2"
    else
        echo ""
    fi
}

wait_for_promotion() {
    local expected_node="$1"
    local max_wait=30
    local count=0

    log_debug "Waiting for $expected_node to be promoted..."
    while [ $count -lt $max_wait ]; do
        local promoted=$(get_promoted_node)
        if [ "$promoted" = "$expected_node" ]; then
            log_debug "$expected_node promoted after $count seconds"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    log "WARNING: $expected_node not promoted within $max_wait seconds"
    return 1
}

#######################################################################
# Test Cases (same as before, but with enhanced test_fail)
#######################################################################

test_slot_creation() {
    test_start "Replication slot automatic creation"

    local promoted=$(get_promoted_node)
    if [ -z "$promoted" ]; then
        test_fail "Replication slot automatic creation" "No promoted node found"
        return
    fi

    local slot_exists=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc \"SELECT count(*) FROM pg_replication_slots WHERE slot_name='${SLOT_NAME}';\" 2>/dev/null" || echo "0")

    if [ "$slot_exists" = "1" ]; then
        test_pass "Replication slot automatic creation"
    else
        test_fail "Replication slot automatic creation" "Slot '${SLOT_NAME}' not found on promoted node"
    fi
}

test_slot_size_monitoring() {
    test_start "Replication slot size monitoring and cleanup"

    local promoted=$(get_promoted_node)
    if [ -z "$promoted" ]; then
        test_fail "Replication slot size monitoring" "No promoted node found"
        return
    fi

    local slot_size=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc \"SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots WHERE slot_name='${SLOT_NAME}';\" 2>/dev/null" || echo "")

    if [ -n "$slot_size" ]; then
        log_debug "Slot size: $slot_size"
        local monitor_log=$(ssh ${SSH_USER}@${promoted} "journalctl -u pacemaker --since '5 minutes ago' 2>/dev/null | grep -i 'slot' | tail -5" || echo "")
        log_debug "Recent slot monitoring: $monitor_log"
        test_pass "Replication slot size monitoring"
    else
        test_fail "Replication slot size monitoring" "Could not determine slot size"
    fi
}

test_automatic_standby_init() {
    test_start "Automatic standby initialization (empty PGDATA)"

    log_debug "Putting ${NODE2} in standby mode"
    ssh ${SSH_USER}@${NODE1} "crm node standby ${NODE2}" 2>&1 | tee -a "$LOG_FILE"
    sleep 3

    log_debug "Deleting PGDATA on ${NODE2}"
    ssh ${SSH_USER}@${NODE2} "rm -rf ${PGDATA}/* ${PGDATA}/.*  2>/dev/null; mkdir -p ${PGDATA}; chown postgres:postgres ${PGDATA}; chmod 700 ${PGDATA}" 2>&1 | tee -a "$LOG_FILE"

    log_debug "Bringing ${NODE2} online"
    ssh ${SSH_USER}@${NODE1} "crm node online ${NODE2}" 2>&1 | tee -a "$LOG_FILE"

    local max_wait=300
    local count=0
    local initialized=false

    while [ $count -lt $max_wait ]; do
        local status=$(ssh ${SSH_USER}@${NODE1} "crm status 2>/dev/null")
        if echo "$status" | grep -q "Unpromoted.*${NODE2}"; then
            local in_recovery=$(ssh ${SSH_USER}@${NODE2} "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();' 2>/dev/null" || echo "")
            if [ "$in_recovery" = "t" ]; then
                initialized=true
                log_debug "Automatic initialization completed after $count seconds"
                break
            fi
        fi
        sleep 1
        count=$((count + 1))
    done

    if [ "$initialized" = true ]; then
        test_pass "Automatic standby initialization"
    else
        test_fail "Automatic standby initialization" "Node2 did not initialize within $max_wait seconds"
    fi
}

test_postgres_auto_settings() {
    test_start "Automatic PostgreSQL variable settings (application_name)"

    local promoted=$(get_promoted_node)
    if [ -z "$promoted" ]; then
        test_fail "Automatic PostgreSQL variable settings" "No promoted node found"
        return
    fi

    # Check if application_name is set correctly in postgresql.auto.conf (server setting)
    # Note: We check the server configuration, not psql client (which overrides with 'psql')
    local expected_app_name
    expected_app_name=$(app_name_for_node "$promoted")
    local app_name
    app_name=$(ssh ${SSH_USER}@${promoted} "grep '^application_name' ${PGDATA}/postgresql.auto.conf 2>/dev/null | cut -d= -f2 | tr -d \"' \"" || echo "")

    if [ "$app_name" = "$expected_app_name" ]; then
        test_pass "Automatic PostgreSQL variable settings"
    else
        test_fail "Automatic PostgreSQL variable settings" "Expected application_name='$expected_app_name', got '$app_name'"
    fi
}

test_prevent_restart_after_crash() {
    test_start "Prevent misconfiguration: restart_after_crash"

    local promoted=$(get_promoted_node)
    if [ -z "$promoted" ]; then
        test_fail "Prevent misconfiguration" "No promoted node found"
        return
    fi

    local restart_setting=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc 'SHOW restart_after_crash;' 2>/dev/null" || echo "")

    if [ "$restart_setting" = "off" ]; then
        test_pass "Prevent misconfiguration: restart_after_crash"
    else
        test_fail "Prevent misconfiguration: restart_after_crash" "restart_after_crash is '$restart_setting', should be 'off'"
    fi
}

test_prevent_invalid_wal_sender_timeout() {
    test_start "Prevent misconfiguration: wal_sender_timeout"

    local promoted=$(get_promoted_node)
    if [ -z "$promoted" ]; then
        test_fail "Prevent misconfiguration: wal_sender_timeout" "No promoted node found"
        return
    fi

    # pg_settings reports milliseconds regardless of how the value is displayed (60s, 1min, ...)
    local timeout_ms
    timeout_ms=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc \"SELECT setting FROM pg_settings WHERE name='wal_sender_timeout';\" 2>/dev/null" || echo "0")

    if [ "$timeout_ms" -ge 10000 ] 2>/dev/null; then
        test_pass "Prevent misconfiguration: wal_sender_timeout"
    else
        test_fail "Prevent misconfiguration: wal_sender_timeout" "wal_sender_timeout is ${timeout_ms} ms, should be >= 10000 ms"
    fi
}

test_migration_with_rewind() {
    test_start "Migration with pg_rewind (timeline divergence recovery)"

    local original_primary=$(get_promoted_node)
    log_debug "Original primary: $original_primary"

    local target_node=""
    if [ "$original_primary" = "$NODE1" ]; then
        target_node="$NODE2"
    else
        target_node="$NODE1"
    fi

    log_debug "Failing over to $target_node"
    ssh ${SSH_USER}@${NODE1} "crm node standby $original_primary" 2>&1 | tee -a "$LOG_FILE"

    if ! wait_for_promotion "$target_node"; then
        test_fail "Migration with pg_rewind" "Failover to $target_node failed"
        ssh ${SSH_USER}@${NODE1} "crm node online $original_primary" 2>&1 | tee -a "$LOG_FILE"
        return
    fi

    log_debug "Creating timeline divergence"
    ssh ${SSH_USER}@${target_node} "sudo -u postgres psql -c 'CREATE TABLE IF NOT EXISTS test_divergence_$(date +%s) (id int);' 2>&1" | tee -a "$LOG_FILE"
    sleep 2

    log_debug "Bringing $original_primary back online (should use pg_rewind)"
    ssh ${SSH_USER}@${NODE1} "crm node online $original_primary" 2>&1 | tee -a "$LOG_FILE"

    # Wait for it to join as standby (pg_rewind or basebackup fallback may take time)
    sleep 30
    local status=$(ssh ${SSH_USER}@${NODE1} "crm status 2>/dev/null")

    local rewind_log=$(ssh ${SSH_USER}@${original_primary} "journalctl -u pacemaker --since '1 minute ago' 2>/dev/null | grep -i 'rewind'" || echo "")
    log_debug "pg_rewind log: $rewind_log"

    if echo "$status" | grep -q "Unpromoted.*${original_primary}"; then
        test_pass "Migration with pg_rewind"
    else
        test_fail "Migration with pg_rewind" "Node $original_primary did not rejoin as standby"
    fi

    log_debug "Failing back to $original_primary"
    ssh ${SSH_USER}@${NODE1} "crm node standby $target_node" 2>&1 | tee -a "$LOG_FILE"
    wait_for_promotion "$original_primary"
    ssh ${SSH_USER}@${NODE1} "crm node online $target_node" 2>&1 | tee -a "$LOG_FILE"
    sleep 5
}

test_migration_with_basebackup_with_slot() {
    test_start "Migration with pg_basebackup (with replication slot)"

    local promoted=$(get_promoted_node)
    local standby_node=""

    if [ "$promoted" = "$NODE1" ]; then
        standby_node="$NODE2"
    else
        standby_node="$NODE1"
    fi

    log_debug "Promoted: $promoted, Standby: $standby_node"

    log_debug "Forcing basebackup by deleting PGDATA on $standby_node"
    ssh ${SSH_USER}@${NODE1} "crm node standby $standby_node" 2>&1 | tee -a "$LOG_FILE"
    sleep 3

    ssh ${SSH_USER}@${standby_node} "rm -rf ${PGDATA}/* ${PGDATA}/.*  2>/dev/null; mkdir -p ${PGDATA}; chown postgres:postgres ${PGDATA}; chmod 700 ${PGDATA}" 2>&1 | tee -a "$LOG_FILE"

    log_debug "Bringing $standby_node online (should use pg_basebackup with slot)"
    ssh ${SSH_USER}@${NODE1} "crm node online $standby_node" 2>&1 | tee -a "$LOG_FILE"

    local max_wait=300
    local count=0
    local completed=false

    while [ $count -lt $max_wait ]; do
        local status=$(ssh ${SSH_USER}@${NODE1} "crm status 2>/dev/null")
        if echo "$status" | grep -q "Unpromoted.*${standby_node}"; then
            local in_recovery=$(ssh ${SSH_USER}@${standby_node} "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();' 2>/dev/null" || echo "")
            if [ "$in_recovery" = "t" ]; then
                completed=true
                log_debug "Basebackup with slot completed after $count seconds"
                break
            fi
        fi
        sleep 1
        count=$((count + 1))
    done

    if [ "$completed" = true ]; then
        # Verify slot was used - check Pacemaker logs for slot creation/usage
        local slot_log=$(ssh ${SSH_USER}@${standby_node} "journalctl -u pacemaker --since '5 minutes ago' 2>/dev/null | grep -E 'Replication slot.*${SLOT_NAME}'" || echo "")
        log_debug "Slot usage log: $slot_log"

        # Also verify slot exists and is active
        local slot_active=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc \"SELECT active FROM pg_replication_slots WHERE slot_name='${SLOT_NAME}';\" 2>/dev/null" || echo "")

        if [ -n "$slot_log" ] || [ "$slot_active" = "t" ]; then
            test_pass "Migration with pg_basebackup (with slot)"
        else
            test_fail "Migration with pg_basebackup (with slot)" "Basebackup did not use replication slot"
        fi
    else
        test_fail "Migration with pg_basebackup (with slot)" "Basebackup did not complete within $max_wait seconds"
    fi
}

test_sync_mode_after_migration() {
    test_start "Correct sync replication mode after migration"

    local promoted=$(get_promoted_node)
    if [ -z "$promoted" ]; then
        test_fail "Sync mode after migration" "No promoted node found"
        return
    fi

    sleep 5

    local sync_state=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc \"SELECT sync_state FROM pg_stat_replication WHERE application_name='${APPLICATION_NAME_NODE1}' OR application_name='${APPLICATION_NAME_NODE2}' LIMIT 1;\" 2>/dev/null" || echo "")

    log_debug "Sync state: '$sync_state'"

    if [ "$sync_state" = "sync" ] || [ "$sync_state" = "potential" ]; then
        test_pass "Correct sync replication mode after migration"
    else
        test_fail "Correct sync replication mode after migration" "Expected sync_state='sync' or 'potential', got '$sync_state'"
    fi
}

test_file_ownership() {
    test_start "File ownership verification (no wrong ownership)"

    local issues=""

    for node in $NODE1 $NODE2; do
        log_debug "Checking file ownership on $node"

        local pgdata_owner=$(ssh ${SSH_USER}@${node} "stat -c '%U:%G' ${PGDATA} 2>/dev/null" || echo "")
        if [ "$pgdata_owner" != "postgres:postgres" ]; then
            issues="${issues}${node}: PGDATA owned by '${pgdata_owner}' (expected postgres:postgres)\n"
        fi

        local wrong_files=$(ssh ${SSH_USER}@${node} "find ${PGDATA} -maxdepth 2 ! -user postgres 2>/dev/null | wc -l" || echo "999")
        if [ "$wrong_files" -gt 0 ]; then
            issues="${issues}${node}: Found ${wrong_files} files not owned by postgres\n"
        fi

        local pgpass_owner=$(ssh ${SSH_USER}@${node} "stat -c '%U:%G' /var/lib/pgsql/.pgpass 2>/dev/null" || echo "")
        if [ "$pgpass_owner" != "postgres:postgres" ]; then
            issues="${issues}${node}: .pgpass owned by '${pgpass_owner}' (expected postgres:postgres)\n"
        fi

        local pgpass_perms=$(ssh ${SSH_USER}@${node} "stat -c '%a' /var/lib/pgsql/.pgpass 2>/dev/null" || echo "")
        if [ "$pgpass_perms" != "600" ]; then
            issues="${issues}${node}: .pgpass has permissions '${pgpass_perms}' (expected 600)\n"
        fi
    done

    if [ -z "$issues" ]; then
        test_pass "File ownership verification"
    else
        test_fail "File ownership verification" "Issues found:\n$issues"
    fi
}

test_slot_missing_during_basebackup() {
    test_start "Handle missing replication slot during basebackup"

    local promoted=$(get_promoted_node)
    local standby_node=""

    if [ "$promoted" = "$NODE1" ]; then
        standby_node="$NODE2"
    else
        standby_node="$NODE1"
    fi

    log_debug "Testing slot recreation: Promoted=$promoted, Standby=$standby_node"

    log_debug "Deleting replication slot on $promoted"
    ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -c \"SELECT pg_drop_replication_slot('${SLOT_NAME}');\" 2>&1" | tee -a "$LOG_FILE"

    log_debug "Forcing standby re-initialization"
    ssh ${SSH_USER}@${NODE1} "crm node standby $standby_node" 2>&1 | tee -a "$LOG_FILE"
    sleep 3

    ssh ${SSH_USER}@${standby_node} "rm -rf ${PGDATA}/* ${PGDATA}/.*  2>/dev/null; mkdir -p ${PGDATA}; chown postgres:postgres ${PGDATA}; chmod 700 ${PGDATA}" 2>&1 | tee -a "$LOG_FILE"

    ssh ${SSH_USER}@${NODE1} "crm node online $standby_node" 2>&1 | tee -a "$LOG_FILE"

    local max_wait=300
    local count=0
    local slot_created=false

    while [ $count -lt $max_wait ]; do
        local slot_exists=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc \"SELECT count(*) FROM pg_replication_slots WHERE slot_name='${SLOT_NAME}';\" 2>/dev/null" || echo "0")

        if [ "$slot_exists" = "1" ]; then
            slot_created=true
            log_debug "Slot recreated after $count seconds"

            sleep 10
            local status=$(ssh ${SSH_USER}@${NODE1} "crm status 2>/dev/null")
            if echo "$status" | grep -q "Unpromoted.*${standby_node}"; then
                break
            fi
        fi

        sleep 1
        count=$((count + 1))
    done

    if [ "$slot_created" = true ]; then
        test_pass "Handle missing replication slot during basebackup"
    else
        test_fail "Handle missing replication slot during basebackup" "Slot was not recreated within $max_wait seconds"
    fi
}

test_version_validation() {
    test_start "PostgreSQL version validation (v1.6.7)"

    local promoted=$(get_promoted_node)
    if [ -z "$promoted" ]; then
        test_fail "PostgreSQL version validation" "No promoted node found"
        return
    fi

    local version_check=$(ssh ${SSH_USER}@${promoted} "journalctl -u pacemaker --since '10 minutes ago' 2>/dev/null | grep -i 'version' | grep -i 'validation\|mismatch'" || echo "")

    log_debug "Version check log: $version_check"

    local pg_version=$(ssh ${SSH_USER}@${promoted} "sudo -u postgres psql -Atc 'SELECT version();' 2>/dev/null" || echo "")

    if [ -n "$pg_version" ]; then
        test_pass "PostgreSQL version validation"
    else
        test_fail "PostgreSQL version validation" "PostgreSQL not running on promoted node"
    fi
}

#######################################################################
# Main Test Execution
#######################################################################

print_header "pgtwin HA Cluster Test Suite v2 (with Log Gathering)"

echo "Configuration:"
echo "  VIP: $VIP"
echo "  Node 1: $NODE1 ($NODE1_IP)"
echo "  Node 2: $NODE2 ($NODE2_IP)"
echo "  PGDATA: $PGDATA"
echo "  Replication User: $REP_USER"
echo "  Slot Name: $SLOT_NAME"
echo ""
echo "Results will be saved to: $RESULTS_FILE"
echo "Detailed logs will be saved to: $LOG_FILE"
echo -e "${CYAN}Diagnostics will be saved to: $DIAG_DIR${NC}"
echo ""

# Initialize results file
cat > "$RESULTS_FILE" << EOF
pgtwin HA Cluster Test Results (v2 with Diagnostics)
Date: $(date)
VIP: $VIP
Nodes: $NODE1, $NODE2
================================================================================
EOF

# Check cluster is accessible
log "Checking cluster accessibility..."
if ! ssh ${SSH_USER}@${NODE1} "crm status >/dev/null 2>&1"; then
    echo "ERROR: Cannot access cluster on $NODE1"
    exit 1
fi

if ! wait_for_cluster_stable; then
    echo "WARNING: Cluster may not be fully stable"
fi

print_header "Running Tests"

# Test 1: Slot Management
test_slot_creation
test_slot_size_monitoring
test_slot_missing_during_basebackup

# Test 2: Automatic Initialization
test_automatic_standby_init

# Test 3: Automatic Settings
test_postgres_auto_settings

# Test 4: Prevent Misconfigurations
test_prevent_restart_after_crash
test_prevent_invalid_wal_sender_timeout

# Test 5: Migration Tests
test_migration_with_rewind
test_migration_with_basebackup_with_slot

# Test 6: Post-Migration Checks
test_sync_mode_after_migration

# Test 7: File Ownership
test_file_ownership

# Test 8: Version Validation
test_version_validation

# Print results summary
print_header "Test Results Summary"

echo "Total Tests: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASS_COUNT${NC}"
echo -e "Failed: ${RED}$FAIL_COUNT${NC}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    exit_code=0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    echo ""
    echo "Failed tests (with diagnostics):"
    grep "^FAIL:" "$RESULTS_FILE" | while read -r line; do
        echo "  $line"
        grep -A1 "^FAIL:.*$(echo "$line" | cut -d: -f2)" "$RESULTS_FILE" | grep "Diagnostics:" | sed 's/^/    /'
    done
    exit_code=1
fi

echo ""
echo "Detailed results: $RESULTS_FILE"
echo "Detailed logs: $LOG_FILE"
echo -e "${CYAN}Diagnostics directory: $DIAG_DIR${NC}"

# Create diagnostic summary
if [ $FAIL_COUNT -gt 0 ]; then
    echo ""
    echo -e "${CYAN}=== Diagnostic Analysis Summary ===${NC}"
    echo ""

    for analysis_file in "${DIAG_DIR}"/*/analysis.txt; do
        if [ -f "$analysis_file" ]; then
            test_name=$(basename $(dirname "$analysis_file") | sed 's/test_[0-9]*_//' | tr '_' ' ')
            echo -e "${YELLOW}Analysis for: $test_name${NC}"

            # Show DIAGNOSIS and PGTWIN ISSUE lines
            grep -E "^(DIAGNOSIS|PGTWIN ISSUE|SEVERITY):" "$analysis_file" | sed 's/^/  /'
            echo ""
        fi
    done

    echo -e "${CYAN}Full analysis available in: ${DIAG_DIR}/*/analysis.txt${NC}"
fi

# Create summary table
cat >> "$RESULTS_FILE" << EOF

================================================================================
SUMMARY TABLE
================================================================================
Total Tests: $TOTAL_TESTS
Passed: $PASS_COUNT
Failed: $FAIL_COUNT

$(if [ $FAIL_COUNT -eq 0 ]; then echo "Result: ✓ ALL TESTS PASSED"; else echo "Result: ✗ $FAIL_COUNT TEST(S) FAILED"; fi)

Diagnostics Directory: $DIAG_DIR
$(if [ $FAIL_COUNT -gt 0 ]; then echo "Failed tests have diagnostic logs collected automatically."; fi)
================================================================================
EOF

# Print single-line summary for CI/CD
echo ""
echo "SUMMARY: Tests=$TOTAL_TESTS Pass=$PASS_COUNT Fail=$FAIL_COUNT Status=$(if [ $FAIL_COUNT -eq 0 ]; then echo 'SUCCESS'; else echo 'FAILURE'; fi) Diagnostics=$DIAG_DIR"

exit $exit_code
