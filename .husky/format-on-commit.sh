#!/usr/bin/env bash
STAGED_FILES=$(git diff --cached --name-only)
pnpm format
UNSTAGED_FILES=$(git diff --name-only)
FILES_TO_RESTAGE=$(comm -12 <(echo "$STAGED_FILES" | sort) <(echo "$UNSTAGED_FILES" | sort))
if [ -n "$FILES_TO_RESTAGE" ]; then
  echo "$FILES_TO_RESTAGE" | xargs git add
  echo "Re-staged formatted files:"
  echo "$FILES_TO_RESTAGE"
else
  echo "All staged files were already properly formatted."
fi
