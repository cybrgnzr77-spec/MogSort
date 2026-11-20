#!/bin/sh
# Runs every MogSort test. Needs a Lua 5.3 interpreter (texlua works).
# Optional: pass the path to FFXiMain.dll to also test against the real client code (the DLL is only read).
#   sh tests/run_all.sh "D:/.../FINAL FANTASY XI/FFXiMain.dll"
cd "$(dirname "$0")/.." || exit 1
LUA=${LUA:-texlua}
"$LUA" tests/test_sortcore.lua || exit 1
"$LUA" tests/test_consolidate.lua || exit 1
"$LUA" tests/test_addon.lua "$@" || exit 1
