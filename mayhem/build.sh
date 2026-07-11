#!/usr/bin/env bash
#
# go-git/mayhem/build.sh — build go-git/go-git's OSS-Fuzz Go fuzz target(s) as sanitized
# libFuzzer binaries, REPLICATING OSS-Fuzz's projects/go-git/build.sh + compile_native_go_fuzzer.
#
# go-git ships MANY native `func FuzzX(f *testing.F)` harnesses (go-118-fuzz-build style).
# We integrate a representative, self-contained subset of the core git-object/packfile/config/
# index parsers (single []byte input — the surface that maps cleanly to a Mayhem file target):
#
#   /mayhem/fuzz_config_decoder    config.FuzzDecoder        (plumbing/format/config)
#   /mayhem/fuzz_packfile_parser   packfile.FuzzParser       (plumbing/format/packfile)
#   /mayhem/fuzz_packfile_scanner  packfile.FuzzScanner      (plumbing/format/packfile)
#   /mayhem/fuzz_object_commit     object.FuzzCommitDecode   (plumbing/object)
#   /mayhem/fuzz_index_decoder     index.FuzzDecoder         (plumbing/format/index)
#
# OSS-Fuzz turns each `func FuzzX(f *testing.F)` into a libFuzzer binary via go-118-fuzz-build,
# after sed-stripping the non-Fuzz funcs/globals/structs from the target file (so suite-based
# sibling test helpers don't break the compile). We replicate that EXACTLY, plus remove the
# package's OTHER *_test.go files (which pull in stretchr/suite + go-git-fixtures and won't
# compile under go-118-fuzz-build). Each target builds in its own scratch copy of $SRC so the
# in-place source rewrites of one target never leak into another.
#
# Builder selection (per harness): we detect the harness signature.
#   * `func FuzzX(f *testing.F)`      -> go-118-fuzz-build (native).  All go-git harnesses.
#   * `func FuzzX(data []byte) int`   -> go-fuzz (go114-fuzz-build, legacy). None here, but the
#                                        selector is kept so the recipe is general.
#
# Outputs per target:
#   /mayhem/<target>            sanitized libFuzzer binary (ASan + libFuzzer engine)
#   /mayhem/<target>-standalone non-fuzzer reproducer: reads argv[1] file, runs the harness once
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. An explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer
# (natural-crash build); otherwise default to ASan for the Go fuzz binary.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# §6.2 item 10: DWARF < 4. clang-19 defaults to DWARF-5; pass -gdwarf-3 on the final link.
# The CGO vars are set (even though go-git is pure-Go) so any CGO shim or the standalone C driver
# inherit the flag. The final $CXX link below also passes $GO_DEBUG_FLAGS explicitly.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Go env: all caches pinned under /opt/toolchains (§6.2 item 8 — HOME-independent).
# GOPROXY: file:// first → offline re-run reads from the in-image module cache; the
# network entries are fallbacks for the first online build only (§6.5 air-gap gate).
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOROOT="${GOROOT:-/opt/toolchains/go}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/cache/go-build}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
mkdir -p "$GOPATH" "$GOCACHE"

cd "$SRC"
go version

mkdir -p /mayhem "$SRC/mayhem-build"

# A small C driver for the standalone (non-fuzzer) reproducer: it implements main(), reads the
# file named by argv[1] into a buffer, and calls LLVMFuzzerTestOneInput once. Linked WITHOUT the
# libFuzzer engine, it is a plain executable that replays a single input (PATCH-grade repro).
STANDALONE_MAIN="$SRC/mayhem-build/standalone_main.c"
cat > "$STANDALONE_MAIN" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int LLVMFuzzerTestOneInput(const unsigned char *data, long size);
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <input-file>\n", argv[0]); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror("fopen"); return 2; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  if (n < 0) { fclose(f); return 2; }
  unsigned char *buf = (unsigned char *)malloc(n ? n : 1);
  long rd = (long)fread(buf, 1, n, f); fclose(f);
  int rc = LLVMFuzzerTestOneInput(buf, rd);
  free(buf);
  return rc;
}
EOF
# Pass GO_DEBUG_FLAGS so the standalone C driver CU also carries DWARF-3.
$CC ${GO_DEBUG_FLAGS} ${SANITIZER_FLAGS:-} -c "$STANDALONE_MAIN" -o "$SRC/mayhem-build/standalone_main.o"

