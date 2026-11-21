# ricode-workspace

Debian Trixie-based workspace container with .NET SDK 8 and 10 installed via
Microsoft's `dotnet-install.sh`, NVM (Node 16, 22,
and 24), Python, Rust, Git/GitHub CLI, Docker CLI, CodeGraph, NetCoreDbg, and SSH tools.

NetCoreDbg is cloned from the official [Samsung/netcoredbg](https://github.com/Samsung/netcoredbg)
repository and compiled during the image build (default release: `3.2.0-1092`).
The debugger and its companion libraries are installed in `/usr/local/share/netcoredbg`,
with `netcoredbg` also available on `PATH`. The local `netcoredbg/` directory is
not used and is excluded from the build context.

The image copies `zed/settings.json` to `/root/.config/zed/settings.json` so Zed
can use the debugger installed in the container. Install the
[NetCoreDbg extension](https://github.com/qwadrox/zed-netcoredbg) in Zed to register
the adapter, and configure launch/attach tasks in your application's `.zed/debug.json`.
The image does not depend on the extension downloading the debugger.

### Remote Zed debugger extension

The debugger binary and the Zed extension are separate requirements. To avoid
`Failed to find a debug adapter` when Zed leaves its uploaded extension uninstalled,
the image also builds and bundles the **NetCoreDbg extension 1.0.0**, pinned to
commit `d8a8aa6c90faf155f983a44cc739b1cad34f4492` of
[qwadrox/zed-netcoredbg](https://github.com/qwadrox/zed-netcoredbg). Cargo uses the
upstream lockfile, Rust **1.93.1**, and the `wasm32-wasip2` target. The source archive is
fetched from `https://codeload.github.com/qwadrox/zed-netcoredbg/tar.gz/d8a8aa6c90faf155f983a44cc739b1cad34f4492`
and checked against SHA-256
`24bcc7f6f64641259c2040f8c2ea5712cd480bbb180c66f62b5dcf404e4697cf`.
The bundle includes the manifest, WASM component, debug adapter schemas, and
upstream MIT license. `BUILD-INFO` records provenance; `SHA256SUMS` records the
checksums of the built package (including WASM), checked before runtime seeding.

The immutable seed is stored at `/usr/local/share/zed-extension-seeds/netcoredbg`.
At build time the helper also installs it into root's default remote extension
directory, so it is present even if a launcher bypasses the entrypoint, provided
no mount hides it. Before SSH starts, the entrypoint seeds the complete package into
`${XDG_DATA_HOME:-$HOME/.local/share}/zed/remote_extensions/netcoredbg`
(`/root/.local/share/zed/remote_extensions/netcoredbg` by default). This runs after
volume mounts are available, including when Zed's data directory is a volume.
Existing valid extension directories are **never overwritten or merged**, including
newer versions. The helper parses TOML, checks adapter registration and every
referenced schema, and checks the WASM component header. Invalid existing packages
cause a clear error and stop startup without modifying them; repair/reinstall those
explicitly rather than mixing package versions. New packages are staged on the
target filesystem and published with no-clobber semantics. No session-specific
`uploads` directory is used, and startup requires no download. Static validation
does not prove host compatibility or that breakpoints work.

Keep NetCoreDbg installed in **host Zed** as well: bundling remote files does not
replace host adapter registration or fix Zed's internal synchronization mechanism.
The bundle uses Zed extension API **0.7.0**. Verify compatibility with your Zed
version on a fresh container; a source build alone cannot verify remote loading.
To change the pinned source, update both `ZED_NETCOREDBG_REV` and
`ZED_NETCOREDBG_SOURCE_SHA256`, and review the manifest/API version, expected
seed version in the helper, toolchain, and package layout too.

If using another remote user, provision that user's settings and permissions, then
run `install-zed-netcoredbg-extension` as that user (or pass its remote extensions
directory explicitly). The rest of this image's SSH setup still targets root.
This repository has no `.devcontainer/devcontainer.json`; the external configuration,
actual mounts, and Zed dev-container lifecycle could not be inspected. Do not assume
`overrideCommand: true` preserves this entrypoint. If it is bypassed **and** a mount
on `/root`, the Zed data directory, or `remote_extensions` hides the build-time copy,
the launcher must invoke `install-zed-netcoredbg-extension` after mounts are ready
and before starting remote Zed. A post-connect hook is too late. For that setup,
verify the actual pre-server lifecycle first; this image alone does not guarantee it.
For SSH, the existing entrypoint invokes the helper synchronously before `sshd`.
The default user is root; a different user/XDG location must match the actual remote
server data directory, not merely the caller's environment.

After rebuilding and **recreating** the container:

1. Check `dotnet --info` for SDK 10 and `netcoredbg --version` for a working binary.
2. Check that the remote extension directory contains `extension.toml`,
   `extension.wasm`, and `debug_adapter_schemas/netcoredbg.json`.
3. Connect/reconnect Zed and check its remote logs in
   `/root/.local/share/zed/logs/` for extension loading errors.
4. Start your application's HTTP debug profile and verify a breakpoint. HTTPS
   additionally requires the ASP.NET Core development certificate in the container.

If a missing-manifest error returns, inspect the extension directory and remote
logs before changing the debugger binary. Update Zed/reinstall the host extension
if synchronization still fails. Reconnect after repairing any remote package.

### Validation status and acceptance procedure

Local validation for this change:

- Real upstream extension source compiled successfully with Rust 1.93.1,
  `cargo build --locked --release --target wasm32-wasip2` (not merely a fixture).
- `python3 zed/test-install-netcoredbg-extension.py -v`: 9 tests passed, covering
  seeding, idempotency, preservation of newer packages, invalid/incomplete packages,
  checksum tampering, and destination selection. Test WASM fixtures are synthetic;
  these tests do not validate Zed compatibility.
- `sh -n docker-entrypoint.sh zed/install-netcoredbg-extension.sh` passed.
- Available host CLI: Zed `1.29.3`, commit
  `d01b134cddf5e4f71964deb2d6f81cdb38fcf1e7`; not tested against the extension in UI.
- Full image build was not run: `podman info` is blocked by sandbox write access to
  `/run/user/1000/libpod`. No tested image tag/digest or remote server version exists
  for this change yet. First connection, breakpoint, restart, and recreate remain
  **unverified**. The binary build/version was not rerun; the Dockerfile keeps
  `NETCOREDBG_VERSION=3.2.0-1092` unchanged.

On a machine with a working container engine, build a unique test tag, for example:

```sh
podman build -t localhost/ricode-workspace:netcoredbg-seed-test-20261121 .
podman image inspect localhost/ricode-workspace:netcoredbg-seed-test-20261121
```

Record the image ID/digest actually used by a new test container. Check SDK 10,
`/usr/local/bin/netcoredbg --version`, the active extension files and `SHA256SUMS`
before connecting. Repeat with an empty disposable Zed data volume and actual
launcher mounts, without deleting user volumes. Run the helper twice and confirm
that the second run preserves the installation. Record host and remote Zed versions.
Connect Zed, inspect logs from the new startup, recheck the package after sync, and
run the application's HTTP profile with an endpoint breakpoint twice. Then repeat
after reconnect, container restart, and recreation using the same image. Do not
accept a recovery that requires copying from `uploads`. This bundling mitigates
missing remote installation; it does not establish the cause of Zed's sync failure
or repair unrelated missing extensions.

Building requires network access to GitHub, NuGet, Rust distribution servers,
and crates.io for upstream dependencies.
To select a different release, pass `--build-arg NETCOREDBG_VERSION=<release-tag>`
to `docker build`.

Run the SSH-enabled workspace (the `authorized_keys` mount is required):

```sh
docker run --rm -d \
  -p 2222:22 \
  -v "$(pwd):/workspace" \
  -v "$HOME/.ssh/authorized_keys:/root/.ssh/authorized_keys:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e GH_TOKEN \
  -e GITHUB_TOKEN \
  azka2606/ricode-workspace:latest
```

Connect with `ssh -p 2222 root@localhost`. The entrypoint copies the mounted
key to a container-owned, permission-safe location before starting SSH, so the
same command also works with Docker Desktop file mounts. To open an interactive
shell while retaining SSH access, append `bash` to the `docker run` command.
On its first start, the container writes every exported environment variable
to root's `.bashrc`, so values passed with `docker run -e` (including
`GH_TOKEN` and `GITHUB_TOKEN`) remain available in SSH shells. The values are
kept for that container's lifetime; recreate the container to capture changed
environment values.

The image includes Tini as PID 1 to forward stop signals to the command's
process group and reap orphaned processes. This lets the default `sleep infinity`
command respond to SIGTERM when stopping the container with Docker or Podman.

The Docker CLI uses the host daemon through the `/var/run/docker.sock` bind
mount. This grants root-equivalent control of that Docker host; omit that mount
when the workspace must not create or manage host containers.

The GitHub workflow publishes `latest` and a semantic-version tag. It reads
`DOCKER_PAT` from repository secrets. `RELEASE_TYPE` accepts `Major`, `Minor`,
or `Patch` (default) and is selected when manually running the workflow.
RiCode Workspace
