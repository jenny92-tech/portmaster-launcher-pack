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
local runtimes = test.runtimes_of([[java_runtime="zulu11.48.21-ca-jdk11.0.11-linux"
weston_runtime="weston_pkg_0.2"
runtime="zulu11.48.21-ca-jdk11.0.11-linux"
# ignored_runtime="frt_3.6"
]])
assert(#runtimes == 2)
assert(runtimes[1] == "zulu11.48.21-ca-jdk11.0.11-linux")
assert(runtimes[2] == "weston_pkg_0.2")

local health_path=os.tmpname()
local health_file=assert(io.open(health_path,"wb")); health_file:write("hsqs-runtime"); health_file:close()
local health,bytes=test.runtime_file_health(health_path,12)
assert(health=="healthy" and bytes==12)
health,bytes=test.runtime_file_health(health_path,13)
assert(health=="size_mismatch" and bytes==12)
health_file=assert(io.open(health_path,"wb")); health_file:write("nope-runtime"); health_file:close()
health,bytes=test.runtime_file_health(health_path,12)
assert(health=="invalid_magic" and bytes==12)
os.remove(health_path)
health,bytes=test.runtime_file_health(health_path,12)
assert(health=="missing" and bytes==0)

print("appmanager Lua scanner tests: PASS")
