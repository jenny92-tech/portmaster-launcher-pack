package.path = arg[1] .. "/?.lua;" .. package.path
local scan = require("scan")
local test = scan._test

local dirs = {hollowknight=true, sts2=true, FileManager=true}
local seed = {directory="mnt/card/Data", controlfolder="/ports/PortMaster", HOME="/root"}

local direct = [[
PORT_NAME=hollowknight
GAMEDIR="/$directory/ports/$PORT_NAME"
cd "$GAMEDIR"
]]
local result = test.port_dir_of(direct, dirs, seed, {})
assert(result.dir == "hollowknight" and result.exists)

local candidates = [[
for candidate in "/$directory/ports/sts2" "/sdcard/roms/ports/sts2"; do
  [ -d "$candidate" ] && GAMEDIR="$candidate"
done
]]
result = test.port_dir_of(candidates, dirs, seed, {})
assert(result.dir == "sts2" and result.exists)

local fallback = [[
SCRIPT_DIR=/roms/ports
cd "$SCRIPT_DIR/FileManager"
]]
result = test.port_dir_of(fallback, dirs, seed, {})
assert(result.dir == "FileManager" and result.exists)

local dangerous = [[cd $(pgrep game) || exit 1]]
result = test.port_dir_of(dangerous, {}, seed, {})
assert(result.dir == "")

assert(test.mentions("/ports/brotato/", "brotato"))
assert(not test.mentions("/ports/brotato1.15/", "brotato"))

assert(test.runtime_of("# runtime=frt_3.6\nruntime=godot_4.5\n") == "godot_4.5")
assert(test.runtime_of("# runtime=frt_3.6\n") == "")

print("appmanager Lua scanner tests: PASS")
