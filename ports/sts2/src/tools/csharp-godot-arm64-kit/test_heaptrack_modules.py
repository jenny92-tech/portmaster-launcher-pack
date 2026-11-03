#!/usr/bin/env python3
# INPUT:  heaptrack_modules and synthetic heaptrack 1.3 interpreted records
# OUTPUT: Unit checks for module attribution, timing, allocation and free
# POS:    Validate offline heaptrack event accounting without game data
import tempfile
import unittest
from pathlib import Path

from heaptrack_modules import summarize


TRACE = b'''v 10300 3
s 9 libc.so.6
s 7 liba.so
s 7 libb.so
i 1 1
t 1 0
i 2 2
t 2 0
t 1 2
a 10 3
+ 0
c 1
i 3 3
t 3 0
a 20 4
+ 1
- 0
a 8 1
+ 2
c 2
- 1
- 2
c 3
'''


class SummaryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'trace.txt'
        self.path.write_bytes(TRACE)

    def tearDown(self):
        self.tmp.cleanup()

    def test_live_peak_cumulative_and_unknown(self):
        result = summarize(self.path, None)
        modules = result['modules']
        self.assertEqual(result['total'], {'live_bytes': 0, 'peak_live_bytes': 48,
                                          'allocated_bytes': 56, 'allocations': 3})
        self.assertEqual(modules['liba.so']['peak_live_bytes'], 16)
        self.assertEqual(modules['libb.so']['peak_live_bytes'], 32)
        self.assertEqual(modules['<unknown-or-runtime-only>']['peak_live_bytes'], 8)
        self.assertEqual(sum(v['peak_live_bytes'] for v in modules.values()), 56)
        self.assertEqual(sum(v['live_bytes_at_total_peak'] for v in modules.values()), 48)
        self.assertEqual(sum(v['live_bytes'] for v in modules.values()), 0)

    def test_sample_is_first_marker_at_or_after_request(self):
        first = summarize(self.path, 1)
        self.assertEqual(first['sample_marker_ms'], 1)
        self.assertEqual(first['total']['live_bytes'], 16)
        second = summarize(self.path, 2)
        self.assertEqual(second['sample_marker_ms'], 2)
        self.assertEqual(second['total']['live_bytes'], 40)
        self.assertEqual(second['modules']['liba.so']['live_bytes'], 0)
        self.assertEqual(second['modules']['libb.so']['live_bytes'], 32)
        with self.assertRaisesRegex(ValueError, 'no timestamp reached'):
            summarize(self.path, 4)

    def test_rejects_attached_or_unbalanced_records(self):
        self.path.write_bytes(TRACE + b'A\n')
        with self.assertRaisesRegex(ValueError, 'attached-process'):
            summarize(self.path, None)
        self.path.write_bytes(TRACE + b'- 0\n')
        with self.assertRaisesRegex(ValueError, 'free without matching'):
            summarize(self.path, None)

    def test_rejects_unterminated_record_but_not_unread_suffix(self):
        self.path.write_bytes(TRACE + b'+ 1')
        last_line = len(TRACE.splitlines()) + 1
        with self.assertRaisesRegex(ValueError, f'line {last_line}: unterminated record'):
            summarize(self.path, None)
        self.assertEqual(summarize(self.path, 1)['total']['live_bytes'], 16)
        self.path.write_bytes(TRACE + b'# trailing comment')
        self.assertEqual(summarize(self.path, None)['total']['live_bytes'], 0)

    def test_rejects_negative_hex_in_all_consumed_fields(self):
        cases = (b't -1 0\n', b't 1 -1\n', b'i 1 -1\n', b'i -1 1\n',
                 b'i 1 1 -1\n', b'a -1 1\n',
                 b'a 1 -1\n', b'c -1\n', b'+ -1\n', b'- -1\n',
                 b's -1 x\n', b'v -1 3\n', b'v 10300 -1\n',
                 b'R -1\n', b'I 1000 -1\n')
        for record in cases:
            with self.subTest(record=record):
                self.path.write_bytes(TRACE + record)
                with self.assertRaisesRegex(ValueError, 'invalid non-negative hex'):
                    summarize(self.path, None)


if __name__ == '__main__':
    unittest.main()
