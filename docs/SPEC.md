# StickyDeck — Behavioral Spec

The behavioural contract for StickyDeck: what the app does, and where a choice was
deliberate rather than incidental. All code, UI copy, icons and design are written
from scratch. StickyDeck is free and open source, so licence and subscription behaviour
is intentionally absent. Sections marked **StickyDeck extension** go beyond the app's
original scope.

## Core concept
Sticky notes docked to a screen edge. Three states, one pointer movement:

1. **Pill (rest)** — a thin rounded strip (~12 pt wide) flush with the screen edge,
   one short colored dash per active note. No Dock icon, no main window.
2. **Fan (hover)** — moving the pointer over the pill fans the notes out as shingled
   40 × 158 pt tabs down the edge, staggered ~45 ms apart, each showing its vertical
   label. Hovering a tab expands it to a 192 pt readable preview without opening. A `+` tile below
   creates a note; if more than 8 notes, a scrollable/clickable "+N more" tile pages
   through the remaining notes.
3. **Expanded (click)** — the note slides clear of the deck into a 400 × 450 pt editor.
   Autoloads its content; saves ~250 ms after typing stops. Esc / close dot returns
   to the deck.

## Notes
- Fields: id, title, body, colorIndex, tag, pinned, createdAt, updatedAt,
  sortIndex, archivedAt, deletedAt.
- Five color swatches in this order: Amber `#FBDF8A`, Coral `#F2B194`, Mint
  `#C0E8D8`, Sky `#C0DEFB`, Lilac `#DED5F9`. Color cycles with ⌘. on the open note.
- Right-click menu on a tab: Color, Pin, Duplicate, Screen Side (Left / Right),
  All Notes…, Show Archive…, Delete, Quit. Mark complete lives in the editor,
  not this menu.
- New note opens where you last left one; pointer shows a hand over the draggable
  title bar area.

## Pinning
- "Pin to desktop" keeps the same 400 × 450 editor surface and position while
  detaching it into a floating sticky window (joins all Spaces). Close while pinned
  unpins it and returns it to the deck.
- Pinned notes are desktop windows only: the fan/deck excludes them (D8).

## Locking — StickyDeck extension / deferred
- "Hide note contents until you authenticate" — blurs/hides body until local
  authentication; re-auth to reveal.
- Locked notes are excluded from sync-folder mode (their bodies would be
  plaintext files); settings copy states this (D14).
- Locking is out of scope for launch.

## Archive
- Archiving removes the note from the deck but keeps it (color, dates, tag).
- Dedicated 786 × 490 archive window (⌥⌘L) with a searchable list, a read-only
  preview, Restore, and Delete. One click restores a note to the deck.

## All Notes (⌥⌘A)
- Single window with every note: searchable list (title, body, tag), filter
  All / Active / Archived, multi-select, and a preview pane with a fixed-height
  card showing created/updated dates. Initial focus and checkbox
  selection are independent: the first row previews with zero boxes checked.
- The preview card's **body is editable in place**, saving on the same 250 ms
  debounce as the deck editor and flushed on focus change, bulk actions and
  window close (D30). Editing here is a deliberate product choice: Archive's
  equivalent pane is read-only, and All Notes is where quick corrections
  actually happen. The title stays a heading here; titles are edited in the
  note editor.
- With one checked note the ordinary preview remains; with two or more, the right
  pane becomes the dedicated bulk-export surface with Markdown, Plain text,
  Single file, and Sticky archive choices.
- Actions: new note, archive, restore, delete (10 s undo), export, import.

## Search
- Search over title, body, and tag. The user-visible behavior is the contract;
  the storage layer is free to satisfy it however it likes.
- Search fields in deck-adjacent UI, All Notes, and Archive.

## Storage
1. **Local** — SQLite (GRDB); note *bodies* encrypted at rest (AES-GCM), key in the
   login keychain. Metadata (title, color, dates) in plaintext columns.
