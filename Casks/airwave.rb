cask "airwave" do
  version "1.1.1"
  sha256 "01988d10149b334b77a43bfc6948417335f4acc9af610d1eb7b8e78e44e7bedb"

  url "https://github.com/sallliisa/Airwave/releases/download/v#{version}/Airwave_v#{version}.zip",
      verified: "github.com/sallliisa/Airwave/"
  name "Airwave"
  desc "System-wide spatial audio for macOS"
  homepage "https://github.com/sallliisa/Airwave"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Airwave.app"

  caveats <<~EOS
    Airwave requires a virtual audio device such as BlackHole 2ch.
    After installation, open Airwave and complete the aggregate-device setup.
  EOS

  zap trash: [
    "~/Library/Application Support/Airwave",
    "~/Library/Preferences/com.southneuhof.Airwave.plist",
    "~/Library/Saved Application State/com.southneuhof.Airwave.savedState",
  ]
end
