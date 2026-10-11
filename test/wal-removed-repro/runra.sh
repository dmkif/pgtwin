#!/bin/bash
# usage: runra.sh <path-to-pgtwin> <action>      (action: start|stop|monitor|unit)
# Copies the agent into the standby container and runs it with stubbed OCF/Pacemaker tools.
RA=${1:?path to pgtwin}; ACT=${2:?action}
podman cp "$RA" pgs:/tmp/pgtwin.ra
if [ "$ACT" = unit ]; then podman exec pgs bash /harness/unit.sh; exit; fi
podman exec pgs bash -c ". /harness/ra-env.sh; bash /tmp/pgtwin.ra $ACT; echo RC=\$?" 2>&1
