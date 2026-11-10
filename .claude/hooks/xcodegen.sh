#!/bin/sh
# After an edit: regenerate the Xcode project when project.yml changed or a Swift file was written.
input=$(cat)
file=$(printf '%s' "$input" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""), d.get("tool_input",{}).get("file_path",""))')
tool=${file%% *}
path=${file#* }
case "$path" in
    "$CLAUDE_PROJECT_DIR"/project.yml) ;;
    "$CLAUDE_PROJECT_DIR"/*.swift) [ "$tool" = Write ] || exit 0 ;;
    *) exit 0 ;;
esac
cd "$CLAUDE_PROJECT_DIR" || exit 0
if ! output=$(xcodegen generate --quiet 2>&1); then
    printf 'xcodegen failed:\n%s\n' "$output" >&2
    exit 2
fi
