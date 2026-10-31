#!/usr/bin/env bash
# Usage: ./nextbreak.sh <ticket-number>   injects the next fault from the hidden .queue without printing it
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; N="${1:?ticket number}"
f=$(head -n1 "$DIR/.queue"); sed -i 1d "$DIR/.queue"
start=$(date -u +%FT%TZ)
"$DIR/lab.sh" break "$f" >/dev/null 2>&1 || { echo "break failed (see .last-break.log)"; exit 1; }
printf 'injection started %s\ninjection finished %s\n' "$start" "$(date -u +%FT%TZ)" | tee "$DIR/evidence/logs/t${N}-0-injected.txt"
