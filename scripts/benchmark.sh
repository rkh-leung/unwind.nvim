#!/usr/bin/env bash
set -euo pipefail

# scripts/benchmark.sh - Microbenchmark runner executing in an isolated environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEMP_ISOLATED_DIR="$(mktemp -d -t unwind_bench_XXXXXX)"
export XDG_STATE_HOME="${TEMP_ISOLATED_DIR}/state"
export XDG_DATA_HOME="${TEMP_ISOLATED_DIR}/data"
export XDG_CONFIG_HOME="${TEMP_ISOLATED_DIR}/config"
export XDG_CACHE_HOME="${TEMP_ISOLATED_DIR}/cache"

mkdir -p "${XDG_STATE_HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

cleanup() {
  rm -rf "${TEMP_ISOLATED_DIR}"
}
trap cleanup EXIT INT TERM

cd "${REPO_ROOT}"

echo "=========================================================="
echo "Unwind Headless Benchmark Runner"
echo "Repository: ${REPO_ROOT}"
echo "Isolated State: ${XDG_STATE_HOME}"
echo "=========================================================="

nvim --headless -u NONE -c "set rtp+=." -c "luafile bench/benchmark.lua" -c "qa!"
