class Twinfold < Formula
  desc "Free disk space by letting identical files share storage (APFS clones), undoable"
  homepage "https://github.com/Himanshu-Sangshetti/twinfold"
  url "https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v0.5.0/twinfold-0.5.0-macos.tar.gz"
  sha256 "3e7bd9b7e5092070b4c8008f25d24808a653c7baf2f9f42be96259ad3a75d81b"
  license "MIT"

  depends_on :macos

  def install
    bin.install "twinfold"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/twinfold version")
  end
end
