# Sonar

A macOS app that connects your Mac, and your phone through it, to your own VPS on networks that block UDP and
throttle TCP. A guided setup takes you from a fresh Ubuntu/Debian server to a working connection: you paste one
command on the server and Sonar does the rest.

- macOS 13+, Apple silicon and Intel
- Local proxies: SOCKS5 `127.0.0.1:10808` and `10809`, HTTP `10810`, optional Wi-Fi sharing for a phone on `10811`
- Downloads: [Releases](https://github.com/g3ntrix/sonar-releases/releases)

## How it works

```
apps -> Xray (SOCKS/HTTP) -> Hysteria2 client -> 127.0.0.1:18096 (UDP)
     -> relayd (ICMP echo, unprivileged socket) -> your VPS: sonar_link.py -> Hysteria2 server -> internet
```

Hysteria2 traffic is carried inside ICMP echo packets, which many restrictive networks still let through. The app
generates all passwords and the certificate itself, so the server install is a single command that can be run again
at any time.

## Layout

| Path | What |
|---|---|
| `Sources/Sonar/App` | App entry, branding, app state |
| `Sources/Sonar/Shared` | Models, secret store, Xray config, engine, connection tester, server script, proxy helper, UI components |
| `Sources/Sonar/Views` | Setup wizard, dashboard, tester, servers, share, logs, settings, donate, menu bar |
| `Sources/Sonar/Resources/Server` | `install.sh`, `check.sh`, `sonar_link.py`, embedded into the install command |
| `Helpers/relayd` | Go helper: `run` (transport), `check`, `net`, `watch` |
| `reference/` | Original Python prototype of the relay |
| `scripts/` | Build, DMG, release and leak-check scripts |

## Build

Requires Xcode 15+ (Swift 5.9) and Go 1.26+.

```
./scripts/build-app.sh        # dist/Sonar.app (universal, ad-hoc signed)
./scripts/make-dmg.sh         # dist/Sonar-<version>.dmg
./scripts/build-release.sh    # builds, writes notes with SHA-256, asks before uploading
```

Tests: `swift test` and `cd Helpers/relayd && go test ./...`. The version lives in `VERSION`.

Run `./scripts/check-secrets.sh` before committing or releasing. Put your own server IPs, one per line, in
`.private/leak-needles.txt` (untracked) so they can never end up in the repo.

## Known limits

- The server side serves one client at a time (one Mac; a phone goes through the Mac).
- Releases are ad-hoc signed and not notarized. See `docs/FIRST_LAUNCH.txt`.

## Donate

USDT (BEP20) `0x71F41696c60C4693305e67eE3Baa650a4E3dA796` · TON `UQCriHkMUa6h9oN059tyC23T13OsQhGGM3hUS2S4IYRBZgvx` ·
TRX `TFrCzU7bDey9WSh3fhqCBqhaiMzr8VhcUV`

## License

GPL-3.0. See `LICENSE`. The bundled Xray core is MPL-2.0 ([source](https://github.com/XTLS/Xray-core)).
