#!/bin/bash
# Writes the Homebrew cask (app) and formula (CLI) for a published release into packaging/homebrew/,
# laid out like a tap repo (Himanshu-Sangshetti/homebrew-twinfold). Usage: scripts/homebrew.sh 0.4.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/homebrew.sh VERSION}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh release download "v$VERSION" --pattern checksums.txt --dir "$TMP"
APP_SHA=$(awk '/Twinfold-.*\.zip/ {print $1}' "$TMP/checksums.txt")
CLI_SHA=$(awk '/twinfold-.*-macos\.tar\.gz/ {print $1}' "$TMP/checksums.txt")
URL=https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v$VERSION

cat > packaging/homebrew/Casks/twinfold.rb <<RUBY
cask "twinfold" do
  version "$VERSION"
  sha256 "$APP_SHA"

  url "$URL/Twinfold-#{version}.zip"
  name "Twinfold"
  desc "Get disk space back without removing files: identical files share storage (APFS clones)"
  homepage "https://github.com/Himanshu-Sangshetti/twinfold"

  depends_on macos: ">= :sonoma"

  app "Twinfold.app"

  zap trash: [
    "~/Library/Application Support/Twinfold",
    "~/Library/LaunchAgents/app.twinfold.automatic.plist",
  ]
end
RUBY

cat > packaging/homebrew/Formula/twinfold.rb <<RUBY
class Twinfold < Formula
  desc "Free disk space by letting identical files share storage (APFS clones), undoable"
  homepage "https://github.com/Himanshu-Sangshetti/twinfold"
  url "$URL/twinfold-$VERSION-macos.tar.gz"
  sha256 "$CLI_SHA"
  license "MIT"

  depends_on :macos

  def install
    bin.install "twinfold"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/twinfold version")
  end
end
RUBY
echo "Wrote packaging/homebrew for $VERSION (app $APP_SHA, cli $CLI_SHA)"
