FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG NVM_VERSION=v0.40.3
ARG NETCOREDBG_VERSION=3.2.0-1092
# NetCoreDbg extension 1.0.0, using zed_extension_api 0.7.0.
ARG ZED_NETCOREDBG_REV=d8a8aa6c90faf155f983a44cc739b1cad34f4492
ARG ZED_NETCOREDBG_SOURCE_SHA256=24bcc7f6f64641259c2040f8c2ea5712cd480bbb180c66f62b5dcf404e4697cf
ARG ZED_EXTENSION_RUST_VERSION=1.93.1

COPY zed/install-netcoredbg-extension.sh /usr/local/bin/install-zed-netcoredbg-extension

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

# Build the official sources for the image's architecture instead of copying a
# host binary. Reuse the installed SDK and install all companion libraries.
# Also build the pinned Zed extension: the binary alone cannot register an adapter.
RUN apt-get update \
    && apt-get install -y --no-install-recommends clang cmake make gcc \
    && git clone --depth 1 --branch "$NETCOREDBG_VERSION" \
        https://github.com/Samsung/netcoredbg.git /tmp/netcoredbg \
    && CC=clang CXX=clang++ cmake -S /tmp/netcoredbg -B /tmp/netcoredbg/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local/share/netcoredbg \
        -DDOTNET_DIR="$DOTNET_ROOT" \
    && cmake --build /tmp/netcoredbg/build --parallel 2 \
    && cmake --install /tmp/netcoredbg/build \
    && ln -s /usr/local/share/netcoredbg/netcoredbg /usr/local/bin/netcoredbg \
    && rm -rf /tmp/netcoredbg /root/.nuget/packages \
    && curl -fsSL "https://codeload.github.com/qwadrox/zed-netcoredbg/tar.gz/${ZED_NETCOREDBG_REV}" \
        -o /tmp/zed-netcoredbg.tar.gz \
    && echo "$ZED_NETCOREDBG_SOURCE_SHA256  /tmp/zed-netcoredbg.tar.gz" | sha256sum -c - \
    && mkdir -p /tmp/zed-netcoredbg /usr/local/share/zed-extension-seeds/netcoredbg \
    && tar -xzf /tmp/zed-netcoredbg.tar.gz --strip-components=1 -C /tmp/zed-netcoredbg \
    && rustup toolchain install "$ZED_EXTENSION_RUST_VERSION" --profile minimal --target wasm32-wasip2 \
    && CARGO_HOME=/tmp/zed-extension-cargo cargo +"$ZED_EXTENSION_RUST_VERSION" build --locked --release \
        --target wasm32-wasip2 --manifest-path /tmp/zed-netcoredbg/Cargo.toml \
    && cp /tmp/zed-netcoredbg/extension.toml /tmp/zed-netcoredbg/LICENSE \
        /usr/local/share/zed-extension-seeds/netcoredbg/ \
    && cp -a /tmp/zed-netcoredbg/debug_adapter_schemas \
        /usr/local/share/zed-extension-seeds/netcoredbg/ \
    && cp /tmp/zed-netcoredbg/target/wasm32-wasip2/release/netcoredbg.wasm \
        /usr/local/share/zed-extension-seeds/netcoredbg/extension.wasm \
    && printf '\n[lib]\nkind = "Rust"\nversion = "0.7.0"\n' \
        >> /usr/local/share/zed-extension-seeds/netcoredbg/extension.toml \
    && printf 'source=https://github.com/qwadrox/zed-netcoredbg\nrevision=%s\nsource_sha256=%s\nrust=%s\nextension=1.0.0\napi=0.7.0\n' \
        "$ZED_NETCOREDBG_REV" "$ZED_NETCOREDBG_SOURCE_SHA256" "$ZED_EXTENSION_RUST_VERSION" \
        > /usr/local/share/zed-extension-seeds/netcoredbg/BUILD-INFO \
    && chmod 0755 /usr/local/bin/install-zed-netcoredbg-extension \
    && /usr/local/bin/install-zed-netcoredbg-extension --check-seed \
    && (cd /usr/local/share/zed-extension-seeds/netcoredbg && \
        sha256sum extension.toml extension.wasm debug_adapter_schemas/netcoredbg.json LICENSE BUILD-INFO > SHA256SUMS) \
    && /usr/local/bin/install-zed-netcoredbg-extension \
    && rm -rf /tmp/zed-netcoredbg /tmp/zed-netcoredbg.tar.gz /tmp/zed-extension-cargo \
    && apt-get purge -y --auto-remove clang cmake make gcc \
    && rm -rf /var/lib/apt/lists/* \
    && netcoredbg --version

COPY zed/settings.json /root/.config/zed/settings.json
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod 0755 /usr/local/bin/docker-entrypoint /usr/local/bin/install-zed-netcoredbg-extension

WORKDIR /workspace
EXPOSE 22
VOLUME ["/workspace"]

# Forward stop signals to the command's process group and reap orphaned children.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/docker-entrypoint"]
CMD ["sleep", "infinity"]
