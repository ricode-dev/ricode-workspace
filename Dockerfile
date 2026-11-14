FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG NVM_VERSION=v0.40.3

ENV NVM_DIR=/usr/local/nvm \
    DOTNET_ROOT=/usr/share/dotnet \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    GH_TOKEN= \
    GITHUB_TOKEN= \
    PATH=/usr/local/nvm/current/bin:/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        git \
        openssh-client \
        openssh-server \
        tini \
        python3 \
        python3-pip \
        libicu-dev \
        unzip \
        zip \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/*.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        gh \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /workspace

# Use Microsoft's installer instead of the distribution package feed. Installing
# both channels in the same directory keeps dotnet capable of selecting either SDK.
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel 8.0 --install-dir "$DOTNET_ROOT" --no-path \
    && /tmp/dotnet-install.sh --channel 10.0 --install-dir "$DOTNET_ROOT" --no-path \
    && ln -s "$DOTNET_ROOT/dotnet" /usr/local/bin/dotnet \
    && rm /tmp/dotnet-install.sh \
    && dotnet --list-sdks

# Install all requested Node versions globally through NVM, and select v24 by default.
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | PROFILE=/dev/null NVM_DIR="$NVM_DIR" bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install 16 \
    && nvm install 22 \
    && nvm install 24 \
    && nvm alias default 24 \
    && NODE_VERSION="$(nvm version default)" \
    && ln -sfn "$NVM_DIR/versions/node/$NODE_VERSION" "$NVM_DIR/current"

# Make nvm available to interactive shells and make Node's default version
# available to non-interactive commands as well.
RUN printf '%s\n' \
        'export NVM_DIR=/usr/local/nvm' \
        'export CARGO_HOME=/usr/local/cargo' \
        'export RUSTUP_HOME=/usr/local/rustup' \
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
        'export PATH="$NVM_DIR/current/bin:/usr/local/cargo/bin:$PATH"' \
        > /etc/profile.d/workspace-tools.sh \
    && chmod 0644 /etc/profile.d/workspace-tools.sh

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
    && curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh \
        | env CODEGRAPH_INSTALL_DIR=/usr/local/lib/codegraph CODEGRAPH_BIN_DIR=/usr/local/bin sh \
    && rustc --version \
    && codegraph --version

# Mount the host key file with:
#   -v ~/.ssh/authorized_keys:/root/.ssh/authorized_keys:ro
RUN mkdir -p /root/.ssh \
    && chmod 0700 /root/.ssh \
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'PermitRootLogin prohibit-password' \
        'PubkeyAuthentication yes' \
        'AuthorizedKeysFile /run/sshd/authorized_keys' \
        > /etc/ssh/sshd_config.d/workspace.conf

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod 0755 /usr/local/bin/docker-entrypoint

WORKDIR /workspace
EXPOSE 22
VOLUME ["/workspace"]

# Forward stop signals to the command's process group and reap orphaned children.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/docker-entrypoint"]
CMD ["sleep", "infinity"]
