# Fatline

A native Mac client for Farcaster, and a reference for building one. It reads the people you follow, posts, and deletes. The feed is built on your Mac and every message is signed there.

Fatline has no built-in server or API key. You choose how it connects.

## Left out on purpose

Fatline is an opinionated client. These aren't in it, and there are no plans to add them:

- Replies
- Reactions
- Notifications
- Profiles
- Follow and unfollow
- Interacting with people you don't already follow

If you want any of that, use another client or fork this one.

## Download

[Download Fatline.dmg](https://github.com/danromero/fatline-mac/releases/latest/download/Fatline.dmg), open it, and drag Fatline to Applications. It needs macOS 27 or later, and it's signed and notarized, so it opens without a warning. When a new version is out, Fatline asks once, and if you say yes it replaces itself and restarts. It only installs a build signed by the same developer as the copy you're running. To find out, it asks GitHub for the latest release about once a day, which sends nothing about you beyond the usual web request.

## Connecting

Setup asks for a Neynar key, with buttons to use a code, Hypersnap or a custom server instead. Settings has the same four on one screen.

| Option | What you need | Who pays for reads |
| --- | --- | --- |
| Neynar key | A key from [dev.neynar.com](https://dev.neynar.com) | Your Neynar account |
| Code | A code written as `code@server.example` | Whoever issued it |
| Hypersnap | Nothing | [Quilibrium](https://quilibrium.com), which runs the public node at `haatz.quilibrium.com` |
| Advanced | An HTTPS server that answers Neynar's feed routes and Snapchain's | Whoever runs it |

Anyone can run either kind of server. To set up a custom server, give a coding agent [this guide](https://fatline.tech/custom-server.md), or deploy [fatline-server](https://github.com/danromero/fatline-server) yourself. [docs/SERVER.md](docs/SERVER.md) describes what an invite server has to answer.

## Your keys

You sign in with your Farcaster recovery phrase. It's used once to authorize a new posting key and isn't saved. The posting key stays in this Mac's Keychain, and your connection is saved there too. The server you connect to sees what you read and post, but never your phrase or posting key. Profile pictures and images in casts load straight from wherever they're hosted, so those sites can see your IP address.

Fatline doesn't verify the signatures on what a server sends, so use one you trust. A dishonest server could show false posts or names, or show you a post with another post's ID so that deleting it removes the wrong one of your own casts. It can't post as you or change what you write.

To report a security problem, see [SECURITY.md](SECURITY.md).

## Build it

You need Xcode 27 and an Apple Developer account, because the app's Keychain access requires a signed build.

```bash
cp Signing.local.example.xcconfig Signing.local.xcconfig
```

Put your team ID and a bundle ID you own in that file. Git ignores it. Then build and open Fatline Dev:

```bash
scripts/dev.sh
```

Run the tests with:

```bash
xcodebuild test -project Fatline.xcodeproj -scheme Fatline -destination 'platform=macOS,arch=arm64'
```

## Release it

Distributing a build needs two things once:

1. A Developer ID Application certificate. In Xcode, open Settings, Apple Accounts, Manage Certificates, then add one. Only the team's Account Holder can.
2. A saved notary login, using an app-specific password from [account.apple.com](https://account.apple.com):

```bash
xcrun notarytool store-credentials fatline-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Then, from a clean checkout:

```bash
scripts/release.sh
```

It runs the tests, signs, notarizes, and staples, then leaves `DerivedData.noindex/Release/Fatline.dmg` ready to attach to a GitHub release. Keep that filename, because the download link above depends on it. Tag the release `v` plus the app's version, like `v0.2.0`, because publishing it is what tells people there's an update. A fork should point the two addresses in `Fatline/UpdateCheck.swift` at its own repository.

## The recovery helper

`Fatline/Recovery/authorize.js` is a bundled, offline copy of the signing code for the recovery phrase. It's built from `scripts/recovery/authorize.mjs` with the pinned versions in `scripts/recovery/package-lock.json`, and rebuilding it gives identical bytes:

```bash
scripts/recovery/build.sh
```

## License

MIT. Inter, BLAKE3, and the libraries in the recovery helper keep their own licenses, which are included next to them.
