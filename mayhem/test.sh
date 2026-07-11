#!/usr/bin/env bash
#
# go-git/mayhem/test.sh — RUN go-git's OWN Go test suite on the harnessed parser packages and
# emit a CTRF summary. exit 0 iff no test failed.
#
# Oracle scope: go-git's full `go test ./...` requires NETWORK + a real git remote (PlainClone
# from github/gitlab, submodule fixtures, archive-remote integration) and is NOT green offline.
# For an HONEST, hermetic oracle we run the self-contained packages that hold the code under
# fuzz — config / packfile / object / index parsers. These are REAL known-answer / golden-output
# suites: config decode<->encode round-trips assert exact values; object decode_test asserts
# decoded commit/tree/tag/blob fields; packfile + index decoders assert structure. They assert
# BEHAVIOUR, not "exits 0", so a no-op / `return nil` patch that breaks decode FAILS this oracle.
# This script only RUNS the suite (it never compiles the fuzz harness).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export GOROOT="${GOROOT:-/opt/toolchains/go}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/cache/go-build}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
cd "$SRC"

# Hermetic, self-contained packages that exercise the fuzzed parsers.
PKGS=(
  ./plumbing/format/config/...
  ./plumbing/format/packfile/...
  ./plumbing/object/...
  ./plumbing/format/index/...
)

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

echo "=== running: go test -json -count=1 ${PKGS[*]} ==="
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"
go test -json -count=1 "${PKGS[@]}" > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Human-readable summary + any build/test errors.
go test -count=1 "${PKGS[@]}" 2>&1 | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines carrying a non-empty "Test" field). Subtests included.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported non-zero but we counted 0 failures (e.g. a package
# build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