# build_one <out-name> <pkg-dir> <target-file-basename> <FuzzFunc>
#   Builds <out-name> (sanitized libFuzzer) and <out-name>-standalone (single-input reproducer).
build_one() {
  local out="$1" pkg="$2" tbase="$3" func="$4"
  echo "=== building ${out} (${func} @ ${pkg}) ==="

  # Each target rewrites source in place (go-118-fuzz-build mutates the tree); isolate in a copy.
  local work="$SRC/mayhem-build/work-${out}"
  rm -rf "$work"; mkdir -p "$work"
  # Copy the module (exclude .git + our scratch to keep it light).
  tar --exclude='./.git' --exclude='./mayhem-build' -C "$SRC" -cf - . | tar -C "$work" -xf -
  cd "$work"

  # Detect harness signature -> pick builder.
  local tfile="$pkg/$tbase"
  local builder="118"
  if grep -q "func ${func}(" "$tfile" 2>/dev/null && \
     grep "func ${func}(" "$tfile" | grep -q '\[\]byte'; then
    builder="114"
  fi

  # Module deps for the go-118 testing shim. tidy FIRST, then go get the shim (tidy would prune
  # it otherwise — nothing imports it until the builder generates the entrypoint).
  # GOPROXY file:// first means the cached shim version is resolved offline on re-run.
  go mod tidy 2>&1 | tail -1 || true
  go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -1 || true

  # Replicate OSS-Fuzz's per-file strip + remove sibling test files in the package directory so
  # suite/fixtures helpers don't break the go-118-fuzz-build compile.
  find "$pkg" -maxdepth 1 -name '*_test.go' ! -name "$tbase" -delete
  sed -i '/^func Fuzz/!{/^func /,/^}/d}' "$tfile"
  sed -i '/^\(var\|const\)\b/d; /^\s*\/\//d; /^\s*\/\*/,/\*\//d' "$tfile"
  sed -i '/^type .* struct {/,/^}/d' "$tfile"
  gofmt -w "$tfile" 2>/dev/null || true
  goimports -w "$tfile" 2>/dev/null || true

  local ar="$SRC/mayhem-build/${out}.a"
  if [ "$builder" = "114" ]; then
    echo "  builder: go-fuzz (legacy []byte)"
    go-fuzz -tags gofuzz -func "$func" -o "$ar" "./$pkg"
  else
    echo "  builder: go-118-fuzz-build (testing.F)"
    go-118-fuzz-build -tags gofuzz -o "$ar" -func "$func" "./$pkg"
  fi

  # Sanitized libFuzzer binary — pass GO_DEBUG_FLAGS to the final link so the first CU (the
  # C glue generated by go-118-fuzz-build) carries DWARF-3 (§6.2 item 10; -m1 gate).
  $CXX $GO_DEBUG_FLAGS $SANITIZER_FLAGS $LIB_FUZZING_ENGINE "$ar" -o "/mayhem/${out}"
  echo "  built /mayhem/${out}"

  # Standalone reproducer: the same Go archive + our C main, NO libFuzzer engine.
  # -lm covers libm refs when the sanitizer runtime is absent (empty SANITIZER_FLAGS build).
  if $CXX $GO_DEBUG_FLAGS ${SANITIZER_FLAGS:-} "$SRC/mayhem-build/standalone_main.o" "$ar" -lm \
        -o "/mayhem/${out}-standalone" 2>"$SRC/mayhem-build/${out}-standalone.log"; then
    echo "  built /mayhem/${out}-standalone"
  else
    echo "  WARNING: standalone link for ${out} failed (see ${out}-standalone.log)" >&2
    tail -5 "$SRC/mayhem-build/${out}-standalone.log" >&2 || true
  fi

  cd "$SRC"
}

build_one fuzz_config_decoder   plumbing/format/config   decoder_test.go        FuzzDecoder
build_one fuzz_packfile_parser  plumbing/format/packfile parser_fuzz_test.go    FuzzParser
build_one fuzz_packfile_scanner plumbing/format/packfile scanner_fuzz_test.go   FuzzScanner
build_one fuzz_object_commit    plumbing/object          decode_fuzz_test.go    FuzzCommitDecode
build_one fuzz_index_decoder    plumbing/format/index    decoder_fuzz_test.go   FuzzDecoder

echo "build.sh complete:"
ls -la /mayhem/fuzz_* 2>&1 || true
