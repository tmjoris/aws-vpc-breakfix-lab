#!/usr/bin/env bash
# Usage: ./evidence.sh <name> <command...>
# Runs a command, prints it, and saves command + UTC timestamp + output to evidence/logs/<name>.txt
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
name="$1"; shift
out="$DIR/evidence/logs/${name}.txt"
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "\$ $*"
  "$@" 2>&1
  echo "# exit: $?"
} | tee "$out"
