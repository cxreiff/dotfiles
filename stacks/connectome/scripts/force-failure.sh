#!/usr/bin/env bash
# stacks/connectome/scripts/force-failure.sh
# AC5.4: stop the onecli gateway, wait (bounded) for the operator's DM to
# produce a failures.log record, ALWAYS restart the gateway.
# Exit: 0 record appeared; 1 timed out.
set -uo pipefail

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
    D exec connectome sh -c 'wc -c < /agent/state/logs/failures.log 2>/dev/null || echo 0' | tr -d ' '
}

before=$(size)
D stop onecli-gateway >/dev/null
echo "force-failure: gateway stopped — send the bot ONE Discord DM now (waiting up to 180 s)"

for _ in $(seq 1 90); do
    if [ "$(size)" -gt "$before" ]; then
        echo "force-failure: new failures.log record:"
        D exec connectome tail -n 1 /agent/state/logs/failures.log
        exit 0
    fi
    sleep 2
done

echo "force-failure: no failures.log record within 180 s" >&2
exit 1
