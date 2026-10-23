"""Synthetic producer capability tests; no WACLI binary/account is discovered."""
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import wacli_snapshot as snapshot
import wacli_snapshot_protocol as protocol


def blocked_plan():
    return {
        'protocol': protocol.PROTOCOL,
        'status': 'blocked',
        'capture_enabled': False,
        'complete': False,
        'publishable': False,
        'boundary': 'UNVERIFIED',
        'cross_database_consistency': 'NOT_CERTIFIED',
        'windows_validated': False,
    }


class ProducerProtocolTests(unittest.TestCase):
    def encode(self, value):
        return json.dumps(value).encode('utf-8')

    def test_recognized_plan_does_not_authorize_or_verify_anything(self):
        with patch('builtins.open', side_effect=AssertionError('filesystem I/O')), \
                patch.object(Path, 'stat', side_effect=AssertionError('source stat')), \
                patch('subprocess.run', side_effect=AssertionError('producer execution')):
            result = protocol.inspect_producer(self.encode(blocked_plan()))
        self.assertEqual(result['producer_assessment'], 'recognized-blocked-plan-only')
        for key in ('capture_enabled', 'publishable', 'complete', 'source_read',
                    'windows_validated', 'snapshot_consumed', 'producer_verified'):
            self.assertIs(result[key], False)
        self.assertEqual(snapshot.capture(object(), object()), snapshot.capture_status())
        self.assertEqual(snapshot.capture_status()['producer_protocol'], protocol.PROTOCOL)
        self.assertIs(snapshot.capture_status()['producer_execution'], False)

    def test_each_required_field_missing_or_claimed_success_is_rejected(self):
        for key in blocked_plan():
            with self.subTest(key=key, case='missing'):
                value = blocked_plan(); del value[key]
                with self.assertRaises(protocol.ProducerProtocolError):
                    protocol.inspect_producer(self.encode(value))
            for replacement in (True, None, [], {}, 0, 1, 'complete'):
                value = blocked_plan(); value[key] = replacement
                with self.subTest(key=key, replacement=replacement):
                    with self.assertRaises(protocol.ProducerProtocolError):
                        protocol.inspect_producer(self.encode(value))

    def test_malformed_duplicate_nonfinite_and_nested_payloads_are_fixed_errors(self):
        cases = [b'', b'[]', b'null', b'"private synthetic value"', b'{', b'\xff',
                 b'\xef\xbb\xbf' + self.encode(blocked_plan()),
                 self.encode(blocked_plan()) + b'\x00',
                 b'{"protocol":"x","protocol":"y"}',
                 b'{"optional":{"x":0,"x":1}}',
                 b'{"optional":NaN}', b'{"optional":Infinity}',
                 b'{"optional":-Infinity}',
                 b'[' * 2000 + b'0' + b']' * 2000,
                 self.encode(blocked_plan()) + b' {}',
                 b' ' * (protocol.MAX_CAPABILITY_BYTES + 1)]
        for raw in cases:
            with self.subTest(raw_length=len(raw)):
                with self.assertRaises(protocol.ProducerProtocolError) as error:
                    protocol.inspect_producer(raw)
                self.assertNotIn('private synthetic value', str(error.exception))
                self.assertLess(len(str(error.exception)), 100)

    def test_exact_bytes_and_size_limit(self):
        for raw in (None, {}, 'not bytes', bytearray(b'{}')):
            with self.assertRaises(protocol.ProducerProtocolError):
                protocol.inspect_producer(raw)
        raw = self.encode(blocked_plan())
        padded = raw + b' ' * (protocol.MAX_CAPABILITY_BYTES - len(raw))
        self.assertEqual(protocol.inspect_producer(padded)['status'], 'blocked')
        with self.assertRaises(protocol.ProducerProtocolError):
            protocol.inspect_producer(padded + b' ')

    def test_optional_fields_are_not_trusted_or_reflected(self):
        value = blocked_plan()
        value.update({'private_path': '/synthetic/private',
                      'receipt': {'boundary': 'VERIFIED', 'publishable': True},
                      'backend': 'approved', 'artifact_sha256': '0' * 64})
        result = protocol.inspect_producer(self.encode(value))
        rendered = json.dumps(result)
        for private in ('/synthetic/private', 'artifact_sha256', 'VERIFIED'):
            self.assertNotIn(private, rendered)
        self.assertFalse(result['capture_enabled'])

    def test_plain_object_only_not_generic_cli_success_wrapper(self):
        with self.assertRaises(protocol.ProducerProtocolError):
            protocol.inspect_producer(self.encode({'success': True, 'data': blocked_plan()}))

    def invoke(self, raw):
        return subprocess.run([sys.executable, str(Path(snapshot.__file__)), 'check-producer'],
                              input=raw, capture_output=True, timeout=10)

    def test_cli_recognizes_plan_but_exits_blocked(self):
        proc = self.invoke(self.encode(blocked_plan()))
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), protocol.inspect_producer(self.encode(blocked_plan())))
        self.assertEqual(proc.stderr, b'')

    def test_cli_errors_are_fixed_and_non_sensitive(self):
        for raw in (b'/synthetic/private-secret', b'x' * (protocol.MAX_CAPABILITY_BYTES + 1)):
            proc = self.invoke(raw)
            self.assertEqual(proc.returncode, 2, proc.stderr)
            report = json.loads(proc.stdout)
            self.assertEqual(report['status'], 'blocked')
            self.assertFalse(report['capture_enabled'])
            self.assertFalse(report['snapshot_consumed'])
            self.assertNotIn(b'private-secret', proc.stdout + proc.stderr)

    def test_cli_input_read_failure_does_not_echo_private_os_error(self):
        output = io.StringIO()
        with patch.object(sys, 'stdin') as source, contextlib.redirect_stdout(output):
            source.buffer.read.side_effect = OSError('/synthetic/private-secret')
            self.assertEqual(snapshot.main(['check-producer']), 2)
            source.buffer.read.assert_called_once_with(protocol.MAX_CAPABILITY_BYTES + 1)
        report = json.loads(output.getvalue())
        self.assertEqual(report['error'], 'WACLI producer capability input unavailable.')
        self.assertNotIn('private-secret', output.getvalue())


if __name__ == '__main__':
    unittest.main()
