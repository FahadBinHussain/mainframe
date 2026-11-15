"""Payload-free WACLI restore requirements, not a migration or account validator.

The Windows manifest/helper records neither producing store versions nor a
consistent SQLite snapshot. Filenames and the target install pin cannot supply
that missing evidence. Never open a database or a config to build this report.
"""
from __future__ import annotations

WINDOWS_PREFIX = 'AppData/Roaming/mainframe/accounts/whatsapp/'


def restoration_status(preservation='not-observed'):
    """Report only what this operation can establish; never infer usable parity."""
    return {
        'installation_status': 'not-performed-by-this-operation',
        'runtime_status': 'not-tested',
        'data_preservation_status': preservation,
        'windows_migration_status': 'blocked',
        'activation_status': 'not-performed',
        'usability_status': 'unverified',
        'complete': False,
        'target': {
            'wacli': 'v0.15.0',
            'source_commit': 'a020de724180d31eccfa5241d45443402d62fb06',
            'wacli_schema_migrations': 24,
            'whatsmeow': 'v0.0.0-20260718134955-fac667d55293',
            'whatsmeow_schema_version': 14,
            'whatsmeow_version_table': 'whatsmeow_version',
            'sqlite_driver': 'github.com/mattn/go-sqlite3 v1.14.48',
        },
        'blockers': [
            {'code': 'source-provenance-unrecorded',
             'requires': 'Source WACLI build/version and whatsmeow dependency provenance; the target Go install pin does not identify backed-up stores.'},
            {'code': 'source-schemas-unverified',
             'requires': 'Compatible complete wacli.db schema/schema_migrations history (target 1-24) and separate whatsmeow session.db SQL-store schema (target whatsmeow_version 14); filenames and version numbers alone cannot validate session keys or account usability.'},
            {'code': 'consistent-snapshot-unproven',
             'requires': 'A stopped, complete store capture protocol, or a coordinated SQLite backup-API snapshot of both databases and media; WAL/journal state must never be omitted. A backup API cannot repair an already torn archive.'},
            {'code': 'paths-and-profile-selection-unconverted',
             'requires': 'Explicit mapping of Windows profile/current.txt to valid named accounts, external store/config paths, messages.local_path and message_local_media_aliases.local_path; preserve original metadata and every unconverted item.'},
            {'code': 'activation-and-usability-not-validated',
             'requires': 'Separately authorized normal installation and explicit non-overwriting restore activation after offline validation; verify local data/media/search and linked-device usability without concurrent source use. No activation is authorized here.'},
        ],
        'documentation': 'docs/linux-wacli-windows-parity.md',
    }
