#!/bin/sh
set -eu

AUTHORIZED_KEYS=/root/.ssh/authorized_keys
ENVIRONMENT_INITIALIZED=/root/.ricode-workspace-environment-initialized

persist_initial_environment() {
    # SSH starts a new shell, so it cannot inherit the environment passed to
    # Docker at container creation time. Persist all exported variables once
    # for subsequent interactive shells in this container.
    if [ -e "$ENVIRONMENT_INITIALIZED" ]; then
        return
    fi

    umask 077
    {
        printf '\n# Environment captured when this container was first started.\n'
        # Bash's %q produces source-safe values, including values containing
        # spaces, quotes, or newlines. compgen -e lists exported variables only.
        bash -c 'for name in $(compgen -e); do printf "export %s=%q\\n" "$name" "${!name}"; done'
    } >> /root/.bashrc
    : > "$ENVIRONMENT_INITIALIZED"
}

mkdir -p /run/sshd /root/.ssh
chmod 0700 /root/.ssh

persist_initial_environment

if [ ! -s "$AUTHORIZED_KEYS" ]; then
    echo "Missing SSH authorized_keys. Mount it at $AUTHORIZED_KEYS." >&2
    exit 1
fi

# Copy the bind-mounted key to a container-owned file. This preserves SSH's
# strict permission checks even when Docker Desktop exposes host files as 0777.
install -m 0600 "$AUTHORIZED_KEYS" /run/sshd/authorized_keys
/usr/sbin/sshd

exec "$@"
