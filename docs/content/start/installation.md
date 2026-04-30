+++
title = "Installation"
description = "Install doma via Homebrew, from source, prebuilt binary, or container."
weight = 1
+++

## Homebrew

```bash
brew tap hahwul/doma
brew install doma
```

## From source

Requires [Crystal](https://crystal-lang.org/) 1.19 or newer and the SQLite headers.

```bash
git clone https://github.com/hahwul/doma.git
cd doma
shards install
shards build --release --no-debug --production
# binary lands at ./bin/doma
```

## Prebuilt binaries

Static Linux (x86_64, arm64) and macOS (x86_64, arm64) binaries are attached to every [release](https://github.com/hahwul/doma/releases). The Linux binaries are fully musl-static — no glibc or libsqlite3 dependency.

`.deb`, `.rpm`, and `.apk` packages are published alongside the binaries:

```bash
# Debian / Ubuntu
sudo dpkg -i doma_X.Y.Z_amd64.deb

# RHEL / Fedora
sudo rpm -i doma-X.Y.Z.x86_64.rpm

# Alpine
sudo apk add --allow-untrusted doma-X.Y.Z-x86_64.apk
```

## Container

Multi-arch image at `ghcr.io/hahwul/doma`:

```bash
docker pull ghcr.io/hahwul/doma:latest
docker run --rm -it \
  -v "$HOME/.config/doma:/root/.config/doma" \
  ghcr.io/hahwul/doma list
```

The volume mount keeps the doma database persistent across container runs.

## Verify the install

```bash
doma version
doma doctor   # path / config / DB sanity check
```

`doctor` is the first command to reach for if something looks off — it reports where doma writes, whether the config parses, and how big the database has grown.
