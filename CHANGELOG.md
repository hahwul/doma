# Changelog

## v0.1.1

### Added
- `mark` and `run` accept `-t/--tag` as an alias for positional tag args; both forms can be mixed on `mark` (#7)
- Installation docs cover AUR and Snap install paths (#6)

### Changed
- Snap build downloads the prebuilt static binary instead of compiling Crystal in-tree; amd64 + arm64 matrix (#6)

### Fixed
- `list -t ''` (and whitespace/comma-only variants) silently matched every path; now rejected (#8)
- `run -t TAG cmd…` without `--` reported "tag specified both positionally and via -t"; now reports "command is required after '--'" (#8)
- `mark` no-tag hint advertises both positional and `-t TAG` forms (#8)
- Homebrew release workflow: skip checksum upload to source release (b2895f6)

## v0.1.0

- First version!
