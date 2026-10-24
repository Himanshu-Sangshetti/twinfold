cask "twinfold" do
  version "0.4.0"
  sha256 "80e2832d2eedf6653419a6f1eaf5a56409e371627a6318c8e2787b44373ea9a3"

  url "https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v0.4.0/Twinfold-#{version}.zip"
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
