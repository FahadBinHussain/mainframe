"""Development VSS source checks: synthetic only, never execute Windows or COM."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import wacli_snapshot

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'wacli-vss-client'


class VssClientDevelopmentTests(unittest.TestCase):
    def test_fake_backend_transaction(self):
        """Build and run only the platform-neutral synthetic backend tests."""
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ unavailable; synthetic C++ tests not run')
        with tempfile.TemporaryDirectory(prefix='wacli-vss-synthetic-') as directory:
            output = Path(directory) / 'fake-tests'
            subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-pedantic', '-I', str(MODULE / 'include'),
                            str(MODULE / 'src/orchestrator.cpp'),
                            str(MODULE / 'tests/fake_tests.cpp'), '-o', str(output)],
                           check=True, capture_output=True, timeout=60)
            subprocess.run([str(output)], check=True, capture_output=True, timeout=30)

    def test_native_adapter_cross_compiles_only(self):
        """Check Windows API declarations without running a Windows executable."""
        compiler = shutil.which('x86_64-w64-mingw32-g++')
        if compiler is None:
            self.skipTest('MinGW unavailable; Windows cross-compilation not run')
        with tempfile.TemporaryDirectory(prefix='wacli-vss-cross-') as directory:
            subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-I', str(MODULE / 'include'),
                            str(MODULE / 'src/orchestrator.cpp'),
                            str(MODULE / 'src/native_vss_backend.cpp'),
                            str(MODULE / 'tests/link_only.cpp'),
                            '-lole32', '-lvssapi', '-luuid', '-o',
                            str(Path(directory) / 'link-only.exe')],
                           check=True, capture_output=True, timeout=60)

    def test_public_capture_remains_blocked(self):
        """The experimental library does not authorize capture or Windows claims."""
        result = wacli_snapshot.capture('/synthetic/nonexistent/source',
                                        '/synthetic/nonexistent/destination')
        self.assertEqual(result['status'], 'blocked')
        for field in ('capture_enabled', 'complete', 'publishable',
                      'windows_validated', 'source_read', 'producer_execution'):
            self.assertIs(result[field], False, field)


if __name__ == '__main__':
    unittest.main()
