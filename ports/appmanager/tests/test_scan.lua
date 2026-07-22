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

local list_calls=0
scan.set_list_provider(function(path,want_dirs)
    list_calls=list_calls+1
    return {
        {name="Data",path=path.."/Data",is_dir=true},
        {name="Game.sh",path=path.."/Game.sh",is_dir=false},
    }
end)
assert(#scan.entries("/ports")==2 and #scan.entries("/ports")==2 and list_calls==1)
scan.invalidate("/ports")
assert(#scan.entries("/ports")==2 and list_calls==2)
scan.set_list_provider(nil)

scan.set_list_provider(function(path)
    if path=="/games" then
        return {
            {name="autoinstall",path="/games/autoinstall",is_dir=true},
            {name="Orphan",path="/games/Orphan",is_dir=true},
        }
    end
    return {}
end)
local ignored=scan.run({gamedirs_dir="/games",scripts_dir="/scripts",images_dir="/images",
    ignore_dirs={"autoinstall"},ignore_scripts={}})
assert(#ignored.orphan_dirs==1 and ignored.orphan_dirs[1]=="Orphan")
scan.set_list_provider(nil)

-- Launcher artwork matches only when the complete stem is identical. Scan both
-- the SH directory and the device-specific frontend image directory; changing
-- case is not a match on case-sensitive devices.
scan.invalidate("/games","/scripts","/images")
scan.set_list_provider(function(path)
    if path=="/scripts" then
        return {
            {name="Game.sh",path="/scripts/Game.sh",is_dir=false},
            {name="Game.png",path="/scripts/Game.png",is_dir=false},
            {name="game.jpg",path="/scripts/game.jpg",is_dir=false},
        }
    elseif path=="/images" then
        return {
            {name="Game.webp",path="/images/Game.webp",is_dir=false},
            {name="GAME.png",path="/images/GAME.png",is_dir=false},
        }
    end
    return {}
end)
local artwork=scan.run({gamedirs_dir="/games",scripts_dir="/scripts",images_dir="/images",scan_script_images=true,
    ignore_dirs={},ignore_scripts={}})
assert(#artwork.ports==1 and artwork.ports[1].script=="Game.sh")
assert(#artwork.ports[1].images==2)
assert(artwork.ports[1].images[1].path=="/images/Game.webp")
assert(artwork.ports[1].images[2].path=="/scripts/Game.png")
assert(#artwork.orphan_images==2)
assert(artwork.orphan_images[1].path=="/images/GAME.png")
assert(artwork.orphan_images[2].path=="/scripts/game.jpg")

scan.invalidate("/games","/scripts","/images")
local trimui_artwork=scan.run({gamedirs_dir="/games",scripts_dir="/scripts",images_dir="/images",
    scan_script_images=false,ignore_dirs={},ignore_scripts={}})
assert(#trimui_artwork.ports==1 and #trimui_artwork.ports[1].images==1)
assert(trimui_artwork.ports[1].images[1].path=="/images/Game.webp")
assert(#trimui_artwork.orphan_images==1 and trimui_artwork.orphan_images[1].path=="/images/GAME.png")
scan.set_list_provider(nil)

local read_path=os.tmpname()
local read_file=assert(io.open(read_path,"wb")); read_file:write("first"); read_file:close()
assert(scan.read(read_path)=="first")
read_file=assert(io.open(read_path,"wb")); read_file:write("second"); read_file:close()
assert(scan.read(read_path)=="first")
scan.invalidate(read_path)
assert(scan.read(read_path)=="second")
os.remove(read_path)

print("appmanager Lua scanner tests: PASS")
