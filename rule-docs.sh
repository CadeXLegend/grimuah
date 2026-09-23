#!/usr/bin/env bash
# keep RULES.md in step with the rule table: regenerate what is derivable, then
# gate what is not
#
# `src/rules.zig` is the table, and the counts the prose states are derived from it
# here rather than typed into a sentence, because a count typed by hand goes stale
# the next time a rule lands
# the prose of a table row is hand-written and stays that way, so the rows are not
# generated: they are gated, and a rule that ships without a documented row leaves
# RULES.md answering for a build that no longer exists
# the name and the severity of each row are what the gate reads, because the prose
# is the only part of a row that the table cannot check
set -euo pipefail
cd "$(dirname "$0")"

# one parse, read four ways below: the shipped rules as `name<TAB>layer<TAB>severity`
# an entry declares `.name`, then `.layer`, then `.severity`, so the pair is printed
# when the severity arrives and the name is cleared for the next entry
rule_rows=$(awk '
  /^pub const all = \[_\]Rule\{/ { in_table = 1; next }
  in_table && /^\};/              { in_table = 0 }
  !in_table                       { next }
  /^        \.name = "/           {
    name = $0
    sub(/^ *\.name = "/, "", name)
    sub(/",.*$/, "", name)
  }
  /^        \.layer = \./         {
    layer = $0
    sub(/^ *\.layer = \./, "", layer)
    sub(/,$/, "", layer)
  }
  /^        \.severity = \./      {
    severity = $0
    sub(/^ *\.severity = \./, "", severity)
    sub(/,$/, "", severity)
    if (severity == "err") severity = "error"
    if (name != "") { print name "\t" layer "\t" severity; name = "" }
  }
' src/rules.zig)

# a table whose entries stopped parsing would otherwise rewrite every count to zero
if [ -z "$rule_rows" ]; then
  echo "rule-docs: found no rules in src/rules.zig, so the table it reads has moved" >&2
  exit 1
fi

total=$(printf '%s\n' "$rule_rows" | wc -l)
hygiene=$(printf '%s\n' "$rule_rows" | awk -F'\t' '$2 == "hygiene"' | wc -l)
project=$((total - hygiene))

# replace the whole line carrying `anchor` with `line`, and only when it differs,
# so a clean tree is left untouched and the hook has nothing to stage
rewrite_line() {
  local file=$1 anchor=$2 line=$3
  local rewritten
  rewritten=$(mktemp)
  if ! awk -v anchor="$anchor" -v line="$line" '
    index($0, anchor) > 0 { $0 = line; hits++ }
    { print }
    END { exit hits == 1 ? 0 : 1 }
  ' "$file" > "$rewritten"; then
    echo "rule-docs: $file has no single line carrying '$anchor'" >&2
    rm -f "$rewritten"
    exit 1
  fi
  if cmp -s "$file" "$rewritten"; then
    rm -f "$rewritten"
  else
    mv "$rewritten" "$file"
    echo "rule-docs: rewrote $file"
  fi
}

rewrite_line RULES.md 'rules ship today:' \
  "$total rules ship today: $project project rules across four configurable layers, plus $hygiene hygiene rules that run whenever the engine runs"

rewrite_line README.md 'needs no rule keys to run all' \
  "so the config a fresh project gets needs no rule keys to run all $total rules"

# ── the gate ─────────────────────────────────────────────────────────────────

# the rows of the tables as `name<TAB>severity` pairs. the row is read by its second
# cell declaring `error` or `warn`: the layers table's third cell says `yes`, and
# the severity table's rows carry their explanation where a rule row carries its
# severity, so neither is a row a rule is documented by
documented_rows=$(awk -F'|' '
  $3 ~ /^ *(error|warn) *$/ {
    name = $2
    gsub(/[` ]/, "", name)
    severity = $3
    gsub(/ /, "", severity)
    print name "\t" severity
  }
' RULES.md | sort -u)

shipped_names=$(printf '%s\n' "$rule_rows" | cut -f1 | sort -u)
documented_names=$(printf '%s\n' "$documented_rows" | cut -f1 | sort -u)

missing=$(comm -23 <(printf '%s\n' "$shipped_names") <(printf '%s\n' "$documented_names"))
stale=$(comm -13 <(printf '%s\n' "$shipped_names") <(printf '%s\n' "$documented_names"))

# a row whose rule is gone is a name problem rather than a severity one, so the
# severity pass reads only the names the two agree on
# the inputs are told apart by name rather than by the `NR == FNR` idiom, which
# reads an empty first input as the start of the second
misstated=$(awk -F'\t' '
  FILENAME == ARGV[1] { documented[$1] = $2; next }
  $1 in documented && documented[$1] != $2 {
    print $1 ": RULES.md says " documented[$1] ", the engine ships " $2
  }
' <(printf '%s\n' "$documented_rows") <(printf '%s\n' "$rule_rows" | cut -f1,3))

indent() { sed 's/^/  /'; }

STATUS=0
if [ -n "$missing" ]; then
  echo ""
  echo "these rules ship, and RULES.md has no row for them:"
  printf '%s\n' "$missing" | indent
  STATUS=1
fi
if [ -n "$stale" ]; then
  echo ""
  echo "these rows name rules the engine does not have:"
  printf '%s\n' "$stale" | indent
  STATUS=1
fi
if [ -n "$misstated" ]; then
  echo ""
  echo "these rows state a severity the engine does not ship:"
  printf '%s\n' "$misstated" | indent
  STATUS=1
fi
if [ "$STATUS" -ne 0 ]; then
  echo ""
  echo "RULES.md states one row per rule, with the severity the engine ships"
fi
exit $STATUS
