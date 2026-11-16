#!/usr/bin/env python3
# INPUT: Port manifests, launcher sources, artwork and existing isolated contracts.
# OUTPUT: Read-only audit findings and one replaceable developer report.
# POS: Host maintenance command; never packaged or executed by a game launcher.
import argparse
import collections
import datetime
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
CHECKER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def png_size(path):
    """Check PNG chunk boundaries/CRCs/dimensions, not decoded pixel appearance."""
    raw = path.read_bytes()
    if raw[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('不是完整 PNG（也可能是尚未拉取的 LFS 指针）')
    at, size, ended, pixels = 8, None, False, False
    while at < len(raw):
        if at + 12 > len(raw):
            raise ValueError('PNG 块被截断')
        length = struct.unpack_from('>I', raw, at)[0]
        end = at + 12 + length
        if end > len(raw):
            raise ValueError('PNG 数据被截断')
        kind, data = raw[at + 4:at + 8], raw[at + 8:end - 4]
        if zlib.crc32(kind + data) & 0xffffffff != struct.unpack_from('>I', raw, end - 4)[0]:
            raise ValueError('PNG CRC 不匹配')
        if at == 8:
            if kind != b'IHDR' or length != 13:
                raise ValueError('PNG 缺少 IHDR')
            size = struct.unpack_from('>II', data)
            if not all(size):
                raise ValueError('PNG 尺寸为零')
        if kind == b'IEND':
            if length or end != len(raw):
                raise ValueError('PNG IEND 或文件尾异常')
            ended = True
        if kind == b'IDAT' and length:
            pixels = True
        at = end
    if not ended or not pixels:
        raise ValueError('PNG 缺少 IEND 或 IDAT')
    return size


def audit(root, contracts=False):
    root = root.resolve()
    findings = []

    def add(status, rule, path, detail):
        findings.append(dict(status=status, rule=rule, path=str(path), detail=detail))

    def asset(port, name):
        part = Path(name)
        if part.is_absolute() or '..' in part.parts or not name or '\\' in name:
            raise ValueError('路径必须位于本端口内')
        path = port / part
        if path.resolve() != path.absolute():
            raise ValueError('检查输入不能通过符号链接跳出或替代端口文件')
        return path

    def image(port, name, required, square=False):
        try:
            path = asset(port, name)
            if not path.is_file():
                add('error' if required else 'warning', 'artwork', path.relative_to(root), '缺少声明的图标/封面' if required else '未提供标准封面；需确认发行包与新设备上的图标')
                return
            width, height = png_size(path)
            if square and width != height:
                raise ValueError('TrimUI APP 图标应保留正方形画布，不能拉伸')
            add('pass', 'artwork', path.relative_to(root), f'PNG 块边界/CRC/尺寸检查通过，{width}×{height}；格式解码、像素、角标和留白仍需看图')
        except (OSError, ValueError, TypeError) as error:
            add('error', 'artwork', port.relative_to(root), str(error))

    manifests = sorted((root / 'ports').glob('*/manifest.json'))
    if not manifests:
        add('error', 'manifest', 'ports', '没有找到端口清单')
    names = set()
    for manifest in manifests:
        port = manifest.parent
        try:
            data = json.loads(manifest.read_text())
            if not isinstance(data, dict) or not isinstance(data.get('portmaster', {}), dict):
                raise ValueError('端口清单与 portmaster 必须是对象')
            script, directory = data['script'], data['port_dir']
            if not isinstance(script, str) or Path(script).name != script or not script.endswith('.sh') or any(c in script for c in '\\\0\r\n'):
                raise ValueError('可见入口必须为单个 SH 文件名')
            if not isinstance(directory, str) or not directory or Path(directory).name != directory or directory in ('.', '..') or any(c in directory for c in '\\\0\r\n'):
                raise ValueError('port_dir 必须为单个目录名')
            if script in names:
                raise ValueError('与其它端口重复的可见入口')
            names.add(script)
            if script != 'APP Manager.sh' and not script.startswith('Je-'):
                raise ValueError('可见入口应使用 Je- 前缀；APP Manager 保留原名')
            items = data.get('portmaster', {}).get('items')
            if items is not None and (not isinstance(items, list) or script not in items or directory not in items):
                raise ValueError('portmaster.items 缺少可见入口或数据目录')
            source = data.get('launcher_sh')
            if 'launcher_sh' in data and (not isinstance(source, str) or not source):
                raise ValueError('launcher_sh 已声明时必须是非空路径字符串')
            if source is None:
                source = 'love/launcher.sh.template' if (port / 'love/launcher.sh.template').is_file() else 'src/launcher.sh'
            launcher = asset(port, source)
            text = launcher.read_text()
            syntax = subprocess.run(['/bin/bash', '-n', str(launcher)], capture_output=True, text=True, timeout=10)
            if syntax.returncode:
                raise ValueError(syntax.stderr.strip())
            executable = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
            if re.search(r'(?m)^\s*(?:exec\s+)?python[23]?(?:\s|$)', executable):
                add('warning', 'runtime-python', launcher.relative_to(root), '直接调用系统 Python：核对设备/SDK 依赖声明；不按语言一刀切原生化')
            debug = re.search(r'portkit-debug-launch|guest-exec-view\.py|RUDROID_EXEC_VIEW_ONCE|(?:source|\.)\s+[^\n]*_kit/debug/|--exec-view(?:\s|$)', executable)
            if debug:
                add('error', 'release/debug', launcher.relative_to(root), '正式入口引用调试执行视图或 debug helper：' + debug[0])
            add('pass', 'entry', launcher.relative_to(root), '命名、清单路径与 Bash 语法通过；依赖和开发隔离另列')
            image_info = data.get('portmaster', {}).get('image')
            if image_info is not None and not isinstance(image_info, dict):
                raise ValueError('portmaster.image 必须为对象或 null')
            image_info = image_info or {}
            image(port, image_info.get('screenshot') or 'screenshot.png', bool(image_info.get('screenshot')))
            app = data.get('trimui_app')
            if 'trimui_app' in data and (not isinstance(app, dict) or not app):
                raise ValueError('trimui_app 已声明时必须是非空对象')
            if app is not None:
                image(port, app['icon'], True, square=True)
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            add('error', 'manifest/entry', manifest.relative_to(root), str(error))

    # Check the existing fixed icon provenance/layout rather than inventing
    # a global cover size. Different products intentionally keep their sizes.
    icons = root / '_kit/love/icons'
    if icons.exists():
        try:
            upstream = json.loads((icons / 'upstream.json').read_text())
            for item in upstream['icons']:
                source = asset(icons, item['file'])
                if hashlib.sha256(source.read_bytes()).hexdigest() != item['sha256']:
                    raise ValueError('Fluent 图标来源散列不匹配：' + item['file'])
            layout = (icons / 'layout.lua').read_text()
            width = re.search(r'\bwidth\s*=\s*(\d+)', layout)
            height = re.search(r'\bheight\s*=\s*(\d+)', layout)
            if not width or not height or png_size(icons / 'atlas.png') != (int(width[1]), int(height[1])):
                raise ValueError('图标图集尺寸与 layout.lua 不一致')
            if not (icons / 'LICENSE').is_file():
                raise ValueError('缺少图标许可')
            add('pass', 'shared-icons', '_kit/love/icons', '固定来源散列、图集尺寸和许可通过')
        except (OSError, ValueError, KeyError, TypeError) as error:
            add('error', 'shared-icons', '_kit/love/icons', str(error))
    else:
        add('error', 'shared-icons', '_kit/love/icons', '缺少共享图标目录')

    revision = root / '_kit/portkit_launcher_revision.py'
    if revision.is_file():
        try:
            result = subprocess.run([sys.executable, str(revision), str(root)], capture_output=True, text=True, timeout=30)
            expected = result.stdout.strip()
            binary = root / '_kit/runtime/portkit-launcher.aarch64'
            raw = binary.read_bytes()
            if result.returncode or not re.fullmatch('[0-9a-f]{64}', expected):
                raise ValueError('无法计算 helper 源码身份：' + result.stderr.strip())
            if (root / '_kit/portkit-launcher-revision.txt').read_text().strip() != expected or expected.encode() not in raw:
                raise ValueError('共享 Release helper 与当前源码不匹配，需真实重建')
            if raw[:7] != b'\x7fELF\x02\x01\x01' or struct.unpack_from('<H', raw, 18)[0] != 183:
                raise ValueError('共享 helper 不是 ARM64 ELF')
            if b'portkit-launcher ' not in raw or b'portkit-debug-launch' in raw:
                raise ValueError('共享 helper 是调试产品或缺少正式产品标记')
            add('pass', 'release-identity', '_kit/runtime/portkit-launcher.aarch64', 'ARM64、源码 revision 与正式/调试产品标记检查通过；封装时仍执行完整 Release 门禁')
        except (OSError, ValueError, struct.error, subprocess.TimeoutExpired) as error:
            add('error', 'release-identity', '_kit/runtime/portkit-launcher.aarch64', str(error))
    else:
        add('error', 'release-identity', '_kit/portkit_launcher_revision.py', '缺少既有 Release 身份检查器')

    if contracts:
        try:
            result = subprocess.run([sys.executable, '-m', 'unittest', '-v', 'tests.test_check_ports', 'tests.test_launcher_compat', 'tests.test_launcher_platform'], cwd=root, capture_output=True, text=True, timeout=120)
            detail = (result.stdout + result.stderr).strip()
            add('pass' if not result.returncode and re.search(r'Ran \d+ tests?', detail) else 'error', 'contracts', 'tests', detail[-16000:])
        except (OSError, subprocess.TimeoutExpired) as error:
            add('error', 'contracts', 'tests', str(error))
    else:
        add('not-run', 'contracts', 'tests', '本轮未指定 --contracts；未执行共享隔离回归')
    return dict(root=str(root), checked_at=datetime.datetime.now().astimezone().isoformat(), ports=len(manifests), contracts_requested=contracts, checker_sha256=CHECKER_SHA256,
                counts=dict(collections.Counter(item['status'] for item in findings)), findings=findings,
                manual=['封面角标、圆角、留白与画面内容；APP Manager 的专用图标例外',
                        '共享 UI 的百分比、字号、焦点、保存，以及 4:3/16:9 的实际截图',
                        '显式发行包内的 debug/存档/缓存排除与引擎自身 Release 身份门禁',
                        '真机按键、后端/分辨率实际生效、退出与主页恢复；月检不启动设备'])


def reusable_report(previous, root, month, contracts, markdown):
    """Only a complete paired report covering this requested scope can count."""
    if not isinstance(previous, dict) or not isinstance(previous.get('counts'), dict):
        return False
    if not all(isinstance(n, int) and not isinstance(n, bool) and n >= 0 for n in previous['counts'].values()):
        return False
    stamp = previous.get('checked_at')
    if not isinstance(stamp, str):
        return False
    try:
        datetime.datetime.fromisoformat(stamp)
    except ValueError:
        return False
    return (previous.get('root') == str(root.resolve()) and stamp[:7] == month
            and previous.get('checker_sha256') == CHECKER_SHA256
            and (not contracts or previous.get('contracts_requested') is True)
            and previous.get('markdown_sha256') == hashlib.sha256(markdown).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--report-dir', type=Path, default=ROOT / '.scratch/launcher-checks')
    parser.add_argument('--contracts', action='store_true')
    parser.add_argument('--monthly', action='store_true', help='同一自然月已有报告时跳过，用于登录补检')
    args = parser.parse_args()
    output = args.report_dir.resolve()
    report_file = output / 'latest.json'
    if args.monthly and report_file.is_file():
        try:
            previous = json.loads(report_file.read_text())
            markdown = (output / 'latest.md').read_bytes()
            if reusable_report(previous, args.root, datetime.datetime.now().strftime('%Y-%m'), args.contracts, markdown):
                print('本月已完成检查；报告：' + str(report_file))
                return 1 if previous['counts'].get('error') else 0
        except (OSError, ValueError, KeyError, TypeError):
            pass
    report = audit(args.root, args.contracts)
    output.mkdir(parents=True, exist_ok=True)
    lines = [f"# 启动器检查：{report['checked_at']}", '', f"端口：{report['ports']}；结果：{report['counts']}", '']
    for item in report['findings']:
        if item['status'] != 'pass':
            lines.extend([f"- **{item['status']}** `{item['path']}`：{item['detail']}", ''])
    lines += ['## 仍需人工或真机确认', '', *['- ' + text for text in report['manual']]]
    markdown = ('\n'.join(lines) + '\n').encode()
    report['markdown_sha256'] = hashlib.sha256(markdown).hexdigest()
    # JSON is the completion marker. A crash between the two replacements
    # leaves mismatched content, which the next monthly run cannot reuse.
    temporary = output / 'latest.md.pending'
    temporary.write_bytes(markdown)
    temporary.replace(output / 'latest.md')
    temporary = report_file.with_suffix('.pending')
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(report_file)
    print(f"检查 {report['ports']} 个端口：{report['counts']}；报告：{output / 'latest.md'}")
    return 1 if report['counts'].get('error') else 0


if __name__ == '__main__':
    raise SystemExit(main())
