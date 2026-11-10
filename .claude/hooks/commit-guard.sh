#!/bin/sh
# Before a git commit: refuse while temporary test code, marked dbg or DBG, is still in the tree.
input=$(cat)
command=$(printf '%s' "$input" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))')
case "$command" in
    *"git commit"*) ;;
    *) exit 0 ;;
esac
cd "$CLAUDE_PROJECT_DIR" || exit 0
marker='(^|[^[:alnum:]_])(dbg|DBG)'
found=$(git diff HEAD -U0 -- '*.swift' | grep -E '^\+' | grep -v '^+++' | grep -E "$marker")
untracked=$(git ls-files -o --exclude-standard -- '*.swift' | while read -r file; do grep -HnE "$marker" "$file"; done)
if [ -n "$found$untracked" ]; then
    printf 'Temporary test code is still in the tree. Remove it before committing:\n%s\n%s\n' "$found" "$untracked" >&2
    exit 2
fi
