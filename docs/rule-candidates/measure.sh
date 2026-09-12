#!/usr/bin/env bash
set -euo pipefail
# research benchmark: count verified grimuah rule candidates discovered in the
# sleepy corpus. fast, deterministic, no network.
#
# the corpus is a separate checkout. override it when it is not at the default:
#   GRIMUAH_RESEARCH_CORPUS=/path/to/sleepy ./docs/rule-candidates/measure.sh
#
# the detectors are read from this directory, and the per-rule evidence table is
# written to docs/rule-candidates/evidence.md

cd "$(dirname "$0")/../.."

corpus="${GRIMUAH_RESEARCH_CORPUS:-/home/cade/dev/sleepy}"
export GRIMUAH_RESEARCH_CORPUS="$corpus"

# harness prints a table then the METRIC lines
node docs/rule-candidates/harness.mjs

# informational: the shipped rule set's current findings on the corpus, so the
# research stays honest about what grimuah already catches
existing="$(cd "$corpus" && grimuah check 2>&1 | tail -1 || true)"
existing_count="$(printf '%s' "$existing" | grep -oE '[0-9]+' | head -1 || true)"
echo "METRIC shipped_rule_violations=${existing_count:-0}"
