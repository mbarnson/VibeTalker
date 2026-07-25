# Gate 0: Native Platform Preflight

Status: **passed for development signing on the acceptance Mac**

Recorded 2026-07-24.

## Revisions

- macOS 27.0, build 26A5378j
- Xcode 27.0 beta, build 27A5209h
- Node 26.4.0 from Homebrew
- Apple development team 95S7RCGWWH

The Xcode build embeds Node and its 25 non-system dynamic libraries under
`Contents/Helpers`, rewrites every non-system load command to a bundle-relative
path, and signs each nested binary with Hardened Runtime. The Node executable
has `com.apple.security.cs.allow-jit`; the helper inherits App Sandbox.

The native host receives only App Sandbox, loopback-server/network-client, and
development-debug rights. It has no user-selected-file entitlement. Node
receives a constructed minimal environment rather than the host environment.

## Xcode-launched evidence

The **Run Native Preflight** control executes the same bundled helper that later
hosts pi. Its ordered native Event Ledger recorded:

1. `stdio: ping/pong passed`
2. `JIT: enabled=true, --jitless comparison=true`
3. `outside write: denied`
4. `network: denied`
5. `Gate 0 preflight passed`

The outside-write fixture attempts to create
`/Users/Shared/VibeTalkerEscapeFixture`. The nested command sandbox denies it.
The network fixture attempts a TCP connection to `1.1.1.1:443`; the same nested
profile denies it. Both run from the signed helper inside the Xcode-launched,
sandboxed app.

## Verification commands

```sh
xcodebuild -project VibeTalker.xcodeproj \
  -scheme VibeTalker \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/VibeTalkerDerivedData \
  build

xcodebuild -project VibeTalker.xcodeproj \
  -scheme VibeTalker \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/VibeTalkerDerivedData \
  test

codesign -d --entitlements - \
  /tmp/VibeTalkerDerivedData/Build/Products/Debug/VibeTalker.app

codesign -d --entitlements - \
  /tmp/VibeTalkerDerivedData/Build/Products/Debug/VibeTalker.app/Contents/Helpers/vibetalker-node
```

The local certificate chain currently reports `CSSMERR_TP_NOT_TRUSTED` under
strict command-line verification. This does not prevent Xcode development
launches, but Developer ID distribution trust remains a release prerequisite
and is not claimed by this gate.

## pi source policy

Pi will not be taken from a global npm install. `Dependencies/upstreams.json`
pins the official `badlogic/pi-mono` source revision, and
`scripts/build-pi-from-source.sh` clones, verifies, and builds that exact
revision. Packaging and tool-policy integration remain Gate 5 work.
