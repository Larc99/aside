# Contributing to Aside

Thanks for taking a look. Aside is a small, single-purpose macOS app, and it is
easy to build: no Xcode project, no code generation, no accounts.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting it running

```bash
git clone https://github.com/Larc99/aside.git
cd aside
swift build          # debug binary
swift test           # unit tests
scripts/make_app.sh  # assembles build/Aside.app (sandboxed, ad-hoc signed)
```

You need macOS 15 or later and a Swift 6 toolchain (Xcode 16+). The only
dependency is [GRDB](https://github.com/groue/GRDB.swift).

`swift run` works for quick iteration, but several behaviours only appear in
the assembled bundle — the sandbox, the security-scoped bookmark used by
sync-folder mode, and the bundled fonts. **Verify anything to do with windows,
permissions or geometry in `build/Aside.app`, not through `swift run`.**

## Where things live

```
Sources/Aside/
  App/          entry point, settings, status item, app lifecycle
  Models/       Note + the five-colour palette
  Persistence/  GRDB store, the NoteStore protocol, the sync-folder store
  Crypto/       AES-GCM note cipher, keychain-backed key store
  Deck/         the edge panels: pill, fan, expanded editor (NSPanel + SwiftUI)
  Windows/      All Notes and Archive
  Sticky/       pinned desktop notes
  Transfer/     import/export, the .stickies archive format
  HotKeys/      global shortcuts (Carbon, so no accessibility permission)
  Onboarding/   first-run walkthrough
```

`docs/SPEC.md` is the behavioural contract. `docs/TAKEOVER.md` is the current
maintainer map and the list of open work.

## Things that will bite you

These are not style preferences. Each one is a bug that actually shipped here,
and the tests that guard them exist because of it.

**The deck's geometry has two consumers that must agree.** `DeckMetrics` is the
single source of truth for the deck's layout. The SwiftUI views draw from it
*and* `DeckController` builds its AppKit hit rectangles from it. Change one
without the other and controls become invisible-but-clickable, or
visible-but-dead. Change them in the same commit.

**Hit-test points are flipped; the metric rects are not.** `NSHostingView` is
flipped (top-left origin), every rect in `DeckMetrics` is AppKit
bottom-left. Anything that compares a live pointer location against those rects
must convert first, via `DeckMetrics.unflippedHitPoint`. This has been got wrong
twice, in two different call sites, and it is invisible for anything vertically
centred — which is most of the deck.

**`Color.clear` is not hit-testable in SwiftUI.** A shape filled with it accepts
no clicks. An unchecked checkbox drawn this way silently passed every click
through to the row behind it, which made the entire bulk-export pane unreachable
by mouse.

**You cannot enlarge a hit target with padding.** SwiftUI clips hit-testing to
the view's layout frame. `contentShape`, insets and negative padding all measure
as no-ops. Only real layout size counts — grow the frame and give the growth
back to the layout around it, then check the rendering is unchanged.

**The deck, pill and sticky windows are non-activating panels.** They are
essentially never the key window, and AppKit will not deliver a click to a view
that refuses first mouse in a non-key window. Anything hosting controls there
must go through `FirstMouseHostingView`, or its buttons will be silently dead
while its text fields keep working.

**Debounced saves must not write whole rows.** Every editor saves 250 ms after
you stop typing, by which time the note may have been archived, deleted or
edited elsewhere. Writing a snapshot resurrects it. Route content saves through
`NoteContentWriter.saveContent` and state changes through
`NoteContentWriter.applyStateChange`, both of which merge onto the store's live
copy.

**Never point a debug run at your real library.** Always set
`ASIDE_DEBUG_DATA_DIR` to an isolated name, and `ASIDE_DEBUG_DISABLE_SYNC=1` so
a saved sync-folder bookmark is not inherited.

## Debug hooks

Environment variables, honoured in debug and release builds. They are
env-gated and do nothing otherwise.

| Variable | Effect |
|---|---|
| `ASIDE_DEBUG_DATA_DIR=name` | Use an isolated database under the app's temporary directory |
| `ASIDE_DEBUG_DISABLE_SYNC=1` | Ignore any saved sync-folder bookmark |
| `ASIDE_DEBUG_SEED=1` | Seed an empty database with representative notes |
| `ASIDE_DEBUG_FAN=1` | Open the deck fan on launch, with hover-collapse suspended |
| `ASIDE_DEBUG_EXPAND=1` | Also expand the first note |
| `ASIDE_DEBUG_ALL_NOTES=1` | Open the All Notes window on launch |
| `ASIDE_DEBUG_AUTOSAVE=1` | Simulate typing bursts to check editor focus survives autosaves. Requires `ASIDE_DEBUG_DATA_DIR`, because it overwrites a note's body repeatedly |

A typical visual-QA run:

```bash
ASIDE_DEBUG_DATA_DIR=qa ASIDE_DEBUG_DISABLE_SYNC=1 ASIDE_DEBUG_SEED=1 \
  ASIDE_DEBUG_FAN=1 build/Aside.app/Contents/MacOS/Aside
```

## Testing

`swift test` must pass before a pull request. Add coverage for anything
behavioural — the store, the deck state machine, geometry, the sync-folder
format.

Be aware of what the suite *cannot* reach: it is all pure logic, so it says
nothing about whether a click lands, whether a window takes focus, or how
anything looks. Several of the worst bugs in this project's history were
invisible to a green suite. If your change touches event delivery, layering or
focus, exercise it in the assembled app and say so in the pull request.

For click-level questions, a small throwaway harness that synthesises
`NSEvent`s into a hosted SwiftUI tree works well — with a control case that
*must* fire, so a broken harness cannot masquerade as a passing test.

## A note on licensing

Contributions go in under the project's MIT licence. The bundled fonts are
SIL OFL 1.1, which is why `OFL.txt` sits beside them and gets copied into the
app bundle — if you touch the resource copying, keep it there.

## Pull requests

- Keep the change focused, and describe what you verified and how.
- Match the surrounding style. The codebase comments the *why* of anything
  subtle; please keep that up.
- `docs/SPEC.md` is the contract. If your change alters behaviour it describes,
  update it in the same PR.
- The fixed dimensions listed in `docs/MACOS_NATIVE_UX.md` should not move
  without a reason recorded alongside them.

## Reporting bugs

Please include your macOS version, whether you built from source or ran the
assembled app, and what you expected. Screenshots are especially useful here —
this is a visual app, and its most serious bugs to date were ones no amount of
code reading would have found.
