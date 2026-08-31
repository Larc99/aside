# StickyDeck takeover guide

Status date: 2026-08-30

This is the current maintainer map for the project.

## Product boundary

StickyDeck is a free, open-source sticky-notes app for macOS, written from scratch.
`SPEC.md` is the behavioural contract. Licence and subscription UI are
deliberately absent. Sync-folder storage and custom fonts are extensions beyond
the app's original scope.

## Runtime map

1. `AppDelegate` constructs `AppEnvironment`, the deck, status item, window
   coordinators, hotkeys, sync-folder coordinator, and onboarding.
2. Every UI surface talks to the `NoteStore` protocol. `StoreHub` is the stable
   store captured by views and forwards to either `LocalNoteStore` or
   `SyncNoteStore`.
3. `LocalNoteStore` persists notes in GRDB/SQLite as plain rows.
   `LegacyEncryptedBodies` is a one-shot launch pass that rescues bodies left
   encrypted by 0.2.0 and earlier; delete it, and the `bodyEnc` column, once no
   install can still be carrying ciphertext.
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

- `swift test`: 143 tests passing in Swift 6 language mode.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`:
  passing with no compiler warnings.
- `STICKYDECK_UNIVERSAL=1 scripts/make_app.sh`: arm64 and x86_64 production
  builds, sandbox signing, resources, entitlements, and app assembly passing.
- Debug/visual runs can isolate their database with the documented
  `STICKYDECK_DEBUG_*` variables; a relative data-dir name resolves inside the
  sandbox temporary directory and never touches the normal note library.

## Highest-value remaining work

1. Run the manual accessibility/windowing verification matrix in
   `MACOS_NATIVE_UX.md`, especially first-click editor focus, multiple displays,
   Stage Manager, Reduce Motion, and Full Keyboard Access.
2. Add an update mechanism now that there is a public repository to release
   from. This is the largest remaining gap.
3. Decide whether sync-folder mode belongs in the default product surface. It
   is well tested, but it moves note bodies out of the sandbox container and
   into a folder that is usually a cloud drive.

## Maintenance rules

- Treat `docs/SPEC.md` as the contract and label extensions explicitly.
- Preserve the fixed deck-panel geometry contract: SwiftUI layout and AppKit
  hit rectangles must change together in `DeckMetrics`.
- Never run visual QA against the default database or inherited sync-folder
  bookmark.
- Add regression coverage for state/persistence behavior; verify geometry and
  interaction changes in the assembled `.app`, not only through `swift run`.
