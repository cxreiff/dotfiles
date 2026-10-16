#!/usr/bin/env bash
# stacks/connectome/scripts/force-failure.sh
# AC5.4: stop the onecli gateway, wait (bounded) for the operator's DM to
# produce a failures.log record, ALWAYS restart the gateway.
# Exit: 0 record appeared; 1 timed out.
# FORCE_FAILURE_WAIT_SECONDS overrides the 180 s wait.
set -uo pipefail

wait_s="${FORCE_FAILURE_WAIT_SECONDS:-180}"
[[ "$wait_s" =~ ^[0-9]+$ ]] || { echo "force-failure: FORCE_FAILURE_WAIT_SECONDS must be an integer" >&2; exit 2; }

D() { docker --context colima-agents "$@"; }

restore() {
    D start onecli-gateway >/dev/null
    for _ in $(seq 1 30); do
        [ "$(D inspect -f '{{.State.Health.Status}}' onecli-gateway 2>/dev/null)" = healthy ] && break
        sleep 2
    done
    echo "force-failure: gateway restarted ($(D inspect -f '{{.State.Health.Status}}' onecli-gateway))"
}

trap restore EXIT

size() {
    D exec connectome sh -c 'f=/agent/state/logs/failures.log; if [ -f "$f" ]; then wc -c < "$f"; else echo 0; fi' | tr -d ' '
}

before=$(size)
D stop onecli-gateway >/dev/null
echo "force-failure: gateway stopped — send the bot ONE Discord DM now (waiting up to ${wait_s} s)"

for _ in $(seq 1 $(( (wait_s + 1) / 2 ))); do
    if [ "$(size)" -gt "$before" ]; then
        echo "force-failure: new failures.log record:"
        D exec connectome tail -n 1 /agent/state/logs/failures.log
        exit 0
    fi
    sleep 2
done

echo "force-failure: no failures.log record within ${wait_s} s" >&2
exit 1
