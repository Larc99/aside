# macOS native UI/UX audit

Audit date: 2026-08-29

This audit covers the SwiftUI/AppKit UI of Aside as an `LSUIElement` accessory
app. The source observations refer to commit `c15be9a`, immediately before the
concurrent native-UX implementation pass began, and use current first-party Apple
documentation only. Aside's established geometry, listed below, is treated as a
fixed product constraint.

## Fixed layout constraints

Native-feel changes should preserve these values unless there is a considered
reason to move them:

- Resting tab 40 × 158 pt, 192 pt hover preview, 84 pt vertical reveal.
- Editor and pinned note 400 × 450 pt.
- All Notes 786 × 634 pt, divider at x=388.
- Archive 786 × 490 pt, with its narrower list pane.
- Onboarding 780 pt wide with a 375 pt left pane. (Height is deliberately 436 pt
  — recorded in `SPEC.md`.)
- The five palette colors and their order.
- The tab context-menu order, including Quit, even though Apple normally
  recommends a short context menu containing only commands relevant to the item.

The safest technique is to enlarge invisible hit regions, improve semantics, and
adapt behavior to system settings without moving visible artwork.

## Must-fix native behavior

### 1. Make every core path operable without hover

`PillView` exposes a label and hint, but opening the deck is implemented only in
`onHover`; the accessibility element has no activation action. A person using
VoiceOver, Switch Control, keyboard navigation, or a dwell-style pointer cannot
perform the instruction in the hint. Add an explicit accessibility action such as
“Open Deck,” and make the pill respond to activation as well as hover. The existing
menu-bar commands and global shortcuts are valuable alternative routes, but they do
not make the pill itself operable.

For each deck tab, expose the default Open action plus named actions for Pin/Unpin,
Duplicate, Delete, and color selection. Keep the context menu as it is, but
do not make it the sole route to tab-specific commands. Apple says assistive
technologies invoke controls through accessibility actions and recommends using
standard controls or `accessibilityRepresentation` for custom controls.

Relevant code:

- `Sources/Aside/Deck/DeckViews.swift`: `PillView`, `DeckTabView`, `PlusButton`,
  `MoreTile`.
- `Sources/Aside/App/StatusItemController.swift`: alternative global routes.

Apple sources:

