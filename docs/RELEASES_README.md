# Sonar for macOS

Sonar is a fast, private connection to your own server, for networks where other tools fail. It connects your Mac
(and, through it, your phone) to **your own VPS**. A guided setup takes you from "I have a VPS" to a working tunnel
with copy-paste commands.

- macOS 13 or newer, Apple silicon and Intel
- English only
- Typical speed about 1.5 MB/s

## Install

1. Download `Sonar-X.Y.Z.dmg` from [Releases](../../releases) and check the SHA-256 in the release notes.
2. Drag Sonar into Applications and open it.
3. If macOS blocks it: **System Settings → Privacy & Security**, scroll to the message about Sonar, click **Open Anyway**.
   (Right-click → Open no longer skips this on recent macOS.) Or run:
   `xattr -dr com.apple.quarantine /Applications/Sonar.app`

**Sonar is not notarized.** It is signed ad hoc, without an Apple Developer ID, so macOS cannot vouch for it.
You install it at your own risk. Sonar sends no telemetry.
