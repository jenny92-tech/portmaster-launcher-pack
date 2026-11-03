#!/usr/bin/env python3
# INPUT:  主机 SDL2/SDL2_ttf、显式字体和仅在内存中的游戏夹具
# OUTPUT: 实际原生界面的多尺寸 PNG 与预览记录，不启动 Wine 或游戏
# POS:    用离屏 SDL 渲染检查掌机游戏库，复用发行界面的布局和绘制
import argparse
import ctypes as c
import json
import os
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from launcher import Game, Menu, read_bottle


def write_png(path, width, height, bgra):
    pixels = bytearray(bgra)
    pixels[0::4], pixels[2::4] = pixels[2::4], pixels[0::4]
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    rows = b''.join(b'\x00' + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def render(font, output):
    os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
    os.environ.setdefault('SDL_RENDER_DRIVER', 'software')
    output.mkdir(parents=True, exist_ok=True)
    game = read_bottle(ROOT / 'adapters/sunken-dragon')
    game.directory = Path('/mnt/sdcard/roms/windows/sunken-dragon/data')
    base = output / 'empty-state'
    files = []
    for width, height in [(960, 720), (640, 480), (1280, 720)]:
        profile = {'label': '迷你龙 · LoongOS' if width == 960 else '界面尺寸预览',
                   'display_size': [width, height], 'font': str(font), 'controller_database': ''}
        menu = Menu(profile, fullscreen=False)
        scene = 'library'
        def capture():
            pixels = c.create_string_buffer(menu.width * menu.height * 4)
            if menu.sdl.SDL_RenderReadPixels(menu.renderer, None, 0x16362004, pixels, menu.width * 4) != 0:
                raise RuntimeError('SDL screenshot failed')
            name = f'{scene}-{width}x{height}.png'
            write_png(output / name, menu.width, menu.height, pixels.raw)
            files.append(name)
        menu.view.present = capture
        try:
            menu.view.library(profile, base, [game], 0)
            if width == 960:
                for scene, selected, overlay in [('environment', 1, None), ('resources', 0, 'resources'), ('controls', 0, 'input')]:
                    menu.view.library(profile, base, [game], selected, overlay=overlay)
                scene = 'loading'
                menu.view.progress(game.title, '正在检查公共运行环境', 7, 'B  取消启动，等待当前准备步骤完成', game, capture=True)
                scene = 'empty'
                menu.view.library(profile, base, [], 0)
                scene = 'many-games'
                fixtures = [Game(f'预览游戏 {index + 1:02d} · 一段很长的中文标题', Path(f'/fixture/{index}/data'),
                                 graphics_api='d3d11') for index in range(8)]
                menu.view.library(profile, base, fixtures, 6)
                art = output / 'fixture-art'
                art.mkdir(exist_ok=True)
                sample = b''.join(bytes((70 + y // 4, 100 + y // 3, 180, 255)) * 240 for y in range(320))
                write_png(art / 'cover.png', 240, 320, sample)
                scene = 'custom-cover'
                menu.view.library(profile, base, [Game('本地封面预览', art / 'data', graphics_api='d3d11')], 0)
                if not any(menu.view.covers.values()):
                    raise RuntimeError('PNG cover did not reach the native SDL texture')
        finally:
            menu.close()
    (output / 'preview.json').write_text(json.dumps({'renderer': 'actual SDL2 software renderer', 'files': files,
                                                  'fixtures_only': True, 'device_connected': False}, ensure_ascii=False, indent=2))
    print(json.dumps({'preview_directory': str(output), 'frames': len(files)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--font', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    render(args.font.resolve(), args.output)
