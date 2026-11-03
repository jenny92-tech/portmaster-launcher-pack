#!/usr/bin/env python3
# INPUT:  Heaptrack 1.3 interpreted version-3 event stream and optional sample time
# OUTPUT: Aggregate allocation counts and byte totals by attributed module
# POS:    Offline first-non-runtime-frame summary without reading object contents
import argparse
import json
import os
import sys


IGNORED_PREFIXES = (
    'libheaptrack', 'libc.so', 'libstdc++.so', 'libgcc_s.so', 'libunwind',
    'libpthread.so', 'libdl.so', 'libm.so', 'liblzma.so', 'ld-linux-',
    'linux-vdso',
)


def parse_hex(value):
    if not value or any(c not in b'0123456789abcdefABCDEF' for c in value):
        raise ValueError('invalid non-negative hex value')
    return int(value, 16)


def parse_fields(raw, count):
    values = [parse_hex(part) for part in raw.split()[1:]]
    if len(values) != count:
        raise ValueError(f'expected {count} numeric fields')
    return values


def summarize(path, at_ms):
    strings = [None]
    ips = [None]
    traces = [None]
    allocations = []
    live_counts = []
    groups = {}
    version = None
    timestamp_markers = 0
    elapsed_ms = 0
    reached = at_ms is None
    total_live = total_peak = total_allocated = total_count = 0
    last_snapshot = {}

    def group_for_trace(trace_id):
        seen = set()
        while trace_id:
            if trace_id in seen or trace_id >= len(traces):
                raise ValueError('invalid trace chain')
            seen.add(trace_id)
            ip_id, trace_id = traces[trace_id]
            if not 0 < ip_id < len(ips):
                raise ValueError('invalid instruction pointer index')
            module_id = ips[ip_id]
            if module_id >= len(strings):
                raise ValueError('invalid module string index')
            module = strings[module_id] if module_id else None
            if module and not os.path.basename(module).startswith(IGNORED_PREFIXES):
                return module
        return '<unknown-or-runtime-only>'

    with open(path, 'rb') as stream:
        for line_number, raw in enumerate(stream, 1):
            if not raw.endswith(b'\n') and not raw.startswith(b'#'):
                raise ValueError(f'line {line_number}: unterminated record')
            raw = raw.rstrip(b'\r\n')
            if not raw or raw.startswith(b'#'):
                continue
            record = chr(raw[0])
            try:
                if record == 'v':
                    heaptrack_version, version = parse_fields(raw, 2)
                    if heaptrack_version != 0x010300:
                        raise ValueError('expected heaptrack 1.3.0')
                    if version != 3:
                        raise ValueError('expected interpreted heaptrack format 3')
                elif version is None:
                    raise ValueError('missing version header')
                elif record == 's':
                    _, length, data = raw.split(b' ', 2)
                    if len(data) != parse_hex(length):
                        raise ValueError('invalid sized string')
                    strings.append(data.decode('utf-8', 'surrogateescape'))
                elif record == 'i':
                    parts = raw.split()
                    fields = [parse_hex(part) for part in parts[1:]]
                    ips.append(fields[1])
                elif record == 't':
                    traces.append(tuple(parse_fields(raw, 2)))
                elif record == 'a':
                    size, trace = parse_fields(raw, 2)
                    allocations.append((size, group_for_trace(trace)))
                    live_counts.append(0)
                elif record in '+-':
                    index, = parse_fields(raw, 1)
                    if index >= len(allocations):
                        raise ValueError('invalid allocation index')
                    size, module = allocations[index]
                    group = groups.setdefault(module, {'live_bytes': 0, 'peak_live_bytes': 0,
                                                        'allocated_bytes': 0, 'allocations': 0})
                    if record == '+':
                        live_counts[index] += 1
                        total_live += size
                        total_allocated += size
                        total_count += 1
                        group['live_bytes'] += size
                        group['allocated_bytes'] += size
                        group['allocations'] += 1
                        group['peak_live_bytes'] = max(group['peak_live_bytes'], group['live_bytes'])
                        if total_live > total_peak:
                            total_peak = total_live
                            last_snapshot = {k: v['live_bytes'] for k, v in groups.items()}
                    else:
                        if live_counts[index] <= 0:
                            raise ValueError('free without matching allocation')
                        live_counts[index] -= 1
                        total_live -= size
                        group['live_bytes'] -= size
                elif record == 'c':
                    elapsed_ms, = parse_fields(raw, 1)
                    timestamp_markers += 1
                    if at_ms is not None and elapsed_ms >= at_ms:
                        reached = True
                        break
                elif record == 'A':
                    raise ValueError('attached-process traces are not supported')
                elif record in ('I', 'R'):
                    parse_fields(raw, 2 if record == 'I' else 1)
                elif record in ('X', 'S'):
                    continue
                else:
                    raise ValueError('unknown record type')
            except (ValueError, IndexError) as exc:
                raise ValueError(f'line {line_number}: {exc}') from exc
    if version is None:
        raise ValueError('empty trace')
    if not reached:
        raise ValueError(f'no timestamp reached {at_ms} ms; last was {elapsed_ms} ms')
    return {'sample_marker_ms': elapsed_ms, 'requested_ms': at_ms, 'timestamp_markers': timestamp_markers,
            'total': {'live_bytes': total_live, 'peak_live_bytes': total_peak,
                      'allocated_bytes': total_allocated, 'allocations': total_count},
            'modules': {k: dict(v, live_bytes_at_total_peak=last_snapshot.get(k, 0))
                        for k, v in sorted(groups.items(), key=lambda item: -item[1]['allocated_bytes'])}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('interpreted_trace')
    parser.add_argument('--at-ms', type=int, default=None, help='first timestamp marker at or after this time')
    args = parser.parse_args()
    if args.at_ms is not None and args.at_ms < 0:
        parser.error('--at-ms must be non-negative')
    try:
        print(json.dumps(summarize(args.interpreted_trace, args.at_ms), ensure_ascii=True, indent=2))
    except (OSError, ValueError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
