#!/usr/bin/env bash
# Compile only the actual Foundation policy and tests; never start the app or touch a driver.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v swiftc >/dev/null 2>&1; then
    printf '%s\n' 'SKIP: swiftc is unavailable; RogControl host tests were not compiled or run.' >&2
    exit 77
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/rogcontrol-tests.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
# Compile the same Foundation-only policy used by the app.
root="$(cd -- "$here/.." && pwd)"
cat "$root/ControlConfiguration.swift" "$root/SMCTelemetry.swift" "$root/RogControl.swift" "$here/ControlPolicyTests.swift" > "$work/main.swift"
swiftc -D ROG_LOGIC_TESTS "$work/main.swift" -o "$work/control-policy-tests"
"$work/control-policy-tests"
