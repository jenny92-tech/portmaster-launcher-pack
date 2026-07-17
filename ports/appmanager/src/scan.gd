# PortMaster ports 目录扫描器。
#
# 唯一危险的地方是"哪个目录属于哪个脚本" —— 判错就是删掉玩家的游戏。真实卡上
# 74 个脚本里，目录名根本不在 `GAMEDIR=` 里的就有一堆:变量名有 GAMEDIR /
# gamedir / rundir 三种，值有 `"/$directory/ports/$PORT_NAME"` 这样的二次间接，
# 还有整个藏在 `for candidate in ... ; [ -d "$candidate" ] && GAMEDIR="$candidate"`
# 的候选列表里、赋值语句里一个字面量都看不到的。所以用两条独立规则:
#
#   L1 精确: 展开 shell 变量求出脚本拥有的目录。驱动"卸载"(要删对)。
#   L2 保守: 只要任何脚本在词边界上提到该目录名, 就算有主。驱动"孤儿判定"。
#
# L2 的漏解只会让我们"少清一个残留项", 永远不会"多删一个游戏" —— 这个不对称是
# 故意的。真卡验证: L1 解出 71/74(其余 3 个是合法的无目录纯脚本 port),
# L1 与 L2 分歧为 0, 孤儿目录 1 个(rainblood, 与它遗留的孤儿图片互相印证)。

extends Reference

# 脚本目录和游戏目录不一定相等 (TrimUI: Roms/PORTS 对 Data/ports)。
var scripts_dir  = ""
var gamedirs_dir = ""
var images_dir = ""
var libs_dir   = ""
var seed_vars  = {}      # $directory / $controlfolder 等由 launcher.sh 注入
var ignore_dirs = []     # PortMaster / images / 我们自己
var ignore_scripts = []  # PortMaster.sh / 本 APP 自己的 .sh
var self_port = ""       # 本 APP 的 PORT_NAME, 用来认出"我自己"(哪怕 .sh 被改名)

var _re_assign = RegEx.new()
var _re_cd     = RegEx.new()
var _re_for    = RegEx.new()
var _re_token  = RegEx.new()
var _re_rt_var = RegEx.new()

# 目录名允许的字符 —— 决定词边界。`brotato` 不能被 `brotato1.15` 的脚本喂活,
# 所以数字/点/连字符都算词内字符。
const WORD_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"


func _init():
	_re_assign.compile("(?m)^[ \\t]*(?:export[ \\t]+)?([A-Za-z_][A-Za-z0-9_]*)=(.+?)[ \\t]*(?:#.*)?$")
	_re_cd.compile("(?m)^[ \\t]*cd[ \\t]+(.+?)[ \\t]*(?:\\|\\|.*)?$")
	_re_for.compile("(?m)^[ \\t]*for[ \\t]+[A-Za-z_][A-Za-z0-9_]*[ \\t]+in[ \\t]+(.+?)[ \\t]*;?[ \\t]*(?:do)?[ \\t]*$")
	_re_token.compile("\"([^\"]+)\"|'([^']+)'|(\\S+)")
	_re_rt_var.compile("(?m)^[ \\t]*(?:export[ \\t]+)?runtime=[\"']?([A-Za-z0-9_.+-]+)[\"']?")


func setup(env):
	scripts_dir  = env.get("scripts_dir", "")
	gamedirs_dir = env.get("gamedirs_dir", "")
	images_dir = env.get("images_dir", "")
	libs_dir   = env.get("libs_dir", "")
	ignore_dirs = env.get("ignore_dirs", [])
	ignore_scripts = env.get("ignore_scripts", [])
	self_port = env.get("self_port", "")
	seed_vars = {
		"directory":     env.get("directory", ""),
		"controlfolder": env.get("controlfolder", ""),
		"HOME":          env.get("home", "/root"),
	}


# ── 文件系统 ─────────────────────────────────────────────────────────
func _list(path, want_dirs):
	var out = []
	if path == "":
		# Directory.open("") 不会失败, 它会落到当前工作目录 —— 也就是 GAMEDIR。
		# 吹米没有图片目录 → images_dir 为空 → 我们把自己的 bootstrap.pck / port.json
		# 当成"孤儿图片"列了出来, 而残留清理页是默认全选一键删的。空路径必须早退。
		return out
	var d = Directory.new()
	if d.open(path) != OK:
		return out
	d.list_dir_begin(true, true)
	while true:
		var n = d.get_next()
		if n == "":
			break
		if d.current_is_dir() == want_dirs:
			out.append(n)
	d.list_dir_end()
	return out


