cask "twinfold" do
  version "0.5.0"
  sha256 "8d9a223c7d459c9c3b0b76f8bca290780e837dd9ccfa3a2793baa61b8485c2c6"

  url "https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v0.5.0/Twinfold-#{version}.zip"
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
