#!/usr/bin/env bash
# Moneyman financial scraper with isracard retry logic
# Usage: scrape.sh [target...]
#   No args = all 4 targets
#   scrape.sh household.isracard.erik = just that one
#   scrape.sh freelancing household = multiple specific targets

set -euo pipefail

SSH_CONFIG="/app/skills/moneyman/ssh_config"
SSH="ssh -F $SSH_CONFIG moneyman-trigger"

ALL_TARGETS="freelancing household household.isracard.erik household.isracard.sonya"

declare -A results
declare -A outputs
declare -A txn_counts
overall_ok=true

extract_txn_count() {
  # Parses "{ accounts: N, transactions: M }" from moneyman output
  echo "$1" | grep -oP 'transactions: \K\d+' | tail -1
}

run_scraper() {
  local target=$1
  local max_retries=${2:-1}
  local attempt=0
  local delay=30

  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))
    echo "[$target] attempt $attempt/$max_retries" >&2
    output=$($SSH "$target" 2>&1) && ssh_rc=0 || ssh_rc=$?
    outputs[$target]="$output"
    txn_counts[$target]=$(extract_txn_count "$output")

    # Success requires ALL of:
    #   1. ssh exited 0
    #   2. positive evidence the scraper ran to completion (the "{ accounts: N, transactions: M }" line)
    #   3. no failure markers in the output
    if [ $ssh_rc -ne 0 ]; then
      echo "[$target] failed (ssh exit $ssh_rc)" >&2
    elif ! echo "$output" | grep -qE 'accounts: [0-9]+, transactions: [0-9]+'; then
      echo "[$target] failed (no scraper completion line found — likely never ran)" >&2
    elif echo "$output" | grep -qE '❌|Failed Account Updates'; then
      echo "[$target] failed (failures found in output)" >&2
    else
      results[$target]="success"
      echo "[$target] success (${txn_counts[$target]:-?} transactions)" >&2
      return 0
    fi
    if [ $attempt -lt $max_retries ]; then
      echo "[$target] retrying in ${delay}s..." >&2
      sleep $delay
      delay=$((delay * 2))
    fi
  done

  results[$target]="failed after $attempt attempts"
  overall_ok=false
  return 1
}

# Determine which targets to run
if [ $# -gt 0 ]; then
  targets=("$@")
else
  targets=($ALL_TARGETS)
fi

for target in "${targets[@]}"; do
  run_scraper "$target" 3 || true
done

# Output JSON summary
echo "---MONEYMAN_RESULTS---"
echo "{"
first=true
for target in "${targets[@]}"; do
  if [ "$first" = true ]; then first=false; else echo ","; fi
  status="${results[$target]:-unknown}"
  escaped_output=$(echo "${outputs[$target]:-}" | head -20 | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')
  txns="${txn_counts[$target]:-null}"
  echo "  \"$target\": {\"status\": \"$status\", \"transactions\": $txns, \"output\": $escaped_output}"
done
echo "}"

if [ "$overall_ok" = true ]; then
  echo "ALL_OK"
else
  echo "SOME_FAILED"
fi
