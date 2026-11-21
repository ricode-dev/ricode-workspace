#!/bin/sh
set -eu

# Python is already included in the image; tomllib avoids fragile manifest greps.
exec python3 - "$@" <<'PY'

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib

SEED = Path('/usr/local/share/zed-extension-seeds/netcoredbg')


def validate(package):
    with (package / 'extension.toml').open('rb') as source:
        manifest = tomllib.load(source)
    if manifest.get('id') != 'netcoredbg' or not manifest.get('version'):
        raise ValueError('invalid NetCoreDbg identity/version')
    adapters = manifest.get('debug_adapters', {})
    if 'netcoredbg' not in adapters:
        raise ValueError('missing debug_adapters.netcoredbg registration')
    # Validate every referenced adapter schema, not just the default filename.
    for adapter in adapters.values():
        schema = (package / adapter['schema_path']).resolve()
        if not schema.is_relative_to(package.resolve()):
            raise ValueError('schema path escapes extension package')
        with schema.open() as source:
            json.load(source)
    with (package / 'extension.wasm').open('rb') as source:
        # wasm32-wasip2 produces a WebAssembly component, not a core module.
        if source.read(8) != b'\x00asm\x0d\x00\x01\x00' or not source.read(1):
            raise ValueError('missing/invalid WebAssembly component')
    return manifest['version']


def main():
    if sys.argv[1:] == ['--check-seed']:
        version = validate(SEED)
        if version != '1.0.0':
            raise ValueError(f'unexpected bundled version: {version}')
        print(f'Validated NetCoreDbg seed {version}', file=sys.stderr)
        return
    if len(sys.argv) > 2:
        raise ValueError('usage: install-zed-netcoredbg-extension [remote_extensions_directory]')
    data_home = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share')
    extensions = Path(sys.argv[1]) if len(sys.argv) == 2 else data_home / 'zed/remote_extensions'
    destination = extensions / 'netcoredbg'
    if os.path.lexists(destination):
        version = validate(destination)
        print(f'Keeping existing NetCoreDbg {version} at {destination}', file=sys.stderr)
        return

    version = validate(SEED)
    subprocess.run(['sha256sum', '--check', '--strict', 'SHA256SUMS'], cwd=SEED, check=True)
    extensions.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.netcoredbg.', dir=extensions))
    try:
        shutil.copytree(SEED, staging, dirs_exist_ok=True)
        staging.chmod(0o755)
        validate(staging)
        # GNU mv's no-clobber publication never replaces a concurrent installation.
        # Staging is on the same filesystem; call only before the remote server starts.
        subprocess.run(['mv', '--no-clobber', '--no-target-directory', str(staging), str(destination)], check=True)
        if staging.exists():
            validate(destination)
            print(f'Keeping concurrently installed NetCoreDbg at {destination}', file=sys.stderr)
        else:
            print(f'Installed bundled NetCoreDbg {version} at {destination}', file=sys.stderr)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


try:
    main()
except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
    print(f'NetCoreDbg extension initialization failed: {error}. '
          'Existing files were not replaced; repair/reinstall the package before starting remote Zed.', file=sys.stderr)
    sys.exit(1)
PY
