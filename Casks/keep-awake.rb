cask "keep-awake" do
  version "1.1.1"
  sha256 "d6c47af25e043c43e8afc8d38429f7161ae3bd7cbe8ebe705b3c65cdcb6cb95b"

  url "https://github.com/jaqbec1/KeepAwake/releases/download/v#{version}/Keep.Awake.zip"
  name "Keep Awake"
  desc "Menu bar utility for preventing sleep"
  homepage "https://github.com/jaqbec1/KeepAwake"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Keep Awake.app"

  uninstall quit: "sh.holistic.keepawake"

  caveats <<~EOS
    Stop any session and quit Keep Awake before upgrading or uninstalling.
    Closed-lid and restart recovery testing remains in progress.
  EOS
end
