#!/usr/bin/env bash
# e2e: end-to-end test for grimuah (architecture generator)
# Auto-cleanup via trap
# 60+ checks across init/check/add/remove/upgrade/layers/oracle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRIMUAH="${GRIMUAH:-$SCRIPT_DIR/zig-out/bin/grimuah}"
TMPDIR="$(mktemp -d /tmp/grimuah-e2e-XXXXXXXX)"
P1="$TMPDIR/p1"
PASS=0; FAIL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

ok()     { PASS=$((PASS+1)); echo "  ok $*"; }
fail()   { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
achk()   { cd "$P1" && "$GRIMUAH" check 2>&1 || true; }
dagok(){ jq -e '[.surfaces[].dagOrder] | sort == [range(length)]' "$1" >/dev/null; }

# ── 1. init default ──
"$GRIMUAH" init "$P1" --preset default 2>/dev/null <<< ""
for f in architecture.config.json tsconfig.json package.json .gitignore; do
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
# no formatter ships with the scaffold, so no hook may call one
test -f "$P1/.husky/format-on-commit.sh"  && fail "format-on-commit.sh should not ship" || ok "no format-on-commit.sh"
grep -qE 'pnpm (lint|format)|biome' "$P1/.husky/pre-commit" && fail "pre-commit calls a missing script" || ok "pre-commit calls only shipped scripts"

# ── 4. package.json scripts ──
test "$(jq -r '.scripts.check' "$P1/package.json")" = "grimuah check" && ok "package.json: check runs grimuah" || fail "package.json: check is not grimuah check"
jq -e '[.scripts[] | select(test("biome"))] | length == 0' "$P1/package.json" >/dev/null && ok "package.json: no biome script" || fail "package.json: biome script left"
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

# ── 9. no biome output ──
test -f "$P1/biome.json" && fail "biome.json should not be written" || ok "no biome.json"
test -d "$P1/.grimuah-rules" && fail ".grimuah-rules should not be written" || ok "no .grimuah-rules"

# ── 10. the scaffold carries no subprocess and no other linter ──
grep -rqE 'biome' "$P1/src" "$P1/package.json" "$P1/.husky" && fail "scaffold still references biome" || ok "scaffold references no other linter"

# ── 11. grimuah check clean ──
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

# ── 16b. grimuah check catches the three rules no other engine could compile ──
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
test "$(jq -c '.surfaces[] | select(.name=="validators") | .allowedImports' "$P1/architecture.config.json")" = "[]" && ok "add: no imports the DAG already implies" || fail "add: wrote a redundant allowedImports entry"

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

# ── 24. disable layers ──
cd "$P1"
jq '.layers.cosmetic = false | .layers.structural = false | .layers.resilience = false | .layers.behavioural = false' architecture.config.json > tmp.json
mv tmp.json architecture.config.json
achk | grep -q "grimuah check: clean" && ok "all layers disabled: clean" || fail "all layers disabled: still flagged"
jq '.layers.cosmetic = true | .layers.structural = true | .layers.resilience = true | .layers.behavioural = true' architecture.config.json > tmp.json
mv tmp.json architecture.config.json

# ── 25. frozen oracle ──
oracle_log="$TMPDIR/oracle.log"
if bash "$SCRIPT_DIR/tests/oracle/check.sh" >"$oracle_log" 2>&1; then
  ok "frozen oracle: corpus findings unchanged"
else
  fail "frozen oracle: corpus findings changed"
  tail -20 "$oracle_log"
fi

echo ""
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
