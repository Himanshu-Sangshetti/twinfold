class Twinfold < Formula
  desc "Free disk space by letting identical files share storage (APFS clones), undoable"
  homepage "https://github.com/Himanshu-Sangshetti/twinfold"
  url "https://github.com/Himanshu-Sangshetti/twinfold/releases/download/v0.4.0/twinfold-0.4.0-macos.tar.gz"
  sha256 "f604f8c5f173143ce47f639b4ec2f40b85da47dd8a81129c2c4417e6a6ec1e70"
  license "MIT"

  depends_on :macos

  def install
    bin.install "twinfold"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/twinfold version")
  end
end
