class Mqncm < Formula
  desc "CLI for a direct USB network link (CDC-NCM) between a Meta Quest and a Mac"
  homepage "https://github.com/dingyifei/mac-quest-ncm"
  url "https://github.com/dingyifei/mac-quest-ncm/releases/download/v@VERSION@/mqncm-@VERSION@-macos.zip"
  sha256 "@SHA256@"
  license "MIT"

  depends_on :macos

  def install
    bin.install "mqncm"
  end

  def caveats
    <<~EOS
      Needs adb: brew install --cask android-platform-tools
      The menu bar app is available as: brew install --cask dingyifei/tap/mac-quest-ncm
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/mqncm --version")
  end
end
