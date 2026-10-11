#!/bin/bash
# unit test of the log-scan helpers, extracted from the RA
eval "$(sed -n '/^snapshot_pg_logs() {/,/^}/p;/^standby_start_failed_for_missing_wal() {/,/^}/p' /tmp/pgtwin.ra)"
T=$(mktemp -d); LD=$T/log; mkdir $LD
get_pg_log_directory() { echo $LD; }
ERR='2026-10-10 03:57:25 UTC [1] FATAL:  could not receive data from WAL stream: ERROR:  requested WAL segment 0000005B0000001800000097 has already been removed'
t() { local exp=$1 name=$2; shift 2; "$@"; local rc=$?; [ $rc -eq $exp ] && echo "PASS $name" || echo "FAIL $name (rc=$rc, want $exp)"; }
echo "$ERR" > $LD/old.log; : > $T/start.log
snapshot_pg_logs $T/snap
t 1 "old line only -> no escalation"        standby_start_failed_for_missing_wal $T/snap $T/start.log
echo "unrelated line" >> $LD/old.log
t 1 "unrelated new line -> no escalation"   standby_start_failed_for_missing_wal $T/snap $T/start.log
echo "$ERR" >> $LD/old.log
t 0 "error appended to existing log"        standby_start_failed_for_missing_wal $T/snap $T/start.log
snapshot_pg_logs $T/snap2
echo "$ERR" > $LD/new.log
t 0 "error in log file created by attempt"  standby_start_failed_for_missing_wal $T/snap2 $T/start.log
snapshot_pg_logs $T/snap3
t 1 "nothing new since snapshot"            standby_start_failed_for_missing_wal $T/snap3 $T/start.log
echo "$ERR" > $T/start.log
t 0 "error only in start log (no collector)" standby_start_failed_for_missing_wal $T/snap3 $T/start.log
get_pg_log_directory() { :; }
t 1 "no log dir, clean start log"           standby_start_failed_for_missing_wal $T/snap3 /dev/null
rm -rf $T
