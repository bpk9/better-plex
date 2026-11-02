#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 ]]; then
  echo 'Usage: scripts/test-simulator.sh SIMULATOR_ID PATH_TO_TEST_MP4' >&2
  exit 2
fi
mkdir -p artifacts
python3 scripts/fixture-server.py "$2" > artifacts/fixture.log 2>&1 &
fixture_pid=$!
python3 scripts/auth-fixture-server.py > artifacts/auth-fixture.log 2>&1 &
auth_fixture_pid=$!
trap 'kill "$fixture_pid" "$auth_fixture_pid" 2>/dev/null || true' EXIT
sleep 1
kill -0 "$fixture_pid" 2>/dev/null || { cat artifacts/fixture.log; exit 1; }
kill -0 "$auth_fixture_pid" 2>/dev/null || { cat artifacts/auth-fixture.log; exit 1; }
# Use a dedicated simulator or remove only this app's previous test data before running.
xcodebuild -project ios/BetterPlex.xcodeproj -scheme BetterPlex \
  -destination "platform=iOS Simulator,id=$1" -derivedDataPath .build \
  CODE_SIGN_IDENTITY=- test > artifacts/tests.log 2>&1 || {
    tail -60 artifacts/tests.log
    exit 1
  }
tail -15 artifacts/tests.log
