# `bin/`

This directory ships `quicklook`, a tiny summon wrapper.

It does **not** contain `quicklookd` Linux binaries. This repository is authored on macOS; committing fake or foreign-arch helpers would be a lie.

Get a real helper:

1. `../build.sh` on the Omarchy (Linux) machine, or
2. GitHub Actions `.github/workflows/release.yml` (musl x86_64 + aarch64 + checksums), then `../scripts/fetch-helper.sh`.

Until then, QML uses `../compat/quicklookd.sh`.
