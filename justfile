alias b := build
alias t := test
alias c := check
alias vc := version-check
alias vu := version-update

# List available recipes.
default:
    @just --list

# Build the doma binary (debug, fast iteration).
[group('build')]
build:
    shards install
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

# Run the full spec suite.
[group('development')]
test:
    crystal spec

# Auto-format and auto-fix lint issues.
[group('development')]
fix:
    crystal tool format
    ./lib/ameba/bin/ameba.cr --fix

# Verify formatting and lint without changing anything.
[group('development')]
check:
    crystal tool format --check
    ./lib/ameba/bin/ameba.cr

# Check version consistency across all files.
[group('development')]
version-check:
    crystal run scripts/version_check.cr

# Update version across all files.
[group('development')]
version-update:
    crystal run scripts/version_update.cr

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

# Build the local Docker image.
[group('container')]
docker-build:
    docker build -t doma:dev -f docker/Dockerfile .

# Run the locally-built image with persistent state mount.
[group('container')]
docker-run:
    docker run --rm -it -v "$HOME/.config/doma:/root/.config/doma" doma:dev

# Print the version declared in shard.yml.
[group('release')]
version:
    @grep '^version:' shard.yml | awk '{print $2}'
