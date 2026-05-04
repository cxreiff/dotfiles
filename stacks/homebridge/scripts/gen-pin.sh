#!/usr/bin/env bash
# stacks/homebridge/scripts/gen-pin.sh
# Generate a HomeKit setup pin (XXX-XX-XXX) that is NOT on Apple's reserved
# list. Prints exactly one pin per invocation. Use to seed HOMEKIT_PIN in
# stacks/homebridge/.env on a fresh setup.
#
# Exit codes:
#   0 — always (loops until a non-reserved pin is generated, then exits)
set -euo pipefail

reserved=(
    000-00-000 111-11-111 222-22-222 333-33-333 444-44-444
    555-55-555 666-66-666 777-77-777 888-88-888 999-99-999
    123-45-678 876-54-321
)

is_reserved() {
    local pin="$1" r
    for r in "${reserved[@]}"; do
        if [ "$pin" = "$r" ]; then return 0; fi
    done
    return 1
}

while true; do
    # Generate 8 random digits as 3-2-3 grouping
    a=$(printf '%03d' "$((RANDOM % 1000))")
    b=$(printf '%02d' "$((RANDOM % 100))")
    c=$(printf '%03d' "$((RANDOM % 1000))")
    pin="${a}-${b}-${c}"
    if ! is_reserved "$pin"; then
        echo "$pin"
        exit 0
    fi
done
