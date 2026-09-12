#!/usr/bin/env bash
# e2e: end-to-end test for grimuah (architecture generator)
# Auto-cleanup via trap
# 60+ checks across init/check/add/remove/upgrade/biome
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRIMUAH="${GRIMUAH:-$SCRIPT_DIR/zig-out/bin/grimuah}"
BIOME="${BIOME:-biome}"
TMPDIR="$(mktemp -d /tmp/grimuah-e2e-XXXXXXXX)"
P1="$TMPDIR/p1"
PASS=0; FAIL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

ok()     { PASS=$((PASS+1)); echo "  ok $*"; }
fail()   { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
achk()   { cd "$P1" && "$GRIMUAH" check 2>&1 || true; }
dagok(){ jq -e '[.surfaces[].dagOrder] | sort == [range(length)]' "$1" >/dev/null; }

"$BIOME" --version >/dev/null 2>&1 || { echo "biome not found"; exit 1; }

# ── 1. init default ──
"$GRIMUAH" init "$P1" --preset default 2>/dev/null <<< ""
for f in architecture.config.json tsconfig.json package.json biome.json .gitignore; do
  test -f "$P1/$f" && ok "$f" || fail "missing $f"
done
for d in utils services components; do
  test -d "$P1/src/$d" && ok "src/$d" || fail "missing src/$d"
done

s=$(jq '.surfaces | length' "$P1/architecture.config.json"); test "$s" -eq 3 && ok "3 surfaces" || fail "expected 3, got $s"
dagok "$P1/architecture.config.json" && ok "dagOrder sequential" || fail "dagOrder not sequential"

# all src/ surfaces have depth 1
jq -e '[.surfaces[].depth] | map(. == 1) | all' "$P1/architecture.config.json" >/dev/null && ok "all surfaces depth 1" || fail "some surfaces not depth 1"

# ── 2. generated .gitignore ──
for entry in node_modules/ dist/ .pi .rpiv; do
  grep -q "$entry" "$P1/.gitignore" && ok ".gitignore: $entry" || fail ".gitignore: missing $entry"
done

# ── 3. generated .husky/ ──
test -f "$P1/.husky/pre-commit"           && ok ".husky/pre-commit"       || fail ".husky/pre-commit missing"
test -f "$P1/.husky/check-em-dash.sh"     && ok ".husky/check-em-dash.sh" || fail ".husky/check-em-dash.sh missing"
test -f "$P1/.husky/format-on-commit.sh"  && ok ".husky/format-on-commit.sh" || fail ".husky/format-on-commit.sh missing"

# ── 4. package.json scripts ──
jq -e '.scripts.lint' "$P1/package.json"     >/dev/null && ok "package.json: lint script"     || fail "package.json: lint missing"
jq -e '.scripts.prepare' "$P1/package.json"   >/dev/null && ok "package.json: prepare script"  || fail "package.json: prepare missing"
jq -e '.scripts.release' "$P1/package.json"   >/dev/null && ok "package.json: release script"  || fail "package.json: release missing"
jq -e '.devDependencies.husky' "$P1/package.json"       >/dev/null && ok "package.json: husky dep"   || fail "package.json: husky missing"
jq -e '.devDependencies.typescript' "$P1/package.json"  >/dev/null && ok "package.json: typescript" || fail "package.json: typescript missing"
jq -e '.devDependencies["commit-and-tag-version"]' "$P1/package.json" >/dev/null && ok "package.json: commit-and-tag-version" || fail "package.json: catv missing"

# ── 5. init bot ──
"$GRIMUAH" init "$TMPDIR/p2" --preset bot 2>/dev/null <<< "n"
s=$(jq '.surfaces | length' "$TMPDIR/p2/architecture.config.json"); test "$s" -eq 8 && ok "bot: 8 surfaces" || fail "bot: expected 8, got $s"
dagok "$TMPDIR/p2/architecture.config.json" && ok "bot: dagOrder 0-7" || fail "bot: dagOrder not sequential"
jq -e '.rootLib.enabled' "$TMPDIR/p2/architecture.config.json" >/dev/null && ok "bot: rootLib enabled" || fail "bot: rootLib missing"
# lib has depth 0, everything else depth 1
libd=$(jq -r '.surfaces[] | select(.name=="lib") | .depth' "$TMPDIR/p2/architecture.config.json")
test "$libd" = "0" && ok "bot: lib depth 0" || fail "bot: lib depth $libd"
alld1=$(jq '[.surfaces[] | select(.name!="lib") | .depth] | map(. == 1) | all' "$TMPDIR/p2/architecture.config.json")
test "$alld1" = "true" && ok "bot: all other surfaces depth 1" || fail "bot: some surfaces not depth 1"

# ── 6. init backend (middleware preset, tasks optional) ──
"$GRIMUAH" init "$TMPDIR/p3" --preset backend 2>/dev/null <<< ""
s=$(jq '.surfaces | length' "$TMPDIR/p3/architecture.config.json"); test "$s" -eq 4 && ok "backend: 4 surfaces (tasks not added)" || fail "backend: expected 4, got $s"
jq -e '.surfaces[] | select(.name=="middleware")' "$TMPDIR/p3/architecture.config.json" >/dev/null && ok "backend: has middleware" || fail "backend: middleware missing"
jq -e '.surfaces[] | select(.name=="tasks")' "$TMPDIR/p3/architecture.config.json" >/dev/null && fail "backend: tasks should not be present" || ok "backend: tasks not in preset"
jq -e '.rootLib.enabled' "$TMPDIR/p3/architecture.config.json" >/dev/null && ok "backend: rootLib enabled" || fail "backend: rootLib missing"
dagok "$TMPDIR/p3/architecture.config.json" && ok "backend: dagOrder sequential" || fail "backend: dagOrder not sequential"

# ── 7. init backend with tasks answered yes ──
printf 'n\nn\ny\n' | "$GRIMUAH" init "$TMPDIR/p3-tasks" --preset backend 2>/dev/null
s=$(jq '.surfaces | length' "$TMPDIR/p3-tasks/architecture.config.json"); test "$s" -eq 5 && ok "backend+tasks: 5 surfaces" || fail "backend+tasks: expected 5, got $s"
jq -e '.surfaces[] | select(.name=="tasks")' "$TMPDIR/p3-tasks/architecture.config.json" >/dev/null && ok "backend+tasks: tasks added" || fail "backend+tasks: tasks missing"
dagok "$TMPDIR/p3-tasks/architecture.config.json" && ok "backend+tasks: dagOrder sequential" || fail "backend+tasks: dagOrder not sequential"

# ── 7. tsconfig ──
t=$(jq -r '.compilerOptions.target' "$P1/tsconfig.json");     test "$t" = "esnext"   && ok "tsconfig target esnext"     || fail "tsconfig target: $t"
m=$(jq -r '.compilerOptions.module' "$P1/tsconfig.json");     test "$m" = "ES2022"   && ok "tsconfig module ES2022"     || fail "tsconfig module: $m"
jq -e '.compilerOptions.noImplicitOverride' "$P1/tsconfig.json"        >/dev/null && ok "tsconfig noImplicitOverride"   || fail "tsconfig noImplicitOverride missing"
jq -e '.compilerOptions.noPropertyAccessFromIndexSignature' "$P1/tsconfig.json" >/dev/null && ok "tsconfig noPropertyAccessFromIndexSignature" || fail "tsconfig missing"
jq -e '.compilerOptions.noImplicitReturns' "$P1/tsconfig.json"         >/dev/null && ok "tsconfig noImplicitReturns"    || fail "tsconfig noImplicitReturns missing"
jq -e '.compilerOptions.noFallthroughCasesInSwitch' "$P1/tsconfig.json">/dev/null && ok "tsconfig noFallthroughCasesInSwitch" || fail "tsconfig missing"
jq -e '.compilerOptions.forceConsistentCasingInFileNames' "$P1/tsconfig.json" >/dev/null && ok "tsconfig forceConsistentCasingInFileNames" || fail "tsconfig missing"
jq -e '.compilerOptions.esModuleInterop' "$P1/tsconfig.json"          >/dev/null && ok "tsconfig esModuleInterop"      || fail "tsconfig esModuleInterop missing"
# strict should not be explicitly set (it is default in TS 6.0)
jq '.compilerOptions | has("strict")' "$P1/tsconfig.json" | grep -q false && ok "tsconfig strict not explicit" || fail "tsconfig strict is explicit"

# ── 8. example file suffixes ──
test -f "$P1/src/utils/example.util.ts"          && ok "example.util.ts"          || fail "missing example.util.ts"
test -f "$P1/src/services/example.service.ts"    && ok "example.service.ts"       || fail "missing example.service.ts"
test -f "$P1/src/components/example.component.ts"&& ok "example.component.ts"      || fail "missing example.component.ts"

# ── 9. biome.json plugins ──
rule_files=$(find "$P1/.grimuah-rules" -name '*.grit' | wc -l)
test "$(jq '.plugins | length' "$P1/biome.json")" = "$rule_files" && ok "biome.json: one plugin per rule file" || fail "biome.json plugin count != rule file count"

# ── 10. .grit files ──
test "$rule_files" -gt 4 && ok "$rule_files .grit files (one rule per file)" || fail "expected more than 4 .grit files, got $rule_files"
for f in "$P1"/.grimuah-rules/*.grit; do
  name="$(basename "$f")"
  test "$(head -1 "$f")" = "engine biome(1.0)" && ok "  $name engine line" || fail "  $name bad engine"
  grep -q 'or {' "$f" && fail "  $name wraps rules in an or block" || ok "  $name has no or block"
done
# every declared plugin must exist on disk
missing=0
while read -r plugin; do test -f "$P1/$plugin" || missing=$((missing+1)); done < <(jq -r '.plugins[]' "$P1/biome.json")
test "$missing" -eq 0 && ok "biome.json plugins all exist" || fail "$missing biome.json plugin(s) missing on disk"

# ── 11. biome check clean ──
"$BIOME" check "$P1" 2>&1 | grep -q "Failed to compile" && fail "biome check: fails" || ok "biome check: passes"

# ── 12. biome format check ──
"$BIOME" format "$P1" 2>&1 | grep -q "Formatter would have printed" && fail "biome format: would change" || ok "biome format: already clean"

# ── 13. grimuah check clean ──
echo "// extra" > "$P1/src/utils/second.util.ts"
echo "// extra" > "$P1/src/services/second.service.ts"
echo "// extra" > "$P1/src/components/second.component.ts"
achk | grep -q "grimuah check: clean" && ok "grimuah check: clean on multi-file" || fail "grimuah check not clean"

# ── 14. grimuah check catches wrong suffix ──
echo "junk" > "$P1/src/services/wrong.txt"
achk | grep -qE "wrong\.txt.*does not match" && ok "grimuah check: catches wrong suffix" || fail "grimuah check: missed wrong suffix"
rm "$P1/src/services/wrong.txt"

# ── 15. grimuah check catches centralized dirs ──
mkdir -p "$P1/src/config"
echo "export {}" > "$P1/src/config/app.config.ts"
achk | grep -q "centralized.*config/" && ok "grimuah check: catches centralized config/" || fail "grimuah check: missed centralized dir"
rm -rf "$P1/src/config"

# ── 16. grimuah check catches import firewall ──
echo "import { x } from '../components';" > "$P1/src/services/import-test.service.ts"
achk | grep -q "importing from 'components'" && ok "grimuah check: catches import firewall" || fail "grimuah check: missed import violation"
rm "$P1/src/services/import-test.service.ts"

# ── 16b. grimuah check catches the rules biome's plugin engine cannot compile ──
printf 'export const f = (): number => {\n  let x = 1;\n  return x;\n};\n' > "$P1/src/utils/let.util.ts"
achk | grep -q "do not use let" && ok "grimuah check: catches let" || fail "grimuah check: missed let"
printf 'export const g = (x: number): number => {\n  switch (x) {\n    case 1: return 1;\n    default: return 0;\n  }\n};\n' > "$P1/src/utils/switch.util.ts"
achk | grep -q "do not use switch" && ok "grimuah check: catches switch" || fail "grimuah check: missed switch"
printf 'export const s = "a %s b";\n' $'\u2014' > "$P1/src/utils/emdash.util.ts"
achk | grep -q "do not use em-dashes" && ok "grimuah check: catches em-dash" || fail "grimuah check: missed em-dash"
rm -f "$P1/src/utils/let.util.ts" "$P1/src/utils/switch.util.ts" "$P1/src/utils/emdash.util.ts"
achk | grep -q "grimuah check: clean" && ok "grimuah check: clean again after the three rules" || fail "grimuah check: not clean after cleanup"

# ── 17. add ──
cd "$P1" && "$GRIMUAH" add validators 2>/dev/null || true
test -d "$P1/src/validators" && ok "add: creates dir" || fail "add: no dir"
test -f "$P1/src/validators/example.validator.ts" && ok "add: example.validator.ts" || fail "add: no example"
jq -e '.surfaces[] | select(.name=="validators")' "$P1/architecture.config.json" >/dev/null && ok "add: surface in config" || fail "add: missing from config"

# ── 18. add suffix heuristics ──
cd "$P1" && "$GRIMUAH" add guards 2>/dev/null || true
test "$(jq -r '.surfaces[] | select(.name=="guards") | .suffixes[0]' "$P1/architecture.config.json")" = ".guard.ts" && ok "add guards: .guard.ts" || fail "add guards"
cd "$P1" && "$GRIMUAH" add states 2>/dev/null || true
test "$(jq -r '.surfaces[] | select(.name=="states") | .suffixes[0]' "$P1/architecture.config.json")" = ".state.ts" && ok "add states: .state.ts" || fail "add states"
cd "$P1" && "$GRIMUAH" add repositories 2>/dev/null || true
test "$(jq -r '.surfaces[] | select(.name=="repositories") | .suffixes[0]' "$P1/architecture.config.json")" = ".repo.ts" && ok "add repos: .repo.ts" || fail "add repos"

# ── 19. add rejects duplicate ──
cd "$P1" && "$GRIMUAH" add validators 2>&1 | grep -q "already exists" && ok "add: rejects duplicate" || fail "add: duplicate allowed"

# ── 20. remove ──
cd "$P1" && "$GRIMUAH" remove validators 2>&1 | grep -q "removed surface" && ok "remove: succeeded" || fail "remove: failed"
test ! -d "$P1/src/validators" && ok "remove: dir deleted" || fail "remove: dir left"
jq -e '.surfaces[] | select(.name=="validators")' "$P1/architecture.config.json" >/dev/null 2>&1 && fail "remove: surface left in config" || ok "remove: stripped from config"

# ── 21. remove non-existent ──
cd "$P1" && "$GRIMUAH" remove nonexistent 2>&1 | grep -q "not found" && ok "remove: errors on missing" || fail "remove: no error"

# ── 22. upgrade "already up to date" ──
cd "$P1" && "$GRIMUAH" upgrade 2>&1 | grep -q "already up to date" && ok "upgrade: already up to date" || fail "upgrade: unexpected"

# ── 23. upgrade preserves user-added surface ──
cd "$P1" && "$GRIMUAH" add custom 2>/dev/null || true
jq -e '.surfaces[] | select(.name=="custom")' "$P1/architecture.config.json" >/dev/null && ok "upgrade: custom surface added via add" || fail "upgrade: custom surface not added"
cd "$P1" && "$GRIMUAH" upgrade 2>&1 | grep -q "already up to date" && ok "upgrade: preserves user surface" || fail "upgrade: user surface issue"
jq -e '.surfaces[] | select(.name=="custom")' "$P1/architecture.config.json" >/dev/null && ok "  custom surface still in config" || fail "  custom surface removed"

# ── 23b. upgrade migrates the legacy per-layer plugin layout ──
P4="$TMPDIR/p4"
"$GRIMUAH" init "$P4" --preset default 2>/dev/null <<< ""
rm -f "$P4"/.grimuah-rules/*.grit
for L in cosmetic structural resilience behavioural; do
  printf 'engine biome(1.0)\n\n`undefined` where {}\n' > "$P4/.grimuah-rules/$L.grit"
done
jq '.plugins = [".grimuah-rules/cosmetic.grit",".grimuah-rules/structural.grit",".grimuah-rules/resilience.grit",".grimuah-rules/behavioural.grit"]
    | . + {"files": {"includes": ["**", "!dist"]}}' "$P4/biome.json" > "$P4/t.json"
mv "$P4/t.json" "$P4/biome.json"
cd "$P4" && "$GRIMUAH" remove utils >/dev/null 2>&1 || true
cd "$P4" && "$GRIMUAH" upgrade >/dev/null 2>&1 || true
legacy_left=$(jq -r '.plugins[]' "$P4/biome.json" | grep -cE '^\.grimuah-rules/(cosmetic|structural|resilience|behavioural)\.grit$' || true)
test "$legacy_left" = "0" && ok "upgrade: legacy plugin layout migrated" || fail "upgrade: $legacy_left legacy plugin(s) left"
jq -e '.files.includes == ["**", "!dist"]' "$P4/biome.json" >/dev/null && ok "upgrade: user biome.json settings preserved" || fail "upgrade: user settings lost"
missing_plugins=0
while read -r plugin; do test -f "$P4/$plugin" || missing_plugins=$((missing_plugins+1)); done < <(jq -r '.plugins[]' "$P4/biome.json")
test "$missing_plugins" -eq 0 && ok "upgrade: migrated plugins exist" || fail "upgrade: $missing_plugins migrated plugin(s) missing"
"$BIOME" lint "$P4" 2>&1 | grep -q "Failed to compile" && fail "upgrade: migrated rules fail to compile" || ok "upgrade: migrated rules compile"

# ── 24. disable layers ──
cd "$P1"
jq '.layers.cosmetic = false | .layers.structural = false | .layers.resilience = false | .layers.behavioural = false' architecture.config.json > tmp.json
mv tmp.json architecture.config.json
achk | grep -q "grimuah check: clean" && ok "all layers disabled: clean" || fail "all layers disabled: still flagged"
jq '.layers.cosmetic = true | .layers.structural = true | .layers.resilience = true | .layers.behavioural = true' architecture.config.json > tmp.json
mv tmp.json architecture.config.json

# ── 25. .grit files compile with biome ──
for f in "$P1"/.grimuah-rules/*.grit; do
  name="$(basename "$f")"
  dir="$TMPDIR/biome-$name"
  mkdir -p "$dir"
  cp "$f" "$dir/"
  cat > "$dir/biome.json" <<-EOJ
	{ "\$schema": "https://biomejs.dev/schemas/2.5.3/schema.json", "plugins": ["$name"], "linter": { "enabled": true } }
	EOJ
  "$BIOME" lint "$dir" 2>&1 | grep -q "Failed to compile" && fail "  $name fails" || ok "  $name compiles"
done

# ── 26. biome lint on full scaffold ──
"$BIOME" lint "$P1" 2>&1 | grep -q "Failed to compile" && fail "biome lint: scaffold fails" || ok "biome lint: scaffold passes"

echo ""
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
