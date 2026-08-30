# Aside takeover guide

Status date: 2026-08-29

This is the current maintainer map for the project.

## Product boundary

Aside is a free, open-source sticky-notes app for macOS, written from scratch.
`SPEC.md` is the behavioural contract. Licence and subscription UI are
deliberately absent. Sync-folder storage and custom fonts are extensions beyond
the app's original scope.

## Runtime map

1. `AppDelegate` constructs `AppEnvironment`, the deck, status item, window
   coordinators, hotkeys, sync-folder coordinator, and onboarding.
2. Every UI surface talks to the `NoteStore` protocol. `StoreHub` is the stable
   store captured by views and forwards to either `LocalNoteStore` or
   `SyncNoteStore`.
3. `LocalNoteStore` persists metadata in GRDB/SQLite and encrypts note bodies
   with AES-GCM. `KeyStore` owns the login-keychain key.
4. `DeckController` owns one dormant `PillPanel` per display and one movable
   `DeckPanel`. `DeckViewModel` owns the pill/fan/expanded state machine,
   debounced saves, note actions, and the remembered editor offset.
5. `WindowCoordinator` owns All Notes and Archive windows. Their shared
   `NoteListModel` handles filters, multi-selection, 250 ms preview autosave,
   archive/restore, and ten-second delete undo.
6. `StickyWindowManager` owns pinned note windows. `TransferService` owns the
   four export shapes and `.stickies`/Markdown/text import.
7. `DeckInteraction` owns deck timing/motion policy. `PinnedNotePlacement`
   owns the one-shot pin-frame handoff, per-note origins, and display clamping.

Changes propagate through `.noteStoreChanged` and `.appSettingsChanged`.
Deck autosaves update the open note in place and suppress their single store
echo so the editor does not lose first responder.

## Current verification baseline

- `swift test`: 99 tests passing (no flakes across repeated runs).
- `swift build`: no compiler warnings. Under the non-default
  `-strict-concurrency=complete` the package still reports ~66 warnings
  (it ships in Swift 5 language mode); this is down from 68 but is not clean,
  and is the main obstacle to a future Swift 6 language-mode migration.
- `scripts/make_app.sh`: production build, sandbox signing, and app assembly
  passing.
- Debug/visual runs can isolate their database with the documented
  `ASIDE_DEBUG_*` variables; a relative data-dir name resolves inside the
  sandbox temporary directory and never touches the normal note library.

## Highest-value remaining work

1. Run the manual accessibility/windowing verification matrix in
   `MACOS_NATIVE_UX.md`, especially first-click editor focus, multiple displays,
   Stage Manager, Reduce Motion, and Full Keyboard Access.
2. Add an update mechanism now that there is a public repository to release
   from. This is the largest remaining gap.
3. Decide whether sync-folder mode belongs in the default product surface. It
   is well tested, but it changes the privacy model from encrypted SQLite to
   plaintext Markdown.
5. Replace the hard-coded bundle version in `scripts/make_app.sh` with release
   metadata before publishing builds.

## Maintenance rules

- Treat `docs/SPEC.md` as the contract and label extensions explicitly.
- Preserve the fixed deck-panel geometry contract: SwiftUI layout and AppKit
  hit rectangles must change together in `DeckMetrics`.
- Never run visual QA against the default database or inherited sync-folder
  bookmark.
- Add regression coverage for state/persistence behavior; verify geometry and
  interaction changes in the assembled `.app`, not only through `swift run`.
