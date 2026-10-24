set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Install the Swift app in /Applications and link its CLI into ~/.local/bin
install:
    App/install.sh

# Build, publish a GitHub release, and update the cask in the gstark/tap Homebrew tap
homebrew:
    App/release.sh
