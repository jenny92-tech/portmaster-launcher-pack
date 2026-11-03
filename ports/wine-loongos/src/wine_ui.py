# INPUT:  SDL2/SDL2_ttf 画布、游戏列表与玩家可选的本地封面
# OUTPUT: 掌机游戏库、文件/按键说明和统一全屏启动画面
# POS:    仅负责 Je-Wine 的视觉，不安装环境或启动游戏
from collections import OrderedDict
import ctypes as c
import hashlib
import math
from pathlib import Path
import struct
import zlib


class Rect(c.Structure):
    _fields_ = [(name, c.c_int) for name in ('x', 'y', 'w', 'h')]


class Color(c.Structure):
    _fields_ = [(name, c.c_uint8) for name in ('r', 'g', 'b', 'a')]


INK = (238, 241, 251)
MUTED = (157, 168, 190)
MINT = (174, 242, 214)
VIOLET = (179, 158, 244)
AMBER = (244, 194, 132)
PANEL = (24, 30, 46)


def read_png(path):
    """Bounded, non-interlaced 8-bit RGB/RGBA covers; no image dependency on the device."""
    data = path.read_bytes()
    if len(data) > 16 * 1024 * 1024 or data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Unsupported cover')
    offset, packed, dimensions, ended = 8, bytearray(), None, False
    while offset + 12 <= len(data):
        length, kind = struct.unpack_from('>I4s', data, offset)
        payload = data[offset + 8:offset + 8 + length]
        if len(payload) != length or offset + length + 12 > len(data):
            raise ValueError('Incomplete cover')
        if zlib.crc32(kind + payload) & 0xffffffff != struct.unpack_from('>I', data, offset + 8 + length)[0]:
            raise ValueError('Damaged cover')
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            if not (0 < width <= 1024 and 0 < height <= 1024 and depth == 8 and color in (2, 6)
                    and compression == filtering == interlace == 0):
                raise ValueError('Unsupported cover dimensions or format')
            dimensions = width, height, 3 if color == 2 else 4
        elif kind == b'IDAT':
            packed.extend(payload)
        elif kind == b'IEND':
            ended = True
            break
        offset += length + 12
    if dimensions is None or not ended:
        raise ValueError('Missing cover dimensions')
    width, height, channels = dimensions
    stride = width * channels
    expected = (stride + 1) * height
    decoder = zlib.decompressobj()
    raw = decoder.decompress(packed, expected + 1)
    if len(raw) != expected or not decoder.eof:
        raise ValueError('Invalid cover pixels')
    pixels, previous = bytearray(), bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        mode, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if mode > 4:
            raise ValueError('Unsupported cover filter')
        for x in range(stride):
            left, above = row[x - channels] if x >= channels else 0, previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if mode == 1:
                prediction = left
            elif mode == 2:
                prediction = above
            elif mode == 3:
                prediction = (left + above) // 2
            elif mode == 4:
                estimate = left + above - corner
                distances = [abs(estimate - value) for value in (left, above, corner)]
                prediction = (left, above, corner)[distances.index(min(distances))]
            else:
                prediction = 0
            row[x] = (row[x] + prediction) & 255
        if channels == 4:
            pixels.extend(row)
        else:
            for x in range(0, stride, 3):
                pixels.extend(row[x:x + 3] + b'\xff')
        previous = row
    return width, height, pixels


