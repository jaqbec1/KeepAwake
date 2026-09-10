cask "keep-awake" do
  version "1.1.0"
  sha256 "2c286998cb83bd4af92faef064fb175ff5262e09db3720438345f11495f52714"

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
    This development build is ad hoc signed and is not notarized.
    Closed-lid and restart recovery testing remains in progress.
  EOS
end
