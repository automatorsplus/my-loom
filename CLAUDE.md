# Setting up MyLoom

You are setting up MyLoom, a menu-bar screen recorder for macOS with a camera bubble, on the user's Mac. Work through
the steps in order. Tell the user in one line what each step is doing. Don't change the source code unless the build
fails, and then change as little as possible and say what you changed.

## 1. Check the Mac

- `uname -m` must print `arm64` (Apple Silicon) and `sw_vers -productVersion` must be 14 or higher. If not, stop and tell
  the user MyLoom needs an Apple Silicon Mac on macOS 14 or later.
- `xcode-select -p` must print a path. If it fails, run `xcode-select --install`, ask the user to click **Install** in
  the dialog, and wait until they say it has finished.
- `brew --version` must work. If Homebrew is missing, ask the user to paste this into Terminal themselves (it asks for
  their Mac password, which you can't type for them), then carry on once it finishes:
  `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`

## 2. Install the build tools

```sh
brew install meson ninja
```

They're only needed to build the echo canceller, not to run MyLoom.

## 3. Build the echo canceller

```sh
./scripts/build-webrtc.sh
```

It downloads WebRTC's audio processing 2.1 from freedesktop.org, checks it against its published SHA-256 and builds it
into `Vendor/`. It ends with `Built WebRTC audio processing 2.1 into …` and a list of `.a` files. If the checksum check
fails, stop and tell the user; don't work around it.

## 4. Build MyLoom

```sh
./build.sh
```

It prints `Built …/build/MyLoom.app`.

## 5. Check the recorder works

This needs no permissions:

```sh
build/MyLoom.app/Contents/MacOS/MyLoom --selftest /tmp/myloom-selftest.mp4
```

It must print `PASS`. If it prints `FAIL`, fix that before going on.

## 6. Install and open

Ask the user whether to copy the app into Applications. If yes:

```sh
cp -R build/MyLoom.app /Applications/
open /Applications/MyLoom.app
```

Otherwise `open build/MyLoom.app`. A record icon appears in the menu bar. There is no Dock icon or window.

## 7. Permissions, then hand over

macOS asks for each one the first time it's needed. Tell the user what to expect:

1. **Screen Recording:** asked on the first screen recording. Turn on MyLoom under System Settings → Privacy & Security →
   Screen & System Audio Recording, then quit and reopen MyLoom.
2. **Camera:** asked the first time they choose **Show Camera Bubble** or **Camera Only**.
3. **Microphone:** asked when they start a recording with a microphone selected.

Then tell them, briefly: everything is in the menu-bar icon; recordings save as `.mp4` in the Movies folder; nothing
is uploaded. Sharing a recording as a link is optional and needs their own free Supabase project: **Set Up Sharing** in
the menu walks them through it, and the README's *Share a recording as a link* section has the steps. Offer to help
with that only if they ask.
