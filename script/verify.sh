#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

COMMON_ARGS=(--package-path "$ROOT_DIR" -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors)
TEST_ARGS=(test)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-filter|--filter)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; exit 2; }
      TEST_ARGS+=(--filter "$2")
      shift 2
      ;;
    --test-filter=*|--filter=*)
      TEST_ARGS+=(--filter "${1#*=}")
      shift
      ;;
    *) COMMON_ARGS+=("$1"); shift ;;
  esac
done

swift build "${COMMON_ARGS[@]}"
swift "${TEST_ARGS[@]}" "${COMMON_ARGS[@]}"
