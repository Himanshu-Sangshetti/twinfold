class Twinfold < Formula
  desc "Free disk space by letting identical files share storage (APFS clones), undoable"
  homepage "https://github.com/Himanshu-Sangshetti/twinfold"
  url "https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v0.7.0/twinfold-0.7.0-macos.tar.gz"
  sha256 "0c0a4fd57e75cc38b9c13d501fecd274261fd574c19679bb618d6423209d0c46"
  license "MIT"

  depends_on :macos

  def install
    bin.install "twinfold"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/twinfold version")
  end
end
