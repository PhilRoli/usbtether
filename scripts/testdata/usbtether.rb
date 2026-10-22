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
            quit:      "com.philipp.UsbTether",
            delete:    [
              "/Library/LaunchDaemons/com.philipp.usbtether.plist",
              "/Library/PrivilegedHelperTools/usbtetherd",
              "/var/run/usbtether.sock",
              "/var/run/usbtetherd.pid",
            ]

  zap trash: [
    "/Library/Application Support/usbtether",
    "/var/log/usbtether.log",
    "/var/log/usbtether.log.1",
    "~/Library/Preferences/com.philipp.UsbTether.plist",
  ]

  caveats do
    <<~EOS
      UsbTether is ad-hoc signed (not notarized). The installer asks for your
      administrator password once to install the background service (usbtetherd,
      a root launch daemon) and removes the quarantine flag from it and the app.
      The first time a phone is plugged in with USB tethering on, a popup asks
      you to approve it. Approved phones can be removed by opening UsbTether.app.
      The popup needs the app at /Applications/UsbTether.app: after an --appdir
      install it never appears (usbtetherd only logs the request). If Gatekeeper
      blocks an app installed with --appdir, run:
        xattr -dr com.apple.quarantine /path/to/UsbTether.app
    EOS
  end
end
