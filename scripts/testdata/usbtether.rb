cask "usbtether" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/PhilRoli/usbtether/releases/download/v#{version}/UsbTether-#{version}.zip"
  name "UsbTether"
  desc "Android USB tethering driver with approval popup"
  homepage "https://github.com/PhilRoli/usbtether"

  depends_on macos: :ventura

  app "UsbTether.app"

  postflight_steps do
    run "UsbTether.app/Contents/Resources/install-daemon.sh", base: :appdir, sudo: true
  end

  uninstall launchctl: "com.philipp.usbtether",
            delete:    [
              "/Library/LaunchDaemons/com.philipp.usbtether.plist",
              "/Library/PrivilegedHelperTools/usbtetherd",
            ]

  zap trash: [
    "/Library/Application Support/usbtether",
    "/var/log/usbtether.log",
    "~/Library/Preferences/com.philipp.UsbTether.plist",
  ]

  caveats do
    <<~EOS
      UsbTether is ad-hoc signed (not notarized). On first launch, right-click
      the app in Finder and choose "Open" to bypass Gatekeeper, or run:
        xattr -dr com.apple.quarantine /Applications/UsbTether.app
      The installer asks for your administrator password to install the
      background service (usbtetherd, a root launch daemon).
      The first time a phone is plugged in with USB tethering on, a popup asks
      you to approve it. Approved phones can be removed by opening UsbTether.app.
    EOS
  end
end
