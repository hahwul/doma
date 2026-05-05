+++
title = "Installation"
description = "Install doma via Homebrew, AUR, Snap, prebuilt binary, container, or from source."
weight = 1
+++

## Homebrew

macOS and Linux:

```bash
brew tap hahwul/doma
brew install doma
```

## AUR (Arch Linux)

The [`doma`](https://aur.archlinux.org/packages/doma) package tracks the latest tagged release and pulls the static x86_64 binary from GitHub:

```bash
# with an AUR helper
paru -S doma
# or
yay -S doma

# or manually
git clone https://aur.archlinux.org/doma.git
cd doma
makepkg -si
```

## Snap

```bash
sudo snap install doma
```

The snap ships with `home`, `removable-media`, and `network` plugs. If you want doma to read or tag paths outside `$HOME` (e.g. `/mnt`, `/media`), connect the removable-media plug after install:

```bash
sudo snap connect doma:removable-media
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
doma doctor
```

`doctor` reports where doma writes, whether the config parses, and how the database is growing — reach for it first if something looks off:

```
Paths
     home                 /Users/me/.config/doma
  ·  config               /Users/me/.config/doma/config.yml
  ✓  database             /Users/me/.config/doma/doma.db

Config
     status               not present (using defaults)

Database
     size                 52.0 KB
     directories          4
     tags                 4
     schema               v2
```

`✓` means the file exists, `·` means it's missing (which is fine for `config.yml` — defaults apply).
