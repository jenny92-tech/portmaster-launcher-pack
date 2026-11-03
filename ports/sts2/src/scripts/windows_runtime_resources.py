# INPUT: audited Windows export configuration/resources and project-owned stubs
# OUTPUT: minimal ARM64 startup configuration overrides with byte identities
# POS: applied before Godot startup through the merged private main PCK
import hashlib
import re
import struct

SENTRY = b'res://addons/sentry/sentry.gdextension\n'

def rewrite_project(data):
    if data[:4] != b'ECFG' or len(data) < 8:
        raise ValueError('Unrecognized project.binary')
    count, = struct.unpack_from('<I', data, 4)
    pos = 8
    records = []
    removed = 0
    for _ in range(count):
        start = pos
        if pos + 4 > len(data): raise ValueError('Truncated project.binary')
        n, = struct.unpack_from('<I', data, pos); pos += 4
        if pos + n + 4 > len(data): raise ValueError('Truncated project name')
        name = data[pos:pos+n]; pos += n
        size, = struct.unpack_from('<I', data, pos); pos += 4
        if pos + size > len(data): raise ValueError('Truncated project value')
        value = data[pos:pos+size]; pos += size
        if name == b'autoload/SentryBootstrap':
            if b'*res://addons/sentry/SentryBootstrap.cs' not in value: raise ValueError('Unexpected Sentry autoload')
            removed += 1
        else:
            records.append(data[start:pos])
    if pos != len(data) or removed != 1:
        raise ValueError('Unexpected project records or Sentry autoload count')
    return data[:4] + struct.pack('<I', count-1) + b''.join(records)

def rewrite_fmod(data):
    marker = b'\n[icons]\n'
    if data.count(marker) != 1 or b'linux.release.arm64' in data:
        raise ValueError('Unexpected FMOD configuration')
    lines = b''.join(b'linux.'+mode+b'.arm64 = "res://addons/fmod/libs/linux/libGodotFmod.linux.'+suffix+b'.arm64.so"\n' for mode, suffix in ((b'editor',b'editor'),(b'debug',b'template_debug'),(b'release',b'template_release')))
    data = data.replace(marker, b'\n'+lines+marker, 1)
    # Preserve the original dependency list and reuse its release ABI names.
    dependency = re.search(rb'(?m)^linux\.release\.x86_64\s*=\s*\{[^}]*\}', data)
    if not dependency:
        raise ValueError('Missing FMOD Linux release dependencies')
    copied = dependency.group().replace(b'linux.release.x86_64', b'linux.release.arm64', 1)
    return data[:dependency.end()] + b'\n' + copied + data[dependency.end():]

def rewrite_spine(data):
    for mode,suffix in ((b'editor',b'editor'),(b'debug',b'template_debug'),(b'release',b'template_release')):
        before = b'linux.'+mode+b'.arm64 = "linux/libspine_godot.linux.'+suffix+b'.arm64.so"'
        after = before.replace(b'"linux/', b'"res://addons/spine/linux/')
        if data.count(before) != 1: raise ValueError('Unexpected Spine ARM64 mapping')
        data = data.replace(before, after, 1)
    return data

def build(source_pck, reader, index):
    paths = ['project.binary', '.godot/extension_list.cfg', 'addons/fmod/fmod.gdextension',
        'addons/spine/spine_godot_extension.gdextension']
    with source_pck.open('rb') as f:
        original = {p:reader.entry_bytes(f, index[p]) for p in paths}
    extensions = original[paths[1]]
    if extensions.count(SENTRY) != 1:
        raise ValueError('Unexpected Sentry extension list')
    changed = {
        paths[0]: (rewrite_project(original[paths[0]]), 'remove unavailable native Sentry autoload'),
        paths[1]: (extensions.replace(SENTRY,b'',1), 'remove unavailable native Sentry extension; retain FMOD and Spine'),
        paths[2]: (rewrite_fmod(original[paths[2]]), 'add Linux ARM64 FMOD library and release dependency mappings; retain original platforms and dependencies'),
        paths[3]: (rewrite_spine(original[paths[3]]), 'resolve Linux ARM64 Spine libraries from runtime res:// paths'),
    }
    result = {}
    records = []
    for path,(output, reason) in changed.items():
        result['res://'+path] = output
        records.append({'path':'res://'+path,'source_sha256':hashlib.sha256(original[path]).hexdigest(),
            'output_sha256':hashlib.sha256(output).hexdigest(),'reason':reason})
    return result, records
