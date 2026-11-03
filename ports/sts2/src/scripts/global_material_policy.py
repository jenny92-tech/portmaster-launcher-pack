# INPUT:  Godot text scene/resource/shader bytes and the handheld-low policy
# OUTPUT: narrowly transformed visual material/shader bytes and an audit record
# POS:    type/feature-based rules, independent of scene paths and node names
import hashlib
import re
from decimal import Decimal

HEADER = re.compile(rb'^\[(gd_resource|sub_resource|resource|node|ext_resource)\b([^\]]*)\]')
TYPE = re.compile(rb'\btype="([^"\r\n]+)"')
ID = re.compile(rb'\bid="([^"\r\n]+)"')
FIELD = re.compile(rb'(?m)^([ \t]*turbulence_enabled[ \t]*=[ \t]*)([^\r\n]*)(\r?\n|$)')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def shader_syntax(code):
    """Mask comments and strings without changing byte offsets."""
    result = bytearray(code); i = 0; mode = None
    while i < len(code):
        ch = code[i]
        if mode is None:
            if code[i:i+2] == b'//': mode='line'; result[i:i+2]=b'  '; i+=2; continue
            if code[i:i+2] == b'/*': mode='block'; result[i:i+2]=b'  '; i+=2; continue
            if ch == 34: mode='string'; result[i]=32
        elif mode == 'line':
            if ch in (10,13): mode=None
            else: result[i]=32
        elif mode == 'block':
            if code[i:i+2] == b'*/': result[i:i+2]=b'  '; mode=None; i+=2; continue
            if ch not in (10,13): result[i]=32
        else:
            if ch == 92 and i+1 < len(code):
                result[i]=32
                if code[i+1] not in (10,13): result[i+1]=32
                i+=2; continue
            if ch == 34: mode=None
            if ch not in (10,13): result[i]=32
        i+=1
    if mode in ('block','string'): raise ValueError('unterminated shader comment or string')
    return bytes(result)


def resource_syntax(data):
    """Mask quoted resource values while retaining offsets and line breaks."""
    result = bytearray(data); quoted = False; escaped = False
    for i, ch in enumerate(data):
        if quoted:
            if ch not in (10,13): result[i] = 32
            if escaped: escaped = False
            elif ch == 92: escaped = True
            elif ch == 34: quoted = False
        elif ch == 34:
            quoted = True; result[i] = 32
    if quoted: raise ValueError('unterminated quoted resource field')
    return bytes(result)


def sections(data):
    """Locate serialized sections outside quoted, possibly multiline values."""
    result = []
    quoted = False
    offset = 0
    for line in data.splitlines(keepends=True):
        if not quoted:
            match = HEADER.match(line)
            if match:
                result.append((offset, match.group(1), match.group(2)))
        escaped = False
        for ch in line:
            if escaped:
                escaped = False
            elif ch == 92 and quoted:
                escaped = True
            elif ch == 34:
                quoted = not quoted
        offset += len(line)
    if quoted: raise ValueError('unterminated quoted resource field')
    return result


def shader_noise(code):
    """Cap only a structurally recognized canvas-item fractal-noise loop."""
    if not re.search(rb'(?m)^\s*shader_type\s+canvas_item\s*;', code): return code, []
    if re.search(rb'\b(?:discard|vertex|light)\s*\(', code) or b'#include' in code: return code, []
    # Narrow function body grammar: accumulation of a noise call, frequency
    # multiplication and amplitude decay. No arbitrary loop body is changed.
    pat = re.compile(rb'(?s)(float\s+\w+\s*\(\s*vec2\s+(?P<p>\w+)\s*\)\s*\{\s*float\s+(?P<acc>\w+)\s*=\s*0(?:\.0+)?\s*;\s*float\s+(?P<amp>\w+)\s*=\s*0\.5\s*;\s*for\s*\(\s*int\s+(?P<i>\w+)\s*=\s*0\s*;\s*(?P=i)\s*<\s*)(?P<count>[4-9]|[1-9][0-9]+)(\s*;\s*(?P=i)\+\+\s*\)\s*\{\s*(?P=acc)\s*\+=\s*(?P=amp)\s*\*\s*\w*noise\w*\s*\(\s*(?P=p)\s*\)\s*;\s*(?P=p)\s*\*=\s*[0-9.]+\s*;\s*(?P=amp)\s*\*=\s*0\.5\s*;\s*\}\s*return\s+(?P=acc)\s*;\s*\})', re.I)
    found = list(pat.finditer(shader_syntax(code)))
    changes = []
    for match in reversed(found):
        before = int(match.group('count'))
        start, end = match.span('count')
        code = code[:start] + b'2' + code[end:]
        changes.append({'rule':'canvas_fractal_noise_octaves', 'before':before, 'after':2,
                        'reason':'cap structurally identified visual noise octaves while preserving shader interface'})
    return code, list(reversed(changes))


