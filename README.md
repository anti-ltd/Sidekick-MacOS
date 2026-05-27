# Sidekick (macOS)

**Remote desktop with deep integration.** The companion to
[sidekick-ios](../sidekick-ios) — share this Mac to your phone, or drive
another Mac from this one.

`host · client · webrtc · bonjour · cgevent · scrkit`

---

## What it does

Sidekick is a remote-desktop app that goes past plain screen sharing.
Beyond the live display + cursor + keyboard it also pipes:

- **Two-way clipboard sync** — copy on either device, paste on the other.
- **URL bar mirror** — when the host has a browser focused, the
  iOS client shows the current URL and can navigate by typing into a
  *native* field. No more aiming a remote cursor at a TV screen.
- **Claude Code transcript mirror** — when the host has a terminal running
  Claude focused, the iOS client mirrors the visible transcript so you can
  read replies on the phone instead of squinting at the TV. (Pulled via
  Accessibility for v1; reads `~/.claude/projects/.../transcript.jsonl`
  for v2.)
- **File browser** — list/read/write the host's home directory from the
  client. Drag-to-copy in either direction.

This Mac can also be the *client*, driving another Mac with all the same
deep-integration extras.

## Architecture

```
┌─ Sidekick/ ── standalone .app (AppDelegate, main window, icon renderer)
└─ SidekickCore/ ── all logic, embeddable as a library
   ├─ Discovery/       Bonjour browse + advertise (NWBrowser/NWListener)
   ├─ Signaling/       SDP/ICE exchange over the Bonjour TCP connection
   ├─ Transport/       Transport protocol — Loopback (today), WebRTC (next)
   ├─ Capture/         ScreenCaptureKit → VideoToolbox HEVC
   ├─ Input/           CGEvent injector (mouse, keyboard, text)
   ├─ RPC/             RPCEnvelope + channels: clipboard, urlbar, files,
   │                   claude
   ├─ Roles/           HostSession / ClientSession
   └─ UI/              SwiftUI screens (built on iUX-MacOS)
```

Discovery and the SDP/ICE handshake share the same Bonjour service
(`_sidekick._tcp`) — one socket family, separate sockets. The data
channel is a length-prefixed `RPCEnvelope` carrying tagged Codable
payloads — one envelope per RPC, demuxed by `RPCRouter`.

The protocol is shaped so swapping the transport doesn't ripple. The v0
ships with a `LoopbackTransport` for testing; the real `WebRTCTransport`
binds the same interface once the `stasel/WebRTC` SwiftPM dep is added
(see the TODO in `Package.swift`).

## Building

```bash
make build       # swift build -c release
make bundle      # assemble build/Sidekick.app and codesign
make run         # bundle + relaunch
make test        # unit tests for the RPC + loopback layer
make icon        # render Resources/AppIcon.icns from the in-app renderer
```

Requires **macOS 26 (Tahoe)** and Swift 6.1.

### Stable signing identity

Sidekick needs Accessibility (CGEvent injection) and Screen Recording
(ScreenCaptureKit). macOS keys those grants on the code signature — sign
ad-hoc and you re-prompt on every rebuild. Create a self-signed cert once
via Keychain Access → Certificate Assistant → Create a Certificate →
Code Signing, name **Sidekick Dev**, and the Makefile picks it up
automatically.

## Running it for real

To pair your Mac with [sidekick-ios](../sidekick-ios) over Wi-Fi:

```bash
make run             # builds, bundles, signs, opens Sidekick.app
```

First-launch prompts to expect (each shows up once per signed build):

1. **Local Network access** — needed to advertise on Bonjour. Allow it.
2. **Screen Recording** — needed for `ScreenCaptureKit`. macOS opens
   System Settings → Privacy & Security → Screen Recording; flip the
   Sidekick toggle on and re-launch the app.
3. **Accessibility** — needed for CGEvent injection (so the iOS client
   can drive your mouse + keyboard). Same flow: System Settings →
   Privacy & Security → Accessibility, flip Sidekick on.

Then in the Sidekick window pick the **Host** role. The status banner
flips to "Sharing — your devices can find this Mac as <hostname>" once
the capture pipeline is live. Connected iOS clients show up under
"Connected" as they join.

## State of play

- iUX-MacOS layout, Bonjour discovery, RPC envelope and every channel adapter:
  **working**.
- ScreenCaptureKit + VideoToolbox HEVC encoder: **wired but unused** —
  the WebRTC transport is stubbed.
- WebRTC transport: **stubbed**. See `Sources/SidekickCore/Transport/WebRTCTransport.swift`
  for what to do when the `stasel/WebRTC` dep lands.
- iOS counterpart: see [sidekick-ios](../sidekick-ios).

## Layout

```
Projects/
├── sidekick-mac/   ← you are here
├── sidekick-ios/   ← companion iOS app
├── iUX-MacOS/      ← shared macOS UX library
└── iUX-ios/        ← shared iOS UX library
```
