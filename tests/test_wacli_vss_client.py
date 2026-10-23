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
            for fixture in ('fake_tests', 'copy_tests'):
                with self.subTest(fixture=fixture):
                    output = Path(directory) / fixture
                    subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                                    '-pedantic', '-I', str(MODULE / 'include'),
                                    str(MODULE / 'src/orchestrator.cpp'),
                                    str(MODULE / f'tests/{fixture}.cpp'), '-o', str(output)],
                                   check=True, capture_output=True, timeout=60)
                    subprocess.run([str(output)], check=True, capture_output=True, timeout=30)

    def test_actual_native_adapters_with_fake_windows_apis(self):
        """Execute production adapter code against in-memory Win32/VSS API doubles."""
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ unavailable; native API-double tests not run')
        cases = {
            'native_copy_tests': ['native_snapshot_copy.cpp'],
            'native_backend_tests': ['native_vss_backend.cpp', 'orchestrator.cpp'],
        }
        with tempfile.TemporaryDirectory(prefix='wacli-vss-fake-win32-') as directory:
            for fixture, sources in cases.items():
                with self.subTest(fixture=fixture):
                    output = Path(directory) / fixture
                    subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                                    '-D_WIN32', '-I', str(MODULE / 'tests/win32_fake'),
                                    '-I', str(MODULE / 'include'),
                                    *(str(MODULE / 'src' / source) for source in sources),
                                    str(MODULE / f'tests/{fixture}.cpp'), '-o', str(output)],
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
                            str(MODULE / 'src/native_snapshot_copy.cpp'),
                            str(MODULE / 'tests/link_only.cpp'),
                            '-lole32', '-lvssapi', '-luuid', '-ladvapi32', '-o',
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
