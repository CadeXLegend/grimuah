#!/usr/bin/env bash
# frozen oracle: replays the corpus findings that biome's engines validated and
# diffs them against the committed fixtures in tests/oracle
#
# biome was the oracle for both corpora until the native engine replaced it. the
# fixtures were recorded on 2026-09-12 while `.auto/native-diff.sh` (biome's
# plugin engine) and `.auto/hygiene-diff.sh` (biome's five built-in rules) were
# both green, so they carry that verdict without needing biome at run time
#
# the fixtures are a snapshot, not a proof: a deliberate rule change updates them
# in the same commit, and `--record` exists for that. never re-record to make a
# failure go away, because only an oracle can tell a fixed finding from a lost one
#
# usage: tests/oracle/check.sh [--record]
set -euo pipefail

ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ORACLE_DIR/../.." && pwd)"
BIN="${GRIMUAH:-$REPO/zig-out/bin/grimuah}"
RECORD=0
if [ "${1:-}" = "--record" ]; then
  RECORD=1
fi

[ -x "$BIN" ] || { echo "missing $BIN, run: zig build -Doptimize=ReleaseSafe" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0

# findings are the lines `path:line: [layer] message`, and the pre-pass prints
# its paths with a `./` prefix while the engine does not, so it is stripped to
# keep a fixture stable
filter_findings() {
  grep -E '^[^:]*:[0-9]+: \[[a-z]+\] ' || true
}
canonical() {
  sed -E 's#^\./##' | sort
}

# grimuah's own rules over the fixtures that pin biome's plugin semantics
lint_corpus_findings() {
  local project="$TMP/lint-corpus"
  mkdir -p "$project/src"
  "$BIN" init "$project" --preset default >/dev/null 2>&1 </dev/null
  cp -r "$REPO/tests/lint-corpus" "$project/src/probe"
  # the scaffold's surface directories go, so the copied fixtures are the only
  # source in the project. the three structural rows they leave behind are the
  # missing-directory warning, which is what the pre-pass reports on a surface
  # whose directory is not there
  rm -rf "$project/src/components" "$project/src/services" "$project/src/utils"
  # the carve-out machinery is part of what the corpus pins: one entry covers a
  # fixture the oracle would otherwise report, and one names a path no file in the
  # run has, so the frozen rows carry both the suppression and the report on an
  # entry that went stale when its file moved
  jq '.exemptions = [
        { "rule": "null-literal", "paths": ["src/probe/null-lit.ts"],
          "reason": "a driver hands back null" },
        { "rule": "null-literal", "paths": ["src/probe/moved-away.ts"],
          "reason": "the file this used to name" }
      ]' "$project/architecture.config.json" >"$project/cfg.json"
  mv "$project/cfg.json" "$project/architecture.config.json"
  ( cd "$project" && "$BIN" check ) 2>&1 || true
}

# the hygiene rules alone, so the architecture layers cannot mask a change, and
# the scope is the copied corpus rather than the scaffold
hygiene_corpus_findings() {
  local project="$TMP/hygiene-corpus"
  mkdir -p "$project/src"
  "$BIN" init "$project" --preset default >/dev/null 2>&1 </dev/null
  rm -rf "$project/src"
  mkdir -p "$project/src"
  cp -r "$REPO/tests/hygiene-corpus"/. "$project/src/"
  jq '.layers = {"cosmetic": false, "structural": false, "resilience": false, "behavioural": false}
      | .sourceRoots = ["src"]' "$project/architecture.config.json" >"$project/cfg.json"
  mv "$project/cfg.json" "$project/architecture.config.json"
  ( cd "$project" && "$BIN" check ) 2>&1 || true
}

compare_corpus() {
  local label="$1" fixture="$ORACLE_DIR/$2" producer="$3"
  local actual="$TMP/$label.tsv"
  "$producer" | filter_findings | canonical >"$actual"

  if [ "$RECORD" -eq 1 ]; then
    cp "$actual" "$fixture"
    echo "recorded $label: $(wc -l <"$actual" | tr -d ' ') rows into tests/oracle/$2"
    return 0
  fi

  local row_count
  row_count="$(wc -l <"$actual" | tr -d ' ')"
  if diff -u "$fixture" "$actual" >"$TMP/$label.diff"; then
    echo "ok   $label: $row_count rows match tests/oracle/$2"
  else
    echo "FAIL $label: findings differ from the frozen oracle"
    head -30 "$TMP/$label.diff"
    failures=$((failures + 1))
  fi
}

compare_corpus lint-corpus lint-corpus.tsv lint_corpus_findings
compare_corpus hygiene-corpus hygiene-corpus.tsv hygiene_corpus_findings

if [ "$failures" -ne 0 ]; then
  echo "differed from the frozen oracle ($failures corpus/corpora)"
  exit 1
fi
if [ "$RECORD" -eq 0 ]; then
  echo "corpus findings match the frozen oracle"
fi
