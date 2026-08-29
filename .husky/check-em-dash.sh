#!/usr/bin/env bash
# ban em-dash in generator source and shipped TS templates
# an em-dash in a shipped template would make every generated project trip its
# own cosmetic.grit rule, so these files are scanned along with the zig source
# gritql.zig is exempt: it must contain the literal em-dash to match it
STATUS=0
for dir in src code-patterns; do
  if grep -rn $'\xe2\x80\x94' "$dir" --include="*.zig" --include="*.ts" | grep -v 'gritql.zig'; then
    echo ""
    echo "em-dash found in $dir, banned in this project"
    echo "replace with a comma, colon, or sentence break instead"
    STATUS=1
  fi
done
exit $STATUS
