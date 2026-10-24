class Twinfold < Formula
  desc "Free disk space by letting identical files share storage (APFS clones), undoable"
  homepage "https://github.com/Himanshu-Sangshetti/twinfold"
  url "https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v0.6.0/twinfold-0.6.0-macos.tar.gz"
  sha256 "1eec6a6cffb739eaf4e99a84ce273d95e6855b1ecd2fa677147721cc9b4950c2"
  license "MIT"

  depends_on :macos

  def install
    bin.install "twinfold"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/twinfold version")
  end
end
