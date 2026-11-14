#!/bin/sh
set -eu

AUTHORIZED_KEYS=/root/.ssh/authorized_keys

mkdir -p /run/sshd /root/.ssh
chmod 0700 /root/.ssh

if [ ! -s "$AUTHORIZED_KEYS" ]; then
    echo "Missing SSH authorized_keys. Mount it at $AUTHORIZED_KEYS." >&2
    exit 1
fi

# Copy the bind-mounted key to a container-owned file. This preserves SSH's
# strict permission checks even when Docker Desktop exposes host files as 0777.
install -m 0600 "$AUTHORIZED_KEYS" /run/sshd/authorized_keys
/usr/sbin/sshd

exec "$@"
