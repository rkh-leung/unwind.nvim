#!/usr/bin/env bash
set -euo pipefail

# scripts/test.sh - Headless test runner executing in an isolated environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEMP_ISOLATED_DIR="$(mktemp -d -t unwind_runner_XXXXXX)"
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
echo "Unwind Headless Test Runner"
echo "Repository: ${REPO_ROOT}"
echo "Isolated State: ${XDG_STATE_HOME}"
echo "=========================================================="

FAILED=0
TOTAL=0
PASSED=0

# Discover all test files under tests/ ending in _spec.lua
TEST_FILES=$(git ls-files --cached --others --exclude-standard 'tests/*_spec.lua' 'tests/**/*_spec.lua' | sort -u)

for test_file in ${TEST_FILES}; do
  TOTAL=$((TOTAL + 1))
  echo ""
  echo "--- Running: ${test_file} ---"
  # Use lua script wrapper to ensure assertion failures or Lua errors exit Neovim with :cquit 1
  if nvim --headless -u NONE -c "set rtp+=." -c "lua local ok, err = pcall(dofile, '${test_file}'); if not ok then print('ERROR: ' .. tostring(err)); vim.cmd('cquit 1') else vim.cmd('qa!') end"; then
    echo "PASS: ${test_file}"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: ${test_file}" >&2
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=========================================================="
echo "Summary: ${PASSED}/${TOTAL} suites passed (${FAILED} failed)"
echo "=========================================================="

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
exit 0
