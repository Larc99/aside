# Aside

**Sticky notes that live at the edge of your screen. Reach over and they fan
out.**

Aside sits as a thin strip on the edge of your display — one small coloured
dash per note, and nothing else. Move the pointer over it and your notes fan
out like a deck of cards. Click one and it opens into an editor, right there.
Move away and it all folds back. No Dock icon, no window to manage, no app to
switch to.

Free, open source, and entirely offline.

<!-- TODO: screenshot of the fanned deck goes here. Stage it with ASIDE_DEBUG_SEED=1 ASIDE_DEBUG_FAN=1. -->

[![CI](https://github.com/Larc99/aside/actions/workflows/ci.yml/badge.svg)](https://github.com/Larc99/aside/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)](LICENSE)
![Platform: macOS 15+](https://img.shields.io/badge/Platform-macOS%2015%2B-black.svg)

## Why it exists

Most note apps ask you to go to them. This one is already where your pointer
is. It is built for the note you need for the next ten minutes — a phone
number, a command you keep forgetting, the thing you promised to do after this
meeting — not for a knowledge base.

Aside is inspired by [Hold My Notes](https://holdmynotes.app/), a paid Mac app
by [@shobhit99](https://github.com/shobhit99) that got this idea exactly right.
I wanted it, balked at the $6.99, and decided building my own was the more
interesting way to spend the money I was saving. That is the entire origin
story.

This is an independent reimplementation — written from scratch in Swift, from
observed behaviour and the public documentation, with no affiliation with or
endorsement by the original. If you want the polished, supported, notarized
version, go buy theirs. It is six dollars and it is good.

## What it does

- **The deck** — a 12 pt strip at the screen edge. Hover to fan the notes out;
  hover one to read it without opening; click to edit it in place.
- **Saves as you type**, about a quarter of a second after you stop.
- **Pin to the desktop** — pull a note out into its own floating window that
  follows you across Spaces.
- **Archive rather than delete** — completed notes leave the deck but stay
  searchable, and come back in one click.
- **All Notes** (⌥⌘A) — search titles, bodies and tags; filter; select several;
  export in bulk.
- **Export and import** — one `.md` or `.txt` per note, a single combined
  document, or a `.stickies` archive that preserves colours, states and dates.
- **Every display gets its own strip**, and the deck opens on the one you point
  at.
- **No permissions** — global shortcuts use the system hotkey API, so there are
  no Accessibility, Input Monitoring or Screen Recording prompts.
- **Optional sync folder** — store notes as plain Markdown in a folder you
  choose, such as iCloud Drive, so they follow you between Macs.

## Privacy

Your notes stay on your Mac. Note bodies are AES-GCM encrypted before they are
written, with the key in your login keychain. Aside makes no network
connections at all — no accounts, no telemetry, no crash reporting, and no
third-party SDKs beyond its database library.

[SECURITY.md](SECURITY.md) sets out exactly what is and is not protected,
including the parts deliberately left in plaintext.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌥⌘N | New note |
| ⌥⌘A | All Notes |
| ⌥⌘L | Archive |
| Esc | Close the open note |
| ⌘. | Cycle the open note's colour |

## Installing

Download **Aside.zip** from the
[latest release](https://github.com/Larc99/aside/releases/latest), unzip it,
and drag `Aside.app` into your Applications folder.

The build is signed and notarized by Apple, so it opens normally — no
right-clicking, no trip through System Settings. Requires macOS 15 or later.

Aside has no Dock icon. After launching it, look for the coloured strip on the
edge of your screen and the menu-bar item.

### Building from source

```bash
git clone https://github.com/Larc99/aside.git
cd aside
scripts/make_app.sh
open build/Aside.app
```

Needs a Swift 6 toolchain (Xcode 16+). Builds this way are ad-hoc signed, which
is fine to run locally. See [docs/RELEASING.md](docs/RELEASING.md) for how
distributable builds are signed and notarized.

## Contributing

Contributions are welcome, and the codebase is small enough to read in an
afternoon. [CONTRIBUTING.md](CONTRIBUTING.md) covers how to build and test it,
where everything lives, and — more usefully — the handful of traps in this code
that have caused real bugs, so you do not have to rediscover them.

Good places to start are listed in [docs/TAKEOVER.md](docs/TAKEOVER.md) under
"Highest-value remaining work". Participation is covered by the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Documentation

| Document | What it is |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | The behavioural contract, and which parts are deliberate divergences |
| [docs/TAKEOVER.md](docs/TAKEOVER.md) | Maintainer map, verification baseline, open questions |
| [docs/MACOS_NATIVE_UX.md](docs/MACOS_NATIVE_UX.md) | Native-behaviour audit against Apple's guidance |
| [docs/RELEASING.md](docs/RELEASING.md) | Signing and notarization checklist for cutting a downloadable build |

## Licence

MIT — see [LICENSE](LICENSE).

The bundled fonts are not MIT — they are SIL OFL 1.1, and
[their licence](Sources/Aside/Resources/Fonts/OFL.txt) has to ship with them.
The one dependency, [GRDB](https://github.com/groue/GRDB.swift), is MIT.
