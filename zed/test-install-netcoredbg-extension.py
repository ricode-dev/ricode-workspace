#!/usr/bin/env python3
"""Focused regression tests for the installer's embedded Python.

Fixtures contain a synthetic Wasm component header plus arbitrary bytes. They
exercise only the installer's header check, NOT real Wasm/Zed compatibility.
Requires Python 3.11+, sha256sum, and GNU mv, as does the installer.
Run: python3 zed/test-install-netcoredbg-extension.py -v
"""

import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).with_name('install-netcoredbg-extension.sh')
SEED_LITERAL = "SEED = Path('/usr/local/share/zed-extension-seeds/netcoredbg')"
# Deliberately synthetic: not an executable or validated WebAssembly component.
SYNTHETIC_WASM = b'\x00asm\x0d\x00\x01\x00synthetic-test-fixture'


def write_package(package, version='1.0.0'):
    package.mkdir(parents=True)
    (package / 'extension.toml').write_text(
        'id = "netcoredbg"\n'
        f'version = "{version}"\n'
        '[debug_adapters.netcoredbg]\n'
        'schema_path = "debug_adapter_schemas/launch.json"\n',
        encoding='utf-8',
    )
    schemas = package / 'debug_adapter_schemas'
    schemas.mkdir()
    (schemas / 'launch.json').write_text('{"type": "object"}\n', encoding='utf-8')
    (package / 'extension.wasm').write_bytes(SYNTHETIC_WASM)
    write_checksums(package)


def write_checksums(package):
    lines = []
    for path in sorted(package.rglob('*')):
        if path.is_file() and path.name != 'SHA256SUMS':
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            lines.append(f'{digest}  {path.relative_to(package).as_posix()}\n')
    (package / 'SHA256SUMS').write_text(''.join(lines), encoding='utf-8')


def snapshot(root):
    """Capture contents and metadata, excluding read-induced access times."""
    result = {}
    for path in [root, *sorted(root.rglob('*'))]:
        info = path.lstat()
        result[str(path.relative_to(root))] = (
            stat.S_IMODE(info.st_mode),
            info.st_ino,
            info.st_mtime_ns,
            info.st_ctime_ns,
            path.read_bytes() if path.is_file() else None,
        )
    return result


class InstallNetcoredbgTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Extract the actual helper payload, not a separately maintained copy.
        shell = HELPER.read_text(encoding='utf-8')
        prefix, separator, remainder = shell.partition("<<'PY'\n")
        if not separator or 'exec python3 - "$@"' not in prefix:
            raise AssertionError('installer Python heredoc format changed')
        cls.payload, separator, suffix = remainder.rpartition('\nPY')
        if not separator or suffix.strip():
            raise AssertionError('installer Python heredoc terminator changed')
        if cls.payload.count(SEED_LITERAL) != 1:
            raise AssertionError('installer fixed SEED assignment changed')

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='test-netcoredbg-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.seed = self.root / 'seed'
        self.extensions = self.root / 'explicit-extensions'
        self.destination = self.extensions / 'netcoredbg'
        self.home = self.root / 'home'
        self.home.mkdir()
        write_package(self.seed)
        self.code = self.payload.replace(SEED_LITERAL, f'SEED = Path({str(self.seed)!r})')

    def run_installer(self, destination=None, env=None):
        environment = os.environ.copy()
        environment.pop('XDG_DATA_HOME', None)
        environment['HOME'] = str(self.home)
        environment.update(env or {})
        command = [sys.executable, '-']
        if destination is not None:
            command.append(str(destination))
        return subprocess.run(
            command,
            input=self.code,
            text=True,
            capture_output=True,
            env=environment,
            cwd=self.root,
            timeout=10,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_rejected_without_changes(self, expected_error):
        before = snapshot(self.root)
        result = self.run_installer(self.extensions)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('NetCoreDbg extension initialization failed:', result.stderr)
        self.assertIn(expected_error, result.stderr)
        self.assertIn('Existing files were not replaced', result.stderr)
        self.assertEqual(snapshot(self.root), before)

    def test_absent_install_copies_complete_seed(self):
        self.assertFalse(self.extensions.exists())
        seed_before = snapshot(self.seed)
        result = self.run_installer(self.extensions)
        self.assert_success(result)
        self.assertIn('Installed bundled NetCoreDbg 1.0.0', result.stderr)
        self.assertEqual(
            {p.relative_to(self.seed): p.read_bytes()
             for p in self.seed.rglob('*') if p.is_file()},
            {p.relative_to(self.destination): p.read_bytes()
             for p in self.destination.rglob('*') if p.is_file()},
        )
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o755)
        self.assertEqual(list(self.extensions.iterdir()), [self.destination])
        self.assertEqual(snapshot(self.seed), seed_before)

    def test_second_run_is_idempotent(self):
        self.assert_success(self.run_installer(self.extensions))
        before = snapshot(self.root)
        result = self.run_installer(self.extensions)
        self.assert_success(result)
        self.assertIn('Keeping existing NetCoreDbg 1.0.0', result.stderr)
        self.assertEqual(snapshot(self.root), before)

    def test_preserves_newer_valid_install_even_with_broken_seed(self):
        write_package(self.destination, version='9.0.0')
        (self.destination / 'user-file').write_text('keep me', encoding='utf-8')
        (self.seed / 'extension.wasm').unlink()
        before = snapshot(self.root)
        result = self.run_installer(self.extensions)
        self.assert_success(result)
        self.assertIn('Keeping existing NetCoreDbg 9.0.0', result.stderr)
        self.assertEqual(snapshot(self.root), before)

    def test_incomplete_target_is_not_repaired_or_replaced(self):
        self.destination.mkdir(parents=True)
        (self.destination / 'user-file').write_text('keep me', encoding='utf-8')
        self.assert_rejected_without_changes('extension.toml')

    def test_invalid_packages_are_rejected_without_modification(self):
        cases = (
            ('manifest syntax', 'extension.toml', b'not valid toml', 'Expected'),
            ('manifest identity', 'extension.toml',
             b'id = "another-extension"\nversion = "1.0.0"\n', 'identity/version'),
            ('manifest version', 'extension.toml', b'id = "netcoredbg"\n',
             'identity/version'),
            ('adapter registration', 'extension.toml',
             b'id = "netcoredbg"\nversion = "1.0.0"\n'
             b'[debug_adapters.other]\nschema_path = "debug_adapter_schemas/launch.json"\n',
             'missing debug_adapters.netcoredbg'),
            ('adapter schema path', 'extension.toml',
             b'id = "netcoredbg"\nversion = "1.0.0"\n'
             b'[debug_adapters.netcoredbg]\nschema_path = "../outside.json"\n',
             'schema path escapes extension package'),
            ('invalid schema JSON', 'debug_adapter_schemas/launch.json',
             b'{broken json', 'Expecting property name'),
            ('missing schema', 'debug_adapter_schemas/launch.json', None,
             'launch.json'),
            ('invalid wasm magic', 'extension.wasm', b'not wasm',
             'missing/invalid WebAssembly component'),
            ('core wasm instead of component', 'extension.wasm',
             b'\x00asm\x01\x00\x00\x00payload', 'missing/invalid WebAssembly component'),
            ('header without payload', 'extension.wasm', SYNTHETIC_WASM[:8],
             'missing/invalid WebAssembly component'),
        )
        for location in ('seed', 'existing'):
            for name, filename, content, error in cases:
                with self.subTest(location=location, invalid=name):
                    # Isolate each case, including existing-target validation.
                    with tempfile.TemporaryDirectory(dir=self.root) as case_dir:
                        original = self.seed, self.extensions, self.destination, self.code
                        try:
                            case_root = Path(case_dir)
                            self.seed = case_root / 'seed'
                            self.extensions = case_root / 'extensions'
                            self.destination = self.extensions / 'netcoredbg'
                            write_package(self.seed)
                            package = self.seed
                            if location == 'existing':
                                write_package(self.destination)
                                package = self.destination
                            path = package / filename
                            if content is None:
                                path.unlink()
                            else:
                                path.write_bytes(content)
                            # Keep checksums valid to isolate structural validation.
                            write_checksums(package)
                            self.code = self.payload.replace(
                                SEED_LITERAL, f'SEED = Path({str(self.seed)!r})')
                            self.assert_rejected_without_changes(error)
                        finally:
                            (self.seed, self.extensions,
                             self.destination, self.code) = original

    def test_xdg_data_home_controls_default_destination(self):
        data_home = self.root / 'custom-data'
        result = self.run_installer(env={'XDG_DATA_HOME': str(data_home)})
        self.assert_success(result)
        self.assertTrue((data_home / 'zed/remote_extensions/netcoredbg/extension.wasm').is_file())
        self.assertFalse((self.home / '.local').exists())

    def test_default_destination_without_xdg_data_home(self):
        self.assert_success(self.run_installer())
        self.assertTrue((self.home / '.local/share/zed/remote_extensions/netcoredbg/extension.wasm').is_file())

    def test_explicit_destination_overrides_xdg_data_home(self):
        data_home = self.root / 'unused-data'
        self.assert_success(self.run_installer(self.extensions, {'XDG_DATA_HOME': str(data_home)}))
        self.assertTrue(self.destination.is_dir())
        self.assertFalse(data_home.exists())

    def test_checksum_tampering_blocks_install(self):
        # Still valid JSON: only integrity verification should reject this seed.
        (self.seed / 'debug_adapter_schemas/launch.json').write_text(
            '{"type": "string"}\n', encoding='utf-8')
        self.assert_rejected_without_changes('sha256sum')
        self.assertFalse(self.extensions.exists())


if __name__ == '__main__':
    unittest.main()
