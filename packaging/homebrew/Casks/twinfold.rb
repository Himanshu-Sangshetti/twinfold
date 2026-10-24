cask "twinfold" do
  version "0.7.0"
  sha256 "3e571d35b4e45c279c07a067ef1eca1189f5fb539299907c6a8b98d707933461"

  url "https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v0.7.0/Twinfold-#{version}.zip"
  name "Twinfold"
  desc "Get disk space back without removing files: identical files share storage (APFS clones)"
  homepage "https://himanshu-sangshetti.github.io/twinfold/"

  depends_on macos: :sonoma

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
