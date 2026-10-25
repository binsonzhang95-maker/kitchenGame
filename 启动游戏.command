#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h}"
ENGINE="/Users/kari/Documents/Codex/2026-10-24/task-4/tools/official-godot-4.5.1-20261024/engine/Godot.app/Contents/MacOS/Godot"
if [[ ! -x "$ENGINE" ]]; then
  print "未找到已验证的 Godot。请查看本目录 README.md。"
  read "reply?按回车退出…"
  exit 1
fi
exec "$ENGINE" --path "$PROJECT_DIR"