func _read(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var t = f.get_as_text()
	f.close()
	return t


# ── shell 变量展开 ───────────────────────────────────────────────────
func _collect_vars(text):
	var v = seed_vars.duplicate()
	for m in _re_assign.search_all(text):
		var name = m.get_string(1)
		var val = m.get_string(2).strip_edges()
		# 命令替换 $(...) / `...` 求不出来, 跳过而不是瞎猜
		if val.begins_with("$(") or val.begins_with("`"):
			continue
		val = val.split(";")[0].strip_edges()
		val = _unquote(val)
		if not v.has(name):
			v[name] = val
	return v


func _unquote(s):
	s = s.strip_edges()
	if s.length() >= 2:
		var a = s[0]
		var b = s[s.length() - 1]
		if (a == "\"" and b == "\"") or (a == "'" and b == "'"):
			return s.substr(1, s.length() - 2)
	return s


# 未知变量替换成哨兵而不是整条放弃 —— 上游一个 $SCRIPT_DIR 不该拖垮整条路径,
# 我们只需要路径里那个字面量目录名。
func _expand(val, vars_):
	var out = val
	for _i in range(6):
		var prev = out
		var res = ""
		var i = 0
		while i < out.length():
			var c = out[i]
			if c != "$":
				res += c
				i += 1
				continue
			var j = i + 1
			var braced = j < out.length() and out[j] == "{"
			if braced:
				j += 1
			var start = j
			while j < out.length() and (out[j] in WORD_CHARS) and out[j] != "." and out[j] != "-":
				j += 1
			var name = out.substr(start, j - start)
			if braced and j < out.length() and out[j] == "}":
				j += 1
			if name == "":
				res += c
				i += 1
				continue
			res += vars_.get(name, " ")
			i = j
		out = res
		if out == prev:
			break
	return out


# 展开后的路径 → 端口目录名。优先取 "/ports/" 之后那一段(能正确处理
# `cd "$gamedir/gamedata"` —— gamedata 不是端口目录, gamedir 才是);
# 没有 /ports/ 段就退回最后一个字面量段(FileManager 那种 $SCRIPT_DIR/FileManager)。
func _dir_from_path(p):
	p = p.replace("\\", "/")
	while p.ends_with("/"):
		p = p.substr(0, p.length() - 1)
	var parts = []
	for seg in p.split("/"):
		if seg != "" and seg.find(" ") < 0:
			parts.append(seg)
	if parts.empty():
		return ""
	var idx = parts.find("ports")
	if idx >= 0 and idx + 1 < parts.size():
		return parts[idx + 1]
	return parts[parts.size() - 1]


# L1: 这个脚本拥有哪个目录。real_dirs 里存在的优先; 都不存在时返回它声称的那个
# (脚本还在、目录没了 = 死脚本)。
func port_dir_of(text, real_dirs):
	var vars_ = _collect_vars(text)
	var cands = []
	for k in ["GAMEDIR", "gamedir", "rundir", "game_dir"]:
		if vars_.has(k):
			cands.append(vars_[k])
	for m in _re_cd.search_all(text):
		cands.append(_unquote(m.get_string(1)))
	# 目录名可能只出现在 for 的候选列表里, 赋值语句里一个字面量都没有
	for m in _re_for.search_all(text):
		for t in _re_token.search_all(m.get_string(1)):
			for g in range(1, 4):
				var s = t.get_string(g)
				if s != "":
					cands.append(s)

	var claimed = ""
	for c in cands:
		var p = _expand(c, vars_)
		var name = _dir_from_path(p)
		if name == "" or name in ignore_dirs:
			continue
		if real_dirs.has(name):
			return {"dir": name, "exists": true}
		# 目录不存在 = 可能是死脚本。但只有在我们真有把握时才这么说: 路径里必须
		# 出现 ports 段(否则 `cd autoinstall` 这种相对路径会被当成端口目录), 且
		# 名字里不能有 shell 元字符(否则 `cd $(pgrep ...)` 会变成一个"目录名")。
		# 实测这两条各挡掉一个误报。误报一个死脚本 = 劝用户删掉一个能用的端口。
		if claimed == "" and p.find("/ports/") >= 0 and _plain_name(name):
			claimed = name
	if claimed != "":
		return {"dir": claimed, "exists": false}
	return {"dir": "", "exists": false}


func _plain_name(name):
	for ch in ["$", "(", ")", "`", "*", "?", "\"", "'", " ", "|", ";", "&", "="]:
		if name.find(ch) >= 0:
			return false
	return true


# L2: 词边界提及。解析失败只会让孤儿漏报, 不会让游戏误删。
func mentions(text, name):
	var from = 0
	while true:
		var i = text.find(name, from)
		if i < 0:
			return false
		var before_ok = i == 0 or not (text[i - 1] in WORD_CHARS)
		var e = i + name.length()
		var after_ok = e >= text.length() or not (text[e] in WORD_CHARS)
		if before_ok and after_ok:
			return true
		from = i + 1
	return false


# ── runtime ──────────────────────────────────────────────────────────
# 只认 SH 明确声明的 runtime=。不从 libs 路径、注释、glob 或启动器辅助代码推测，
# 避免把可选回退方案误报成用户必须安装的依赖。
func runtime_of(text):
	var code = ""
	for line in text.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		code += line + "\n"

	var match_ = _re_rt_var.search(code)
	return "" if match_ == null else match_.get_string(1)


# ── 主扫描 ───────────────────────────────────────────────────────────
func scan():
	var real_dirs = {}
	for d in _list(gamedirs_dir, true):
		if not (d in ignore_dirs):
			real_dirs[d] = true

	var image_files = _list(images_dir, false)
	var scripts = []
	for f in _list(scripts_dir, false):
		# PortMaster 自己和本 APP 自己不参与扫描: 它们不是游戏端口, 列出来只会让
		# 用户在管理器里把管理器卸载掉; PortMaster.sh 里的相对 cd 还会被误判成死脚本。
		if f.to_lower().ends_with(".sh") and not (f in ignore_scripts):
			scripts.append(f)
	scripts.sort()

	var texts = {}
	for s in scripts:
		texts[s] = _read(scripts_dir + "/" + s)

	# 认出"我自己"不能只靠文件名: 前端会把 port 脚本拷成 .port.sh 再跑, 用户也可能
	# 把 APP Manager.sh 改名。任何引用了本 APP 目录名的脚本就是我们自己, 不列出 ——
	# 否则用户能在管理器里把管理器卸载掉。
	if self_port != "":
		var keep = []
		for s in scripts:
			if not mentions(texts[s], self_port):
				keep.append(s)
		scripts = keep

	# 脚本名 -> 图片(同名不同后缀)
	var images_of = {}
	for s in scripts:
		var stem = s.substr(0, s.length() - 3)
		var imgs = []
		for img in image_files:
			if _stem(img) == stem:
				imgs.append(img)
		images_of[s] = imgs

	var ports = []
	var refcount = {}          # 目录 -> 拥有它的脚本数(共用目录不能连坐删)
	var dead = []
	for s in scripts:
		var r = port_dir_of(texts[s], real_dirs)
		var rt = runtime_of(texts[s])
		if r.dir != "" and r.exists:
			refcount[r.dir] = refcount.get(r.dir, 0) + 1
		elif r.dir != "":
			dead.append({"script": s, "missing_dir": r.dir})
		ports.append({
			"script": s,
			"dir": r.dir if r.exists else "",
			"claimed_dir": r.dir,
			"dir_exists": r.exists,
			"images": images_of[s],
			"runtime": rt,
		})

	# 孤儿目录: 没有任何脚本在词边界上提到它
	var orphan_dirs = []
	for d in real_dirs.keys():
		var seen = false
		for s in scripts:
			if mentions(texts[s], d):
				seen = true
				break
		if not seen:
			orphan_dirs.append(d)
	orphan_dirs.sort()

	# 孤儿图片: 有图无脚本
	var stems = {}
	for s in scripts:
		stems[s.substr(0, s.length() - 3)] = true
	var orphan_images = []
	for img in image_files:
		if not stems.has(_stem(img)):
			orphan_images.append(img)
	orphan_images.sort()

	return {
		"ports": ports,
		"refcount": refcount,
		"orphan_dirs": orphan_dirs,
		"orphan_images": orphan_images,
		"dead_scripts": dead,
		"runtimes": _runtime_report(ports),
	}


func _stem(name):
	var i = name.rfind(".")
	return name if i <= 0 else name.substr(0, i)


func _runtime_report(ports):
	var have = {}
	for f in _list(libs_dir, false):
		if f.ends_with(".squashfs"):
			have[f.substr(0, f.length() - 9)] = true

	var need = {}     # runtime 名 -> 需要它的脚本
	for p in ports:
		if p.runtime != "":
			if not need.has(p.runtime):
				need[p.runtime] = []
			need[p.runtime].append(p.script)

	var missing = []
	for r in need.keys():
		if not have.has(r):
			missing.append({"name": r, "users": need[r]})

	return {"have": have.keys(), "need": need, "missing": missing}
