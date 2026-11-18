#!/usr/bin/env bash
set -uo pipefail

log_file="${1:?usage: xcodebuild.sh <log-file> <xcodebuild arguments...>}"
shift
mkdir -p "$(dirname "$log_file")" || exit 1

# grep may find no summary. Keep xcodebuild's exit status and the complete log.
xcodebuild "$@" 2>&1 | tee "$log_file" | grep -E \
  '^(\*\*|.*: error:|error:)|^[[:space:]]*Executed [0-9]+ tests?|Test Case .* failed'
statuses=("${PIPESTATUS[@]}")
if (( statuses[0] != 0 )); then
  printf 'xcodebuild 失败，完整日志：%s\n' "$log_file" >&2
  exit "${statuses[0]}"
fi
exit "${statuses[1]}"
