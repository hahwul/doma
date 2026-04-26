alias b := build
alias t := test
alias c := check

# List available recipes.
default:
    @just --list

# ---------- build ----------

# Build the doma binary (debug, fast iteration).
[group('build')]
build:
    shards build

# Release build (--release --no-debug --production).
[group('build')]
build-release:
    shards build --release --no-debug --production

# Run the bench harness against a seeded temp DB.
[group('build')]
bench:
    crystal run --release bench/bench.cr

# Remove build artifacts.
[group('build')]
clean:
    rm -rf bin/ lib/ .shards/
    find . -name '*.dwarf' -type f -delete

# ---------- development ----------

# Run the full spec suite.
[group('development')]
test:
    crystal spec

# Auto-format and auto-fix lint issues.
[group('development')]
fix:
    crystal tool format
    ./lib/ameba/bin/ameba.cr --fix

# Verify formatting + lint without changing anything (CI mirror).
[group('development')]
check:
    crystal tool format --check
    ./lib/ameba/bin/ameba.cr

# ---------- docs ----------
# `docs/` is a moving target during development. These recipes assume
# its presence; if it's not there yet, hwaro itself will produce the
# error message — no justfile-level guard needed.

# Serve the docs site locally (http://localhost:3000).
[group('docs')]
docs-serve:
    hwaro serve -i docs --base-url="http://localhost:3000"

# Build the docs site for deployment.
[group('docs')]
docs-build:
    hwaro build -i docs

# Install hwaro (the SSG used to build doma's docs).
[group('docs')]
docs-deps:
    brew install hahwul/hwaro/hwaro

# ---------- container ----------

# Build the local Docker image (host platform only — multi-arch lives in CI).
[group('container')]
docker-build:
    docker build -t doma:dev -f docker/Dockerfile .

# Run the locally-built image. Mounts ~/.config/doma so state persists.
[group('container')]
docker-run:
    docker run --rm -it -v "$HOME/.config/doma:/root/.config/doma" doma:dev

# ---------- release ----------

# Print the version declared in shard.yml (single source of truth).
[group('release')]
version:
    @grep '^version:' shard.yml | awk '{print $2}'