class LibraryView:
    def __init__(self, sdl, ttf, renderer, width, height, font):
        self.sdl, self.ttf, self.renderer = sdl, ttf, renderer
        self.width, self.height, self.font_path = width, height, font
        self.scale = min(width / 960, height / 720)
        self.fonts, self.labels, self.covers = {}, OrderedDict(), OrderedDict()
        sdl.SDL_SetRenderDrawBlendMode(renderer, 1)

    def close(self):
        for cache in (self.labels, self.covers):
            for value in cache.values():
                if value:
                    self.sdl.SDL_DestroyTexture(value[0])
            cache.clear()
        for font in self.fonts.values():
            self.ttf.TTF_CloseFont(font)
        self.fonts.clear()

    def present(self):
        self.sdl.SDL_RenderPresent(self.renderer)

    def color(self, value):
        self.sdl.SDL_SetRenderDrawColor(self.renderer, *value[:3], value[3] if len(value) == 4 else 255)

    def box(self, x, y, width, height, color, radius=0):
        self.color(color)
        x, y, width, height = map(round, (x, y, width, height))
        radius = min(round(radius), width // 2, height // 2)
        if radius <= 0:
            self.sdl.SDL_RenderFillRect(self.renderer, c.byref(Rect(x, y, width, height)))
            return
        self.sdl.SDL_RenderFillRect(self.renderer, c.byref(Rect(x, y + radius, width, height - 2 * radius)))
        for row in range(radius):
            inset = radius - round(math.sqrt(max(0, radius * radius - (radius - row - .5) ** 2)))
            for line in (y + row, y + height - row - 1):
                self.sdl.SDL_RenderDrawLine(self.renderer, x + inset, line, x + width - inset - 1, line)

    def line(self, x1, y1, x2, y2, color):
        self.color(color)
        self.sdl.SDL_RenderDrawLine(self.renderer, *map(round, (x1, y1, x2, y2)))

    def circle(self, x, y, radius, color):
        self.color(color)
        for row in range(-round(radius), round(radius) + 1):
            half = math.sqrt(max(0, radius * radius - row * row))
            self.sdl.SDL_RenderDrawLine(self.renderer, round(x - half), round(y + row), round(x + half), round(y + row))

    def polygon(self, points, color):
        self.color(color)
        for y in range(math.ceil(min(p[1] for p in points)), math.ceil(max(p[1] for p in points))):
            edges = []
            for a, b in zip(points, [*points[1:], points[0]]):
                if min(a[1], b[1]) <= y < max(a[1], b[1]):
                    edges.append(a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]))
            edges.sort()
            for x1, x2 in zip(edges[::2], edges[1::2]):
                self.sdl.SDL_RenderDrawLine(self.renderer, round(x1), y, round(x2), y)

    def gradient(self, x, y, width, height, top, bottom):
        for row in range(max(1, round(height))):
            fraction = row / max(1, height - 1)
            color = tuple(round(a + (b - a) * fraction) for a, b in zip(top, bottom))
            self.line(x, y + row, x + width - 1, y + row, color)

    def font(self, size, bold=False):
        key = max(10, round(size)), bold
        if key not in self.fonts:
            font = self.ttf.TTF_OpenFont(str(self.font_path).encode(), key[0])
            if not font:
                raise RuntimeError('无法打开启动器字体')
            self.ttf.TTF_SetFontStyle(font, int(bold))
            self.fonts[key] = font
        return self.fonts[key]

    def measure(self, text, size, bold=False):
        width, height = c.c_int(), c.c_int()
        self.ttf.TTF_SizeUTF8(self.font(size, bold), text.encode(), c.byref(width), c.byref(height))
        return width.value, height.value

    def text(self, value, x, y, size=18, color=INK, max_width=None, bold=False):
        value = str(value).replace('\n', ' ')
        if not value:
            return 0
        if max_width is not None and self.measure(value, size, bold)[0] > max_width:
            lo, hi = 0, len(value)
            while lo < hi:
                mid = (lo + hi + 1) // 2
                if self.measure(value[:mid] + '…', size, bold)[0] <= max_width:
                    lo = mid
                else:
                    hi = mid - 1
            value = value[:lo] + '…'
        key = value, round(size), tuple(color), bold
        if key not in self.labels:
            surface = self.ttf.TTF_RenderUTF8_Blended(self.font(size, bold), value.encode(), Color(*color, 255))
            if not surface:
                return 0
            texture = self.sdl.SDL_CreateTextureFromSurface(self.renderer, surface)
            self.sdl.SDL_FreeSurface(surface)
            if not texture:
                return 0
            width, height = self.measure(value, size, bold)
            self.labels[key] = texture, width, height
            if len(self.labels) > 192:
                self.sdl.SDL_DestroyTexture(self.labels.popitem(last=False)[1][0])
        texture, width, height = self.labels[key]
        self.labels.move_to_end(key)
        self.sdl.SDL_RenderCopy(self.renderer, texture, None, c.byref(Rect(round(x), round(y), width, height)))
        return width

    def wrap(self, value, x, y, width, size, color=MUTED, lines=2):
        remaining = str(value)
        for index in range(lines):
            if not remaining:
                break
            if index == lines - 1:
                self.text(remaining, x, y, size, color, width)
                break
            end = 1
            while end < len(remaining) and self.measure(remaining[:end + 1], size)[0] <= width:
                end += 1
            self.text(remaining[:end], x, y, size, color, width)
            remaining, y = remaining[end:], y + size * 1.55

    def pill(self, value, x, y, color=VIOLET):
        s = self.scale
        width = self.measure(value, 13 * s)[0] + 22 * s
        self.box(x, y, width, 27 * s, (*color, 23), 8 * s)
        self.text(value, x + 11 * s, y + 3 * s, 13 * s, color)
        return width

    def icon(self, name, x, y, size, color):
        unit = size / 24
        if name == 'wine':
            for points in [[(2, 5), (7, 19), (12, 8), (17, 19), (22, 5)]]:
                for a, b in zip(points, points[1:]):
                    for offset in (0, 1):
                        self.line(x + a[0] * unit, y + a[1] * unit + offset, x + b[0] * unit, y + b[1] * unit + offset, color)
        elif name == 'play':
            self.polygon([(x + 7 * unit, y + 4 * unit), (x + 20 * unit, y + 12 * unit), (x + 7 * unit, y + 20 * unit)], color)
        elif name == 'refresh':
            for i in range(29):
                a, b = i / 28 * 5.1 - 1.5, (i + 1) / 28 * 5.1 - 1.5
                self.line(x + (12 + 8 * math.cos(a)) * unit, y + (12 + 8 * math.sin(a)) * unit,
                          x + (12 + 8 * math.cos(b)) * unit, y + (12 + 8 * math.sin(b)) * unit, color)
            self.polygon([(x + 10 * unit, y), (x + 16 * unit, y + 4 * unit), (x + 10 * unit, y + 8 * unit)], color)
        else:
            self.box(x + 2 * unit, y + 6 * unit, 20 * unit, 15 * unit, (*color, 45), 3 * unit)
            self.line(x + 2 * unit, y + 6 * unit, x + 12 * unit, y + unit, color)
            self.line(x + 12 * unit, y + unit, x + 22 * unit, y + 6 * unit, color)
            self.line(x + 12 * unit, y + 8 * unit, x + 12 * unit, y + 18 * unit, color)

    def background(self):
        s, w, h = self.scale, self.width, self.height
        self.gradient(0, 0, w, h, (20, 25, 42), (10, 15, 25))
        for r in range(220, 10, -12):
            self.circle(w * .83, h * .14, r * s, (111, 80, 170, 2))
        for x in range(0, w, max(1, round(64 * s))):
            self.line(x, 106 * s, x, h - 77 * s, (190, 204, 239, 5))

    def cover(self, game, x, y, width, height, small=False):
        directory = Path(game.directory).parent
        path = directory / 'cover.png'
        texture = None
        if path.is_file() and not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024:
            signature = str(path), path.stat().st_mtime_ns, path.stat().st_size
            if signature not in self.covers:
                try:
                    pw, ph, rgba = read_png(path)
                    data = (c.c_ubyte * len(rgba)).from_buffer(rgba)
                    surface = self.sdl.SDL_CreateRGBSurfaceFrom(data, pw, ph, 32, pw * 4, 0xff, 0xff00, 0xff0000, 0xff000000)
                    created = self.sdl.SDL_CreateTextureFromSurface(self.renderer, surface) if surface else None
                    if surface:
                        self.sdl.SDL_FreeSurface(surface)
                    self.covers[signature] = (created, pw, ph) if created else None
                except (OSError, ValueError, struct.error, zlib.error):
                    self.covers[signature] = None
                if len(self.covers) > 8:
                    old = self.covers.popitem(last=False)[1]
                    if old:
                        self.sdl.SDL_DestroyTexture(old[0])
            self.covers.move_to_end(signature)
            texture = self.covers[signature]
        if texture:
            image, pw, ph = texture
            ratio = max(width / pw, height / ph)
            sw, sh = round(width / ratio), round(height / ratio)
            crop = Rect((pw - sw) // 2, (ph - sh) // 2, sw, sh)
            self.sdl.SDL_RenderCopy(self.renderer, image, c.byref(crop), c.byref(Rect(round(x), round(y), round(width), round(height))))
            return
        seed = hashlib.sha256(game.title.encode()).digest()
        accent = [(121, 179, 176), (161, 143, 203), (213, 158, 122)][seed[0] % 3]
        self.gradient(x, y, width, height, tuple(round(c * .38) for c in accent), (17, 29, 43))
        self.circle(x + width * .64, y + height * .31, width * .25, (*accent, 18))
        self.circle(x + width * .64, y + height * .31, width * .19, (*accent, 44))
        self.circle(x + width * .64, y + height * .31, width * .17, (34, 52, 67))
        for i in range(13):
            px = x + width * (.08 + seed[i + 1] / 255 * .84)
            py = y + height * (.1 + seed[i + 2] / 255 * .45)
            self.box(px, py, max(1, width / 150), max(1, width / 150), (*accent, 130))
        def terrain(points, color):
            self.polygon([(x + a * width, y + b * height) for a, b in points], color)
        terrain([(0, .71), (.24, .44), (.48, .7), (.72, .49), (1, .71), (1, 1), (0, 1)], (36, 66, 77))
        terrain([(0, .86), (.32, .62), (.55, .84), (.84, .64), (1, .84), (1, 1), (0, 1)], (24, 43, 56))
        terrain([(.39, .78), (.47, .3), (.51, .24), (.55, .3), (.62, .78)], (19, 33, 48))
        self.line(x + width * .51, y + height * .28, x + width * .51, y + height * .67, (*accent, 175))
        for i in range(4):
            self.line(x + width * (.44 - i * .012), y + height * (.52 + i * .065),
                      x + width * (.58 + i * .008), y + height * (.52 + i * .065), (*accent, 80))
        self.gradient(x, y + height * .79, width, height * .21, (17, 28, 43, 0), (10, 19, 32, 245))
        if not small:
            s = self.scale
            self.text('W I N D O W S', x + 18 * s, y + 17 * s, 10 * s, INK, width - 36 * s)
            self.text(game.title, x + 18 * s, y + height - 61 * s, 22 * s, INK, width - 36 * s, True)
            self.text('LOCAL COLLECTION', x + 19 * s, y + height - 27 * s, 9 * s, MUTED)

    def header(self, profile, count):
        s, w = self.scale, self.width
        self.box(28 * s, 26 * s, 47 * s, 47 * s, VIOLET, 14 * s)
        self.icon('wine', 38 * s, 36 * s, 27 * s, (26, 24, 44))
        self.text('Jenny Loong', 91 * s, 18 * s, 33 * s, INK, bold=True)
        self.text('Je-Wine  /  游 戏 库', 93 * s, 61 * s, 11 * s, MUTED)
        right = w - 270 * s
        self.text(profile.get('label', 'Windows 游戏库'), right, 29 * s, 16 * s, INK, 240 * s)
        self.circle(right + 4 * s, 65 * s, 3 * s, MINT)
        self.text(f'本地收藏  ·  {count:02d} 款游戏', right + 15 * s, 53 * s, 12 * s, MUTED)
        self.line(28 * s, 98 * s, w - 28 * s, 98 * s, (255, 255, 255, 18))

    def footer(self, label, overlay=False):
        s, w, h = self.scale, self.width, self.height
        self.line(28 * s, h - 70 * s, w - 28 * s, h - 70 * s, (255, 255, 255, 18))
        self.text('← →  切换', 31 * s, h - 44 * s, 13 * s, MUTED)
        actions = [('A', label, MINT), ('B', '返回' if overlay else '退出', INK)]
        if not overlay:
            actions += [('X', '按键', VIOLET), ('Y', '重新扫描', INK)]
        widths = [self.measure(text, 13 * s)[0] + 48 * s for _, text, _ in actions]
        x = w - 28 * s - sum(widths)
        for (key, text, color), width in zip(actions, widths):
            self.circle(x + 11 * s, h - 33 * s, 10 * s, (*color, 28))
            self.text(key, x + 6 * s, h - 44 * s, 13 * s, color, bold=True)
            self.text(text, x + 28 * s, h - 44 * s, 13 * s, INK)
            x += width

    def library(self, profile, base, games, selected, message='', overlay=None):
        s, w, h = self.scale, self.width, self.height
        self.background()
        self.header(profile, len(games))
        self.text('继续你的下一场冒险', 30 * s, 113 * s, 15 * s, MUTED)
        self.text(f'{selected + 1:02d} / {len(games) + 2:02d}', w - 105 * s, 113 * s, 14 * s, MINT)
        panel_y, panel_h = 153 * s, h - 397 * s
        self.box(28 * s, panel_y + 6 * s, w - 56 * s, panel_h, (0, 0, 0, 55), 20 * s)
        self.box(28 * s, panel_y, w - 56 * s, panel_h, (37, 45, 66), 20 * s)
        self.box(29 * s, panel_y + s, w - 58 * s, panel_h - 2 * s, PANEL, 19 * s)
        art_x, art_y, art_w, art_h = 40 * s, panel_y + 12 * s, 242 * s, panel_h - 24 * s
        detail_x, detail_w = 314 * s, w - 374 * s
        if selected < len(games):
            game = games[selected]
            self.cover(game, art_x, art_y, art_w, art_h)
            api = {'d3d9': 'Direct3D 9', 'd3d10': 'Direct3D 10', 'd3d11': 'Direct3D 11', 'd3d12': 'Direct3D 12', 'vulkan': 'Vulkan'}.get(game.graphics_api, 'Windows')
            self.pill(api, detail_x, panel_y + 23 * s)
            self.text(game.title, detail_x, panel_y + 64 * s, 36 * s, INK, detail_w, True)
            state, color = ('等待补齐文件', AMBER) if game.error else ('资源已就绪', MINT)
            self.circle(detail_x + 4 * s, panel_y + 135 * s, 3 * s, color)
            self.text(state, detail_x + 16 * s, panel_y + 123 * s, 14 * s, color)
            description = game.error or '环境将于启动时检查。准备好了，就开始游戏吧。'
            self.wrap(description, detail_x, panel_y + 159 * s, detail_w, 16 * s, MUTED, 2)
            self.text('资源目录', detail_x, panel_y + panel_h - 103 * s, 11 * s, MUTED)
            self.text(str(game.directory), detail_x, panel_y + panel_h - 83 * s, 12 * s, INK, detail_w)
            action = '查看补全说明' if game.error else '启动游戏'
            self.box(detail_x, panel_y + panel_h - 49 * s, 184 * s, 37 * s, color, 10 * s)
            self.icon('box' if game.error else 'play', detail_x + 12 * s, panel_y + panel_h - 42 * s, 22 * s, (21, 32, 38))
            self.text(action, detail_x + 47 * s, panel_y + panel_h - 45 * s, 17 * s, (21, 32, 38), bold=True)
            self.text('手柄键鼠  ·  独立存档', detail_x + 204 * s, panel_y + panel_h - 40 * s, 12 * s, MUTED, detail_w - 204 * s)
        else:
            install = selected == len(games)
            color, icon = (VIOLET, 'box') if install else (MINT, 'refresh')
            self.gradient(art_x, art_y, art_w, art_h, (44, 41, 74), (19, 31, 45))
            for radius in [86, 66, 47]:
                self.circle(art_x + art_w / 2, art_y + art_h * .45, radius * s, (*color, 12))
            self.icon(icon, art_x + art_w / 2 - 37 * s, art_y + art_h * .45 - 37 * s, 74 * s, color)
            self.text('SHARED RUNTIME' if install else 'YOUR COLLECTION', art_x + 28 * s, art_y + art_h - 37 * s, 11 * s, MUTED)
            self.pill('所有游戏共用' if install else 'Windows 游戏库', detail_x, panel_y + 23 * s, color)
            self.text('运行环境' if install else '发现更多游戏', detail_x, panel_y + 68 * s, 36 * s, INK, detail_w, True)
            description = ('安装或补齐 Wine 与图形组件。以后添加游戏，继续共用这份环境。' if install else
                           '将游戏适配包解压到 SD 卡根目录，再把自己的完整游戏文件放进 data 文件夹。')
            self.wrap(description, detail_x, panel_y + 134 * s, detail_w, 17 * s, MUTED, 3)
            state = '环境映像已保存 · 启动时检查组件' if (Path(base) / 'runtime.ext4').is_file() else '首次启动游戏时也会自动安装'
            self.text(state if install else '扫描 Windows 库中的 bottle.json', detail_x, panel_y + panel_h - 89 * s, 13 * s, color, detail_w)
            self.box(detail_x, panel_y + panel_h - 49 * s, 220 * s, 37 * s, color, 10 * s)
            self.text('A   安装 / 补齐环境' if install else 'A   重新扫描游戏', detail_x + 17 * s, panel_y + panel_h - 45 * s, 16 * s, (21, 27, 38), bold=True)
            action = '安装环境' if install else '重新扫描'
        row_y = h - 199 * s
        self.text('我的收藏', 30 * s, row_y - 38 * s, 18 * s, INK, bold=True)
        self.text('游戏与工具', 130 * s, row_y - 33 * s, 11 * s, MUTED)
        total, gap = len(games) + 2, 12 * s
        tile_w = (w - 56 * s - gap * 3) / 4
        first = max(0, min(selected - 1, total - 4))
        for index in range(first, min(first + 4, total)):
            x = 28 * s + (index - first) * (tile_w + gap)
            focused = index == selected
            self.box(x, row_y, tile_w, 99 * s, MINT if focused else (47, 55, 75), 12 * s)
            self.box(x + (2 if focused else 1) * s, row_y + (2 if focused else 1) * s,
                     tile_w - (4 if focused else 2) * s, (95 if focused else 97) * s,
                     (35, 48, 53) if focused else (25, 32, 47), 10 * s)
            if index < len(games):
                item = games[index]
                self.cover(item, x + 10 * s, row_y + 11 * s, 52 * s, 76 * s, True)
                title, subtitle = item.title, '待补文件' if item.error else '资源就绪'
            else:
                install = index == len(games)
                self.box(x + 11 * s, row_y + 17 * s, 49 * s, 62 * s, (46, 45, 71), 10 * s)
                self.icon('box' if install else 'refresh', x + 23 * s, row_y + 35 * s, 25 * s, VIOLET if install else MINT)
                title, subtitle = ('运行环境', '共享安装与补齐') if install else ('重新扫描', '添加你的游戏')
            self.text(title, x + 73 * s, row_y + 24 * s, 16 * s, INK, tile_w - 84 * s, True)
            self.text(subtitle, x + 73 * s, row_y + 55 * s, 11 * s, MINT if focused else MUTED, tile_w - 84 * s)
        if total > 4:
            self.text(f'{first + 1}–{min(first + 4, total)} / {total}', w - 115 * s, row_y - 31 * s, 11 * s, MUTED)
        if message:
            self.text(message, 32 * s, h - 98 * s, 12 * s, AMBER, w - 64 * s)
        else:
            self.text('你的游戏文件留在自己的目录里，运行环境由所有游戏共享。', 32 * s, h - 98 * s, 12 * s, MUTED, w - 64 * s)
        self.footer(action)
        if overlay:
            self.overlay(games[selected] if selected < len(games) else None, overlay)
        self.present()

    def overlay(self, game, kind):
        s, w, h = self.scale, self.width, self.height
        self.box(0, 0, w, h, (5, 8, 16, 220))
        x, y, width, height = 100 * s, (h - 400 * s) / 2, w - 200 * s, 400 * s
        self.box(x, y, width, height, (64, 70, 91), 20 * s)
        self.box(x + s, y + s, width - 2 * s, height - 2 * s, PANEL, 19 * s)
        self.pill('CONTROLS' if kind == 'input' else 'GAME FILES', x + 28 * s, y + 26 * s)
        self.text('按键说明' if kind == 'input' else '游戏尚未就绪', x + 28 * s, y + 72 * s, 30 * s, INK, width - 56 * s, True)
        if kind == 'input':
            self.wrap(game.input_help if game else '摇杆移动鼠标；A 左键，B 右键，X 回车，Y Esc。',
                      x + 30 * s, y + 130 * s, width - 60 * s, 20 * s, INK, 4)
            self.text('Select + Start  请求正常退出游戏', x + 30 * s, y + 279 * s, 17 * s, MINT, width - 60 * s)
        else:
            self.wrap(game.error, x + 30 * s, y + 130 * s, width - 60 * s, 17 * s, AMBER, 3)
            self.text('把自己的完整游戏文件放到：', x + 30 * s, y + 232 * s, 15 * s, MUTED)
            self.wrap(str(game.directory), x + 30 * s, y + 263 * s, width - 60 * s, 16 * s, INK, 2)
        self.line(x + 28 * s, y + 337 * s, x + width - 28 * s, y + 337 * s, (255, 255, 255, 20))
        self.text('A / B   返回游戏库', x + 30 * s, y + 355 * s, 16 * s, MINT)

    def progress(self, title, message, elapsed=0, footer='', game=None, capture=False):
        s, w, h = self.scale, self.width, self.height
        self.background()
        self.text('Jenny Loong  /  Je-Wine', 35 * s, 30 * s, 12 * s, VIOLET)
        x = 44 * s
        if game:
            self.cover(game, x, (h - 352 * s) / 2, 240 * s, 352 * s)
            x = 324 * s
        self.pill('正在准备', x, h * .28, MINT)
        self.text(title, x, h * .28 + 52 * s, 34 * s, INK, w - x - 44 * s, True)
        self.wrap(message, x, h * .28 + 120 * s, w - x - 44 * s, 18 * s, MUTED, 3)
        track_y, track_w = h * .28 + 223 * s, w - x - 50 * s
        self.box(x, track_y, track_w, 4 * s, (43, 52, 70), 2 * s)
        position = (math.sin(elapsed * 1.6 - math.pi / 2) + 1) / 2
        self.box(x + position * max(0, track_w - 65 * s), track_y, 65 * s, 4 * s, MINT, 2 * s)
        self.text(f'已等待 {int(elapsed)} 秒  ·  首次启动会建立游戏环境', x, track_y + 23 * s, 12 * s, MUTED, track_w)
        self.line(32 * s, h - 83 * s, w - 32 * s, h - 83 * s, (255, 255, 255, 18))
        self.text(footer, 35 * s, h - 59 * s, 14 * s, MUTED, w - 70 * s)
        pixels = None
        if capture:
            buffer = c.create_string_buffer(w * h * 4)
            if self.sdl.SDL_RenderReadPixels(self.renderer, None, 0x16362004, buffer, w * 4) != 0:
                raise RuntimeError('无法准备全屏启动画面')
            pixels = buffer.raw
        self.present()
        return pixels