def shader_gaussian(code):
    """Replace an entirely recognized symmetric weighted canvas blur sum."""
    if not re.search(rb'(?m)^\s*shader_type\s+canvas_item\s*;', code): return code, []
    if re.search(rb'\bdiscard\b', shader_syntax(code)) or b'#include' in code: return code, []
    assign = re.compile(rb'\bCOLOR\.rgb\s*=\s*(?P<expr>[^;]+);', re.S)
    term = re.compile(rb'\s*(?P<w>\d+\.\d+)\s*\*\s*texture\s*\(\s*TEXTURE\s*,\s*UV\s*(?P<sign>[+-])\s*(?P<offset>\d+\.\d+)\s*\*\s*(?P<scale>[A-Za-z_]\w*)\s*\)\s*\.rgb\s*')
    screen_term = re.compile(rb'\s*(?P<w>\d+\.\d+)\s*\*\s*sample\s*\(\s*SCREEN_UV\s*(?P<sign>[+-])\s*(?P<offset>\d+\.\d+)\s*\*\s*(?P<scale>[A-Za-z_]\w*)\s*\)\s*\.rgb\s*')
    changes = []
    for assignment in reversed(list(assign.finditer(shader_syntax(code)))):
        expr = assignment.group('expr'); parts = expr.split(b'+\n')
        # Godot's exported Gaussian uses a trailing '+' between tap lines.
        if len(parts) < 12: continue
        taps = [term.fullmatch(p) for p in parts]; screen = False
        if any(x is None for x in taps):
            taps = [screen_term.fullmatch(p) for p in parts]; screen = True
            if not re.search(rb'\bvec4\s+sample\s*\(\s*vec2\s+\w+\s*\)', shader_syntax(code)):
                continue
        if any(x is None for x in taps): continue
        if len({x.group('scale') for x in taps}) != 1: continue
        values = [(Decimal(x.group('w').decode()), Decimal(x.group('offset').decode()) * (-1 if x.group('sign') == b'-' else 1)) for x in taps]
        if any(w <= 0 for w, _ in values): continue
        total = sum(w for w, _ in values)
        if not Decimal('0.95') <= total <= Decimal('1.05'): continue
        if any(a[1] >= b[1] for a, b in zip(values, values[1:])): continue
        if values[0][1] >= 0 or values[-1][1] <= 0: continue
        groups = [values[i*len(values)//7:(i+1)*len(values)//7] for i in range(7)]
        terms = []
        for group in groups:
            weight = sum(w for w, _ in group)
            offset = sum(w*x for w, x in group) / weight
            sign = '+' if offset >= 0 else '-'
            offset_text = f'{sign} {abs(offset):.9f} * {taps[0].group("scale").decode()}'
            sample = f'sample(SCREEN_UV {offset_text})' if screen else f'texture(TEXTURE, UV {offset_text})'
            terms.append(f'{weight:.9f} * {sample}.rgb')
        out = ('\n        ' + ' +\n        '.join(terms)).encode()
        start,end = assignment.span('expr'); code=code[:start]+out+code[end:]
        changes.append({'rule':'canvas_weighted_blur_taps','before':len(taps),'after':7,
                        'reason':'coalesce recognized normalized weighted blur samples while preserving total weight and centroid'})
    return code, list(reversed(changes))


def shader_screen_warp(code):
    """Disable a structurally recognized noise-only screen UV displacement."""
    clean = shader_syntax(code)
    if not re.search(rb'(?m)^\s*shader_type\s+canvas_item\s*;', clean) or b'#include' in code:
        return code, []
    if re.search(rb'\bdiscard\b', clean): return code, []
    pattern = re.compile(rb'(?s)void\s+fragment\s*\(\s*\)\s*\{\s*vec2\s+(?P<uv>\w+)\s*=\s*SCREEN_UV\s*;\s*vec4\s+(?P<sample>\w+)\s*=\s*texture\s*\(\s*(?P<screen>\w+)\s*,\s*(?P=uv)\s*\)\s*;\s*vec2\s+\w+\s*=\s*[^;{}]+;\s*float\s+(?P<noise>\w+)\s*=\s*texture\s*\(\s*\w+\s*,\s*[^;{}]+\)\s*\.r\s*-\s*0\.5\s*;\s*(?P=uv)\s*\+=\s*(?P=noise)\s*\*\s*SCREEN_PIXEL_SIZE\s*\*\s*\w+\s*;\s*COLOR\s*=\s*texture\s*\(\s*(?P=screen)\s*,\s*(?P=uv)\s*\)\s*;\s*\}')
    found = list(pattern.finditer(clean)); changes=[]
    for match in reversed(found):
        sampler = re.escape(match.group('screen'))
        if not re.search(rb'\buniform\s+sampler2D\s+'+sampler+rb'\s*:\s*hint_screen_texture\b', clean): continue
        replacement = b'void fragment() {\n\tCOLOR = texture('+match.group('screen')+b', SCREEN_UV);\n}'
        code=code[:match.start()]+replacement+code[match.end():]
        changes.append({'rule':'canvas_noise_screen_warp_disabled','before':'noise-displaced screen sample',
                        'after':'original screen sample', 'reason':'remove noise sampling and screen UV displacement; retain screen sampler interface'})
    return code, list(reversed(changes))


def shader_uv_distortion(code):
    """Disable a recognized distortion sample used only in UV calculations."""
    clean = shader_syntax(code)
    if not re.search(rb'(?m)^\s*shader_type\s+canvas_item\s*;', clean) or re.search(rb'\bdiscard\b', clean): return code, []
    pattern = re.compile(rb'(?is)float\s+(?P<v>\w*distort\w*)\s*=\s*texture\s*\(\s*\w*distort\w*\s*,\s*[^;{}]+\)\s*\.r\s*;\s*(?P=v)\s*=\s*\(\s*(?P=v)\s*-\s*0\.5\s*\)\s*\*\s*2\.0\s*;\s*(?P=v)\s*\*=\s*\w*distort\w*\s*;')
    changes=[]
    for match in reversed(list(pattern.finditer(clean))):
        variable = match.group('v')
        before, after = clean[:match.start()], clean[match.end():]
        refs = [line for line in after.splitlines() if re.search(rb'\b'+re.escape(variable)+rb'\b', line)]
        if re.search(rb'\b'+re.escape(variable)+rb'\b', before) or not refs or any(b'uv' not in line.lower() or b'vec2' not in line for line in refs):
            continue
        code=code[:match.start()]+b'float '+variable+b' = 0.0;'+code[match.end():]
        changes.append({'rule':'canvas_noise_uv_distortion_disabled','before':'noise-sampled UV distortion',
                        'after':'zero UV distortion','reason':'remove recognized distortion sampling while retaining shader interface and alpha calculation code; sampled values may change'})
    return code, list(reversed(changes))


def transform_shader(code):
    # Serialized Shader.code may contain Godot string escapes. Rewriting those
    # requires a lossless escape-aware round trip; leave them for manual audit.
    if b'\\' in code: return code, []
    out, a = shader_noise(code)
    out, b = shader_gaussian(out)
    out, c = shader_screen_warp(out)
    out, d = shader_uv_distortion(out)
    return out, a+b+c+d


def quoted_shader_range(chunk):
    match = re.search(rb'(?m)^[ \t]*code[ \t]*=[ \t]*"', chunk)
    if not match: return None
    start = match.end(); escaped = False
    for i in range(start, len(chunk)):
        ch=chunk[i]
        if escaped: escaped=False
        elif ch==92: escaped=True
        elif ch==34: return start,i
    raise ValueError('unterminated shader code')


def transform_resource(path, data):
    if path.endswith('.gdshader'):
        result, changes = transform_shader(data)
        for change in changes:
            change['output_code_sha256'] = sha(result.replace(b'\r\n', b'\n').replace(b'\r', b'\n'))
        return result, changes
    spans=sections(data)
    if not spans: raise ValueError('unrecognized Godot text resource')
    root_type=None; changes=[]; result=bytearray(); pos=0
    for i,(start,kind,attrs) in enumerate(spans):
        end=spans[i+1][0] if i+1<len(spans) else len(data)
        result.extend(data[pos:start]); chunk=data[start:end]; pos=end
        t=TYPE.search(attrs); rid=ID.search(attrs)
        typ=t.group(1).decode() if t else None
        if kind==b'gd_resource': root_type=typ
        if kind==b'resource': typ=root_type
        name=rid.group(1).decode() if rid else ('root' if kind==b'resource' else None)
        if typ=='ParticleProcessMaterial':
            matches=list(FIELD.finditer(resource_syntax(chunk)))
            if len(matches)>1: raise ValueError('duplicate turbulence field in '+path)
            if matches:
                val=matches[0].group(2).strip()
                if val not in (b'true',b'false'): raise ValueError('unknown turbulence value in '+path)
                if val==b'true':
                    match=matches[0]; a,b=match.span(2)
                    chunk=chunk[:a]+match.group(2).replace(b'true', b'false', 1)+chunk[b:]
                    changes.append({'rule':'particle_turbulence_disabled','material_id':name,
                                    'field':'turbulence_enabled','before':True,'after':False,
                                    'reason':'disable expensive particle turbulence while preserving node, shader interface and timing'})
        if typ=='Shader':
            location=quoted_shader_range(chunk)
            if location:
                a,b=location; new, found=transform_shader(chunk[a:b])
                if found:
                    chunk=chunk[:a]+new+chunk[b:]
                    for change in found:
                        changes.append({'shader_id':name, 'output_code_sha256':sha(new.replace(b'\r\n',b'\n').replace(b'\r',b'\n')), **change})
        result.extend(chunk)
    result.extend(data[pos:])
    return bytes(result), changes
