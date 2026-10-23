#!/usr/bin/env python3
"""Untrusted WACLI capability bytes are information, never capture authority.

This module performs no filesystem, executable, account or database discovery.
It deliberately has no receipt importer or success/capture-enabling branch.
"""
from __future__ import annotations

import json

PROTOCOL = 'wacli-coordinated-snapshot-v1'
MAX_CAPABILITY_BYTES = 16 * 1024
_REQUIRED = {
    'protocol': PROTOCOL,
    'status': 'blocked',
    'capture_enabled': False,
    'complete': False,
    'publishable': False,
    'boundary': 'UNVERIFIED',
    'cross_database_consistency': 'NOT_CERTIFIED',
    'windows_validated': False,
}


class ProducerProtocolError(ValueError):
    """A fixed, non-sensitive error for invalid/unrecognized producer bytes."""


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProducerProtocolError('Invalid WACLI producer capability report.')
        result[key] = value
    return result


def _invalid_constant(value):
    raise ProducerProtocolError('Invalid WACLI producer capability report.')


def inspect_producer(raw):
    """Recognize a blocked plan only; never certify snapshots or enable capture.

    The bytes must come from a separately reviewed producer. A matching JSON
    document is not build provenance, writer-fence evidence or trusted input.
    Unknown optional fields are ignored, not copied into diagnostics or trusted.
    All required field types are exact (e.g. numeric zero is not JSON false).
    """
    if type(raw) is not bytes or not 0 < len(raw) <= MAX_CAPABILITY_BYTES:
        raise ProducerProtocolError('Invalid WACLI producer capability report.')
    try:
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=_object,
                           parse_constant=_invalid_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise ProducerProtocolError('Invalid WACLI producer capability report.') from None
    if type(value) is not dict:
        raise ProducerProtocolError('Invalid WACLI producer capability report.')
    if value.get('protocol') != PROTOCOL:
        raise ProducerProtocolError('Unsupported WACLI snapshot producer protocol.')
    for key, expected in _REQUIRED.items():
        actual = value.get(key)
        if type(actual) is not type(expected) or actual != expected:
            raise ProducerProtocolError('Unsupported WACLI producer capability claim.')
    return {
        'protocol': PROTOCOL,
        'producer_assessment': 'recognized-blocked-plan-only',
        'status': 'blocked',
        'capture_enabled': False,
        'complete': False,
        'publishable': False,
        'source_read': False,
        'windows_validated': False,
        'snapshot_consumed': False,
        'producer_verified': False,
        'activation': 'not-performed',
        'blockers': ['verified-all-writer-boundary-backend-unavailable',
                     'producer-capability-report-is-not-capture-evidence'],
    }