2. **Sync folder — StickyDeck extension** — optional user-chosen folder (e.g. iCloud Drive): notes written
   as plain files, one per note, so files sync between Macs; local-only notes stay
   encrypted on disk. Writes are atomic (temp + rename), filename = `<uuid>.md`
   with a versioned frontmatter block (`stickyDeck: 1`; files written under the
   app's earlier names carry `aside: 1` or `edgeNotes: 1` and are still read,
   since they live in the user's folder and outlive a rename); conflict policy =
   last-writer-wins on `updatedAt`; external changes are watched and imported.
   Deletions sync as `deletedAt` tombstones; purge removes the file.
   Locked notes are never written to the sync folder (D14).
- Title is an independent field, not derived from the first body line; `.md`
  import/export maps the first heading ⇄ title (D7).
- Schema uses soft-delete (`deletedAt`) plus archived/done states folded into
  `archivedAt`; `sortIndex` orders the deck. In-deck drag-to-reorder is deferred
  post-v1; `sortIndex` remains the ordering contract.

## Import / Export
- Export selected notes as: one `.md` per note, one `.txt` per note, single file,
  and a `.stickies` archive that keeps colors, states, and dates.
- Import `.stickies` (and readable note files); imported notes arrive active.
- Works offline, no account.

## Settings
- Deck edge: Left or Right.
- **StickyDeck extension:** Animation speed (stagger modes).
- **StickyDeck extension:** Font choice and size (bundled faces are
  OFL-licensed open fonts; empty setting = system rounded).
- Show over full-screen apps (toggle).
- Check for updates is not implemented. StickyDeck cannot make a truthful release
  check until there is a published release endpoint to check against.
- No licence or subscription UI: StickyDeck is free and open source.

## Global shortcuts (system hotkey API, no permissions)
- ⌥⌘N — new note
- ⌥⌘A — All Notes window
- ⌥⌘L — Archive window
- In-note: Esc close, ⌘F find, ⌘. cycle color.
- **Deliberate omission:** there is no in-note ⌘⌫ "delete note" shortcut.
  macOS defines ⌘⌫ in a text view as
  delete-to-start-of-line, and the body editor holds focus for nearly the whole
  time a note is open, so the shortcut shadowed a standard editing command with
  a destructive one. Deleting a note remains available from the editor footer,
  the tab context menu, and All Notes — all with the same 10 s undo.

## Windows & panels behavior
- Accessory app (LSUIElement): no Dock icon; quit via pill right-click menu or
  the menu-bar status item (D11). Reachability never depends on a single surface.
- NSStatusItem menu: New Note, All Notes, Archive, edge submenu, show over
  full-screen apps, Settings…, Quit (D11); window-opening requests travel as
  notifications.
- Deck is a floating non-activating panel that joins every Space (unaffected by
  Stage Manager); optional "show over full-screen apps".
- Each display gets its own dormant pill; the deck opens on the screen the pointer
  enters and stays there (screen switching is sticky: pill hover / explicit
  triggers only). Pills are rebuilt on display connect/disconnect.
- Pill is vertically centered on its edge, height clamped to
  [36 pt, 40 % of screen height]; the fan clamps to the visible frame (D10).
- Delete-undo toast is anchored inside the deck panel bottom; a newer delete
  replaces a pending one; undo restores the original `sortIndex`; purge after
  10 s (D9).
- Fast user switching is observed via `NSWorkspace.sessionDid(Resign|Become)Active`;
  the deck hides for a resigned session. This is an StickyDeck hardening behavior.
- Right-click pill menu: new note, all notes, archive, edge choice, show over
  full-screen apps, settings, and quit — items with icons. Check for Updates remains
  pending until the project has a public release endpoint.

## Onboarding
- First launch uses a 780 × 436 four-step split window: "One stripe per note, and
  nothing else", "Reach over and the deck fans out", "Open one and start typing",
  and "Finished notes step out of the way".
- The last step defaults "Add to Login Items" on and ends with "Make my first
  note". The wording and the miniature artwork are StickyDeck's own.
- The window is 436 pt tall: the value the layout was actually built and
  reviewed against. Treat it as intentional rather than as drift to correct.

## Privacy
- Local-only storage, encrypted bodies, no analytics, no third-party SDKs
  beyond GRDB. If an updater is added, the privacy copy must identify its network access.
- Sandboxed; only file access is user-chosen export/import/folder.
