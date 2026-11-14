# ricode-workspace

Debian Trixie-based workspace container with .NET SDK 8 and 10 installed via
Microsoft's `dotnet-install.sh`, NVM (Node 16, 22,
and 24), Python, Rust, Git/GitHub CLI, Docker CLI, CodeGraph, and SSH tools.

Build locally:

```sh
docker build -t azka2606/ricode-workspace:latest .
```

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

The Docker CLI uses the host daemon through the `/var/run/docker.sock` bind
mount. This grants root-equivalent control of that Docker host; omit that mount
when the workspace must not create or manage host containers.

The GitHub workflow publishes `latest` and a semantic-version tag. It reads
`DOCKER_PAT` from repository secrets. `RELEASE_TYPE` accepts `Major`, `Minor`,
or `Patch` (default) and is selected when manually running the workflow.
RiCode Workspace
