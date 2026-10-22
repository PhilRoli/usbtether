# usbtether

A trimmed fork of [rtether](https://github.com/nkazbekov/rtether) (MIT OR Apache-2.0): a macOS userspace RNDIS USB-tethering daemon (`usbtetherd`). It also builds on the ideas of erg-tether. Unlike upstream it only connects phones on an approved-phone allowlist: an unknown phone is not touched until an admin approves it over a local control socket (`/var/run/usbtether.sock`), and an approval app is launched for the console user when one is waiting.

Status: under construction.

## Releasing

Push a `vX.Y.Z` tag: the Release workflow tests, packages a universal build, publishes the GitHub release and updates the Homebrew cask in `PhilRoli/homebrew-tap`. Prerelease tags such as `v1.2.0-rc.1` publish a GitHub prerelease but skip the tap. Dependency bumps merged by Dependabot ship with the next manual tag.

## License

MIT OR Apache-2.0, see `LICENSE-MIT` and `LICENSE-APACHE`.
