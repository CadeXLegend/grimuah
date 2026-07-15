#!/usr/bin/env bash
# e2e: end-to-end test for arch (architecture generator)
# Auto-cleanup via trap. 50+ checks across init/check/add/remove/upgrade/biome.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH="${ARCH:-$SCRIPT_DIR/zig-out/bin/arch}"
BIOME="${BIOME:-biome}"
TMPDIR="$(mktemp -d /tmp/arch-e2e-XXXXXXXX)"
P1="$TMPDIR/p1"
PASS=0; FAIL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

ok()     { PASS=$((PASS+1)); echo "  ok $*"; }
fail()   { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
achk()   { cd "$P1" && "$ARCH" check 2>&1 || true; }
depthok(){ jq -e '[.surfaces[].depth] | sort == [range(length)]' "$1" >/dev/null; }

"$BIOME" --version >/dev/null 2>&1 || { echo "biome not found"; exit 1; }

# ── 1. init default ──
"$ARCH" init "$P1" --preset default 2>/dev/null <<< ""
for f in architecture.config.json tsconfig.json package.json biome.json; do
  test -f "$P1/$f" && ok "$f" || fail "missing $f"
done
for d in utils services components; do
  test -d "$P1/src/$d" && ok "src/$d" || fail "missing src/$d"
done

s=$(jq '.surfaces | length' "$P1/architecture.config.json"); test "$s" -eq 3 && ok "3 surfaces" || fail "expected 3, got $s"
depthok "$P1/architecture.config.json" && ok "depths sequential" || fail "depths not sequential"

# ── 2. init bot ──
"$ARCH" init "$TMPDIR/p2" --preset bot 2>/dev/null <<< "n"
s=$(jq '.surfaces | length' "$TMPDIR/p2/architecture.config.json"); test "$s" -eq 8 && ok "bot: 8 surfaces" || fail "bot: expected 8, got $s"
depthok "$TMPDIR/p2/architecture.config.json" && ok "bot: depths 0-7" || fail "bot: depths not sequential"
jq -e '.rootLib.enabled' "$TMPDIR/p2/architecture.config.json" >/dev/null && ok "bot: rootLib enabled" || fail "bot: rootLib missing"

# ── 3. tsconfig ──
t=$(jq -r '.compilerOptions.target' "$P1/tsconfig.json");     test "$t" = "ES2022"   && ok "tsconfig target ES2022"     || fail "tsconfig target: $t"
m=$(jq -r '.compilerOptions.module' "$P1/tsconfig.json");     test "$m" = "ES2022"   && ok "tsconfig module ES2022"     || fail "tsconfig module: $m"

# ── 4. example file suffixes ──
test -f "$P1/src/utils/example.util.ts"          && ok "example.util.ts"          || fail "missing example.util.ts"
test -f "$P1/src/services/example.service.ts"    && ok "example.service.ts"       || fail "missing example.service.ts"
test -f "$P1/src/components/example.component.ts"&& ok "example.component.ts"      || fail "missing example.component.ts"

# ── 5. biome.json plugins ──
test "$(jq '.plugins | length' "$P1/biome.json")" = "4" && ok "biome.json: 4 plugins" || fail "biome.json: expected 4"

# ── 6. .grit files ──
test "$(find "$P1/arch-rules" -name '*.grit' | wc -l)" = "4" && ok "4 .grit files" || fail "expected 4"
for L in cosmetic structural resilience behavioural; do
  f="$P1/arch-rules/$L.grit"
  test -f "$f" && ok "  $L.grit" || { fail "  $L.grit missing"; continue; }
  test "$(head -1 "$f")" = "engine biome(1.0)" && ok "  $L.grit engine line" || fail "  $L.grit bad engine"
done

# ── 7. check clean ──
echo "// extra" > "$P1/src/utils/second.util.ts"
echo "// extra" > "$P1/src/services/second.service.ts"
echo "// extra" > "$P1/src/components/second.component.ts"
achk | grep -q "arch check: clean" && ok "check: clean on multi-file" || fail "check not clean"

# ── 8. check catches wrong suffix ──
echo "junk" > "$P1/src/services/wrong.txt"
achk | grep -qE "wrong\.txt.*does not match" && ok "check: catches wrong suffix" || fail "check: missed wrong suffix"
rm "$P1/src/services/wrong.txt"

# ── 9. check catches centralized dirs ──
mkdir -p "$P1/src/config"
echo "export {}" > "$P1/src/config/app.config.ts"
achk | grep -q "centralized.*config/" && ok "check: catches centralized config/" || fail "check: missed centralized dir"
rm -rf "$P1/src/config"

# ── 10. check catches import firewall ──
echo "import { x } from '../components';" > "$P1/src/services/import-test.service.ts"
achk | grep -q "importing from 'components'" && ok "check: catches import firewall" || fail "check: missed import violation"
rm "$P1/src/services/import-test.service.ts"

# ── 11. add ──
cd "$P1" && "$ARCH" add validators 2>/dev/null || true
test -d "$P1/src/validators" && ok "add: creates dir" || fail "add: no dir"
test -f "$P1/src/validators/example.validator.ts" && ok "add: example.validator.ts" || fail "add: no example"
jq -e '.surfaces[] | select(.name=="validators")' "$P1/architecture.config.json" >/dev/null && ok "add: surface in config" || fail "add: missing from config"

# ── 12. add suffix heuristics ──
cd "$P1" && "$ARCH" add guards 2>/dev/null || true
test "$(jq -r '.surfaces[] | select(.name=="guards") | .suffixes[0]' "$P1/architecture.config.json")" = ".guard.ts" && ok "add guards: .guard.ts" || fail "add guards"
cd "$P1" && "$ARCH" add states 2>/dev/null || true
test "$(jq -r '.surfaces[] | select(.name=="states") | .suffixes[0]' "$P1/architecture.config.json")" = ".state.ts" && ok "add states: .state.ts" || fail "add states"
cd "$P1" && "$ARCH" add repositories 2>/dev/null || true
test "$(jq -r '.surfaces[] | select(.name=="repositories") | .suffixes[0]' "$P1/architecture.config.json")" = ".repo.ts" && ok "add repos: .repo.ts" || fail "add repos"

# ── 13. add rejects duplicate ──
cd "$P1" && "$ARCH" add validators 2>&1 | grep -q "already exists" && ok "add: rejects duplicate" || fail "add: duplicate allowed"

# ── 14. remove ──
cd "$P1" && "$ARCH" remove validators 2>&1 | grep -q "removed surface" && ok "remove: succeeded" || fail "remove: failed"
test ! -d "$P1/src/validators" && ok "remove: dir deleted" || fail "remove: dir left"
jq -e '.surfaces[] | select(.name=="validators")' "$P1/architecture.config.json" >/dev/null 2>&1 && fail "remove: surface left in config" || ok "remove: stripped from config"

# ── 15. remove non-existent ──
cd "$P1" && "$ARCH" remove nonexistent 2>&1 | grep -q "not found" && ok "remove: errors on missing" || fail "remove: no error"

# ── 16. upgrade "already up to date" ──
cd "$P1" && "$ARCH" upgrade 2>&1 | grep -q "already up to date" && ok "upgrade: already up to date" || fail "upgrade: unexpected"

# ── 17. upgrade preserves user-added surface ──
cd "$P1" && "$ARCH" add custom 2>/dev/null || true
jq -e '.surfaces[] | select(.name=="custom")' "$P1/architecture.config.json" >/dev/null && ok "upgrade: custom surface added via add" || fail "upgrade: custom surface not added"
cd "$P1" && "$ARCH" upgrade 2>&1 | grep -q "already up to date" && ok "upgrade: preserves user surface" || fail "upgrade: user surface issue"
jq -e '.surfaces[] | select(.name=="custom")' "$P1/architecture.config.json" >/dev/null && ok "  custom surface still in config" || fail "  custom surface removed"

# ── 18. disable layers ──
cd "$P1"
jq '.layers.cosmetic = false | .layers.structural = false | .layers.resilience = false | .layers.behavioural = false' architecture.config.json > tmp.json
mv tmp.json architecture.config.json
achk | grep -q "arch check: clean" && ok "all layers disabled: clean" || fail "all layers disabled: still flagged"
jq '.layers.cosmetic = true | .layers.structural = true | .layers.resilience = true | .layers.behavioural = true' architecture.config.json > tmp.json
mv tmp.json architecture.config.json

# ── 19. .grit files compile with biome ──
for L in cosmetic structural resilience behavioural; do
  dir="$TMPDIR/biome-$L"
  mkdir -p "$dir"
  cp "$P1/arch-rules/$L.grit" "$dir/"
  cat > "$dir/biome.json" <<-EOJ
	{ "\$schema": "https://biomejs.dev/schemas/2.5.3/schema.json", "plugins": ["$L.grit"], "linter": { "enabled": true } }
	EOJ
  "$BIOME" lint "$dir" 2>&1 | grep -q "Failed to compile" && fail "  $L.grit fails" || ok "  $L.grit compiles"
done

# ── 20. biome lint on full scaffold ──
"$BIOME" lint "$P1" 2>&1 | grep -q "Failed to compile" && fail "biome lint: scaffold fails" || ok "biome lint: scaffold passes"

echo ""
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
