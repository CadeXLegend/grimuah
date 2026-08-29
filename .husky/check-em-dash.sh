#!/usr/bin/env bash
# ban em-dash in source files
STATUS=0
if grep -rn $'\xe2\x80\x94' src/ --include="*.zig"; then
  echo ""
  echo "em-dash found in source files, banned in this project"
  echo "replace with a comma, colon, or sentence break instead"
  STATUS=1
fi
exit $STATUS
