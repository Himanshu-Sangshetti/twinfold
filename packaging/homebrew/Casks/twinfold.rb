cask "twinfold" do
  version "0.6.0"
  sha256 "1f3c68efdbd0b56d213125572515714ee4b89ba55976ec00415c0df613d8ef17"

  url "https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v0.6.0/Twinfold-#{version}.zip"
  name "Twinfold"
  desc "Get disk space back without removing files: identical files share storage (APFS clones)"
  homepage "https://himanshu-sangshetti.github.io/twinfold/"

  depends_on macos: ">= :sonoma"

  app "Twinfold.app"

  zap trash: [
    "~/Library/Application Support/Twinfold",
    "~/Library/LaunchAgents/app.twinfold.automatic.plist",
  ]

  caveats <<~EOS
    Twinfold is not notarized yet. If macOS blocks the first launch, open
    System Settings > Privacy & Security and click Open Anyway.
  EOS
end