- [Accessible controls](https://developer.apple.com/documentation/swiftui/accessible-controls)
- [`accessibilityRepresentation(representation:)`](https://developer.apple.com/documentation/swiftui/view/accessibilityrepresentation%28representation%3A%29)
- [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)

Visual impact: none. This adds nonvisual semantics and alternate input routes.

### 2. Treat panel focus as an explicit state machine

The deck and sticky windows correctly use borderless, nonactivating `NSPanel`s and
`becomesKeyOnlyIfNeeded`. Apple documents that such a panel becomes key only when
the hit view returns `true` from `needsPanelToBecomeKey`. Verify and enforce these
states rather than relying on incidental SwiftUI hosting behavior:

1. Hovering a pill, tab, `+`, or menu must not activate Aside or steal keyboard
   focus from the frontmost app.
2. Clicking title/body text must make the panel key and place the insertion point in
   the intended field on the first click.
3. Clicking a nonediting control must not unexpectedly discard editor selection.
4. Closing/unpinning must return focus cleanly to the previously active app.
5. Opening All Notes, Archive, Settings, or onboarding should activate Aside and
   make the requested window key.

An AppKit bridge around the hosted text controls can explicitly report
`needsPanelToBecomeKey` and `acceptsFirstResponder` if the current hosted hierarchy
does not do so reliably. Add UI tests for the key-window and first-responder
transitions above.

Apple sources:

- [`NSPanel.becomesKeyOnlyIfNeeded`](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)
- [`NSView.needsPanelToBecomeKey`](https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey)
- [`NSApplication.ActivationPolicy.accessory`](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory)

Visual impact: none; this makes the existing interaction deterministic.

### 3. Do not use the modal-panel window level for a nonmodal deck

`DeckPanel`, `PillPanel`, and `StickyPanel` switch from `.floating` to
`.modalPanel` when “Show over full-screen apps” is enabled. Apple defines
`.floating` as the level for floating palettes and `.modalPanel` as the level for a
modal panel. Aside panels are not modal. Keep them at `.floating` and implement
the preference through collection behavior instead.

The current collection behavior always contains `.fullScreenAuxiliary`, even when
the setting is off, so the visible preference and actual Space behavior can diverge.
Make the collection behavior conditional, and test both values in another app’s
full-screen Space and under Stage Manager. Continue using `.ignoresCycle` for these
auxiliary surfaces. A current-SDK implementation can also evaluate the newer
`.auxiliary` Stage Manager classification, guarded by deployment availability.

Apple sources:

- [`NSWindow.Level`](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct)
- [`NSWindow.Level.floating`](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/floating)
- [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)
- [`fullScreenAuxiliary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)

Visual impact: no geometry change. This may correct behavior that was previously
more aggressive than intended.

### 4. Apply Reduce Motion consistently, not only to deck tabs

`DeckTabView` reads `accessibilityReduceMotion`, but state transitions in
`DeckViewModel`, the root deck transition, matched geometry, button press scaling,
the `+`/More hover scaling, editor open/close, and undo-toast movement still animate
independently. Create one motion policy consumed by all deck surfaces:

- Normal: preserve the established spring/stagger language.
- Reduce Motion: remove spatial movement, scaling, and matched-geometry travel;
  use no animation or a short crossfade.
- The app-specific Brisk/Normal/Gentle setting may scale normal motion, but Reduce
  Motion must override it.

Also react when the accessibility display preference changes while the app is
running. SwiftUI environment values handle view updates; AppKit-owned timing should
observe `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification` or be driven
by SwiftUI state.

Apple sources:

- [`accessibilityReduceMotion`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
- [`NSWorkspace.accessibilityDisplayShouldReduceMotion`](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion)
- [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)

Visual impact: the default remains exact. Only the system accessibility variant
changes.

### 5. Give All Notes and Archive native focus, selection, and keyboard behavior

The split-view structure is appropriate, but the note list is a custom
`ScrollView`/`LazyVStack` with `onTapGesture`. The faint custom highlight is not a
keyboard focus model, rows cannot be traversed with arrow keys, and checkbox
selection is represented by a custom button rather than checkbox semantics. Apple
expects the selected row that drives a detail pane to remain persistently
highlighted, and macOS uses row highlighting to communicate focus.

Preserve the established row sizes and split widths while adding:

- A focusable list region with Up/Down, Home/End, Page Up/Page Down, Return, and
  Space behavior.
- Persistent row selection/focus traits; use the active accent highlight when the
  window is key and the inactive selection appearance when it is not.
- A real `Toggle` semantics layer for each custom checkbox, preferably via a custom
  `ToggleStyle` or `accessibilityRepresentation`.
- A real `Picker` semantics layer for All/Active/Archived and the four export radio
  choices, while retaining the existing artwork.
- Focus repair after search/filter/delete: move to the closest surviving row and
  notify assistive technologies of the changed selection/layout.
- A visible focus ring on search and text fields, and a clear keyboard path between
  search, list, detail actions, and the split divider.

Using native `List(selection:)` is the strongest semantic option but is likely to
change row insets and selection chrome. First implement the semantics and keyboard
behavior around the existing custom rows; consider a native List only after visual
comparison.

Apple sources:

- [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/)
- [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)
- [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [`FocusState`](https://developer.apple.com/documentation/swiftui/focusstate)
- [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)

Visual impact: keyboard and inactive-window states are additive. Replacing the
custom rows with native `List` would risk the established visuals and should be a
separate, screenshot-gated experiment.

### 6. Restore user-positioned windows and pinned notes

All Notes and Archive are resizable but do not assign frame autosave names. Pinned
notes are initially placed at the editor position, but their moved positions are not
persisted per note. This makes the app feel forgetful on every relaunch.

- Give All Notes, Archive, and Settings stable window identifiers and unique frame
  autosave names. Center only when there is no saved frame.
- Persist each sticky origin by note ID when the panel moves. Restore it to the
  corresponding display and clamp the 400 × 450 card to that display’s current
  `visibleFrame` after monitor/Dock/menu-bar changes.
- If the saved display no longer exists, choose the nearest current display rather
  than always using `NSScreen.main`.
- Keep the sticky size exactly 400 × 450; only position is restored.

Apple sources:

- [`setFrameAutosaveName(_:)`](https://developer.apple.com/documentation/appkit/nswindow/1419509-setframeautosavename)
- [Restoring your app’s state with AppKit](https://developer.apple.com/documentation/appkit/restoring-your-app-s-state-with-appkit)
- [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)

Visual impact: none; fixed initial sizes and geometry remain unchanged.

### 7. Make destructive feedback perceivable and controllable

Delete-with-Undo is the correct model for a common destructive action: Apple advises
against confirmation alerts for common undoable actions. Keep the 10-second
window, but make the feedback robust:

- Announce “Deleted …, Undo available” through an accessibility announcement.
- Ensure Command-Z remains routed to the pending note deletion even when a text
  editor or search field is first responder; after the deletion expires, return
  Command-Z to the normal responder-chain undo manager.
- Pause expiry while the toast itself is hovered or accessibility-focused. This is
  an accessibility exception to the 10-second timing, because Apple warns
  that time-boxed UI can be difficult for people who need more time.
- Use a sheet with Cancel for truly irreversible bulk purge or destructive sync
  removal, but do not add confirmation to ordinary note deletion while Undo works.

Apple sources:

- [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)
- [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [`AccessibilityNotification.Announcement`](https://developer.apple.com/documentation/accessibility/accessibilitynotification/announcement)

Visual impact: default expiry stays at 10 seconds. Pausing while explicitly engaged
is a small accessibility-only behavioral divergence.

### 8. Enlarge undersized click targets without enlarging their artwork

Apple’s macOS accessibility guidance gives 28 × 28 pt as the default control size
and 20 × 20 pt as the minimum. Several plain buttons appear to use only their tiny
label as the hit region: the editor’s 9 pt close dots, the 12 pt pin symbol, 6 pt
onboarding step indicators, and 14 pt custom radio glyphs. Wrap them in at least a
20 × 20 pt content shape, preferably 28 × 28 pt where the layout permits.

The editor color chips already reach the 20 pt minimum, and the 30 pt `+`/More
buttons are adequate. Add help tags to icon-only controls; the close and pin buttons
already have them and should retain them.

Apple sources:

- [Accessibility HIG — mobility and control size](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Offering help](https://developer.apple.com/design/human-interface-guidelines/offering-help)

Visual impact: no visible size or spacing change if the hit area expands invisibly.

## High-value polish

### Search fields

The custom search row omits standard search-field behavior such as a clear
button. Preserve its 30 pt chrome and add a
trailing clear control when nonempty, Escape-to-clear, and an appropriate search
field accessibility role. Replacing it wholesale with `.searchable` or
`NSSearchField` would bring more behavior for free but may change the layout;
treat that as a screenshot-gated prototype.

Apple source: [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)

### Contrast and transparency

The UI uses many low-opacity black labels (often 0.28–0.44) on pastel backgrounds
and material-backed undo toasts. Audit every surface with Accessibility Inspector.
At minimum, read `colorSchemeContrast`, `accessibilityDifferentiateWithoutColor`,
and `accessibilityReduceTransparency` to provide darker text/strokes, non-color
selection indicators, and opaque toast backgrounds when requested.

The default palette should not change. Preference-specific variants can
increase contrast while keeping all geometry fixed.

Apple sources:

- [Accessibility HIG — contrast and color](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [`accessibilityDifferentiateWithoutColor`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilitydifferentiatewithoutcolor)
- [`accessibilityReduceTransparency`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)

### Settings window

The grouped Form is appropriate. The settings window currently requests a 440 × 360
content rect while `SettingsView` requests 420 × 440; reconcile those sizes so the
window never clips or unexpectedly resizes. Apple recommends disabling the minimize
and zoom controls for Settings, using Command-Comma, minimizing the number of
preferences, and keeping task-specific controls near the task. The app already
provides Command-Comma and mirrors edge/full-screen controls in deck menus.

Recommended refinements:

- Remove or disable the enabled minimize button.
- Use “Aside Settings” as the one-pane title, as the app already does.
- Keep the current three sections until another pane is genuinely necessary; do not
  add a toolbar for a single pane.
- Make Reduce Motion a system override rather than another app preference.
- Present folder-selection errors as a sheet on Settings instead of an app-modal
  `runModal()` alert.

Apple source: [Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings)

### List-window chrome

The initial window sizes must remain exact, but first launch should center them and
subsequent launches should restore position/size. Retain divider dragging. Removing
the sidebar-toggle button is deliberate; restoring the standard toggle would
follow general sidebar guidance but would visibly change the window chrome, so it
is optional rather than a must-fix.

Apple sources:

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)

### Menu-bar item and menus

The status item is the right persistent reachability surface for an accessory app.
Add a tooltip, give it a stable `autosaveName`, and retain the accessibility
description. Use title-style capitalization in the status menu (“Deck Edge,” “Show
Over Full-Screen Apps”). Continue to show shortcut equivalents.

The tab context menu is an intentional HIG exception: it contains global items
such as All Notes, Archive, and Quit. Do not shorten or reorder it. Instead,
expose its item-specific commands through accessibility
actions and other visible surfaces.

Apple sources:

- [`NSStatusItem`](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [`NSStatusItem.button`](https://developer.apple.com/documentation/appkit/nsstatusitem/button)
- [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)

### Pinned-panel polish

Keep `hidesOnDeactivate = false` as an intentional product exception: a pinned note
must remain visible while the user works in another app. Limit dragging to the header
region instead of relying on `isMovableByWindowBackground` across the whole card, so
text selection and scrolling never turn into a window drag. Provide a pointing-hand
cursor only over the draggable header, matching the behavioral spec. Clamp the card
after every drag and display-configuration change.

Apple’s general floating-panel guidance normally says a floating panel hides when
the app deactivates. Aside deliberately differs because cross-app persistence is
the core pinned-note behavior.

Apple source: [`NSPanel.isFloatingPanel`](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel)

## Verification matrix

Before calling the UI native-quality complete, run this matrix on both screen edges:

1. Mouse and trackpad: slow hover, rapid diagonal hover, tab-to-tab transfer, `+`,
   More paging, context menus, scroll momentum, editor drag, and sticky drag.
2. Keyboard: global shortcuts, Tab/Shift-Tab, arrows in lists, Space on checkboxes,
   Return on the focused primary action, Escape, Command-W, Command-F, and Command-Z
   in every responder state.
3. Focus: frontmost third-party app remains active on deck hover; the first editor
   click types immediately; opening normal windows activates Aside; closing them
   restores a predictable front app.
4. Accessibility: VoiceOver traversal/actions, Voice Control labels, Full Keyboard
   Access, Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate
   Without Color, and Accessibility Inspector audits.
5. Windowing: one/two/three displays, displays above or left of the primary display,
   Dock on every edge, menu-bar auto-hide, display disconnect, Spaces, Stage Manager,
   and another app in full screen with the preference both on and off.
6. Geometry snapshots: verify that the six fixed dimensions listed at the top did
   not move.

Apple recommends running Accessibility Inspector audits for every screen, then still
testing with assistive technologies because a clean automated audit is not sufficient.

Apple sources:

- [Accessibility Inspector](https://developer.apple.com/documentation/accessibility/accessibility-inspector)
- [Performing accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app)
- [Testing system accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app)

## Suggested implementation order

1. Panel focus state machine and correct full-screen collection behavior.
2. Central Reduce Motion policy.
3. All Notes/Archive keyboard focus and control semantics.
4. Window/sticky frame persistence and display clamping.
5. Accessible delete announcements and hit targets.
6. Search, contrast/transparency variants, Settings, and menu-bar polish.

This order addresses interaction reliability first and leaves pixel geometry intact.
