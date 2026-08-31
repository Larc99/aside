# Native gaps — read-only audit (2026-08-30)

Scope: the seven files listed in the task, audited against current Apple docs via context7.
Items already fixed per `docs/MACOS_NATIVE_UX.md` (e.g. `.modalPanel` misuse, status-item
tooltip/autosave/a11y) are marked as implemented, not re-reported. DeckViewModel.swift,
DeckViews.swift, NoteListModel.swift, NoteListView.swift, StickyWindowManager.swift,
SettingsView.swift excluded (actively being edited).

---

## 1. NSStatusItem — StatusItemController.swift: current API, compliant

Quoted evidence of compliance:

```swift
// StatusItemController.swift:13-23
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.autosaveName = "StickyDeckStatusItem"
...
let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "StickyDeck menu")
image?.isTemplate = true
button.image = image
button.toolTip = "StickyDeck"
button.setAccessibilityLabel("StickyDeck menu")
```

Every element the question asks about is already present and current:

- `statusItem.button` (not the deprecated `cell`/`title` path) — https://developer.apple.com/documentation/appkit/nsstatusitem/button
- Template rendering (`isTemplate = true`) — https://developer.apple.com/documentation/appkit/nsimage/istemplate
- Tooltip (`toolTip`) — https://developer.apple.com/documentation/appkit/nsview/tooltip
- Accessibility description (both on the image and the button) — https://developer.apple.com/documentation/appkit/nsimage/1513451-accessibilitydescription
- `autosaveName` — https://developer.apple.com/documentation/appkit/nsstatusitem/autosavename

`NSStatusItem.behavior` (https://developer.apple.com/documentation/appkit/nsstatusitem/behavior,
values `.removalBehavior` / `.terminationBehavior` / `.combinationBehavior`) controls when the
item is removed from the bar. Not setting it is correct for a permanent accessory-app item;
the default matches the product intent. **No actionable gap.** Availability annotations for
`behavior`/`autosaveName` availability values: unverified (AppKit pages not surfaced by
context7), but both are pre-10.15 APIs in practice.

Title-style capitalization ("Show Over Full-Screen Apps", StatusItemController.swift:68)
matches Apple's capitalization guidance — implemented per MACOS_NATIVE_UX.md.

## 2. NSPanel — DeckPanels.swift: correct level and collection behavior; one follow-up

The old `.modalPanel` violation is gone — both panels now use `.floating` with conditional
`.fullScreenAuxiliary`, which is exactly what MACOS_NATIVE_UX.md item 3 prescribed:

```swift
// DeckPanels.swift:26-32 (identical 54-60 in PillPanel)
func applyFullscreenBehavior() {
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
    if AppSettings.showOverFullScreen {
        collectionBehavior.insert(.fullScreenAuxiliary)
    }
}
```

`.floating` is the documented level for floating palettes
(https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/floating);
`.fullScreenAuxiliary` (https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
and `.ignoresCycle` are current, non-deprecated. `styleMask: [.borderless, .nonactivatingPanel]`
with `becomesKeyOnlyIfNeeded` (DeckPanels.swift:11, 20) is the documented non-modal panel
recipe. **No deprecated API found.**

### Gap — Stage Manager `.auxiliary` classification (DeckPanels.swift:28, 56)

- **What**: the only remaining modernization is adding a Stage Manager-aware collection
  behavior, guarded by availability.
- **Apple-documented API**: an AppKit `NSWindow.CollectionBehavior.auxiliary` is *unverified* —
  context7 (SwiftUI mirror) did not surface an AppKit page for it; check the macOS 26 SDK
  headers on this dev machine before adopting. The confirmed SwiftUI analog is
  `WindowManagerRole.associated` (macOS 15.0+): "windows … can be displayed alongside windows
  with a principal role in full screen or Stage Manager, but do not independently participate"
  (https://developer.apple.com/documentation/swiftui/windowmanagerrole/associated) — SwiftUI-scene
  only, so not directly applicable to these hand-built `NSPanel`s.
- **Risk**: low; behavior change only under Stage Manager, no pixel change.
- **Suggested shape** (only after header-verification of the symbol):

```swift
if #available(macOS 14.0, *) { // adjust to the header's real availability
    collectionBehavior.insert(.auxiliary) // unverified symbol — verify in NSWindow.h
}
```

## 3. Concurrency — AppDelegate.swift: `asyncAfter` chains

Correction to the premise: the chain at AppDelegate.swift:202–258 is **debug-only** (gated on
`STICKYDECK_DEBUG_FAN` / `_EXPAND` / `_AUTOSAVE` / `_ALL_NOTES`), not onboarding choreography.
The real onboarding path (OnboardingController.swift:42–54) already uses structured `Task`s
with a generation counter.

Gaps:

- **AppDelegate.swift:203, 217, 229, 242, 255** — `DispatchQueue.main.asyncAfter(deadline:)`
  chains with deeply nested closures. Current replacement: a structured, cancellable
  `Task.sleep` chain:

```swift
// AppDelegate.swift:203-210, instead of DispatchQueue.main.asyncAfter
let choreography = Task { @MainActor in
    try? await Task.sleep(for: .seconds(0.6))
    guard !Task.isCancelled else { return }
    viewModel.debugPinned = true
    viewModel.state = .fan
    ...
}
```

  with `choreography.cancel()` wherever the panel goes away (e.g. `hideAllPanels`,
  `applicationShouldTerminate`). Doc: https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:)

- **What breaks mid-chain today** (both forms, but asyncAfter cannot be interrupted):
  1. The nested `asyncAfter` blocks strongly capture `viewModel` and run to completion even if
     the deck panel is closed, the app is terminating, or the display is gone. Lines 204–209 /
     218–248 mutate `viewModel.state = .fan` unconditionally — if this lands after a collapse,
     the model is `.fan` while the panel is ordered out, i.e. exactly the stranded-fan bug
     DeckController.swift:268–276 works around.
  2. The 10 ticks at line 242 keep calling `viewModel.saveDraft` for ~9 s after the note could
     have been deleted or the store swapped (`StoreHub` swap during `setPersistenceInteractionBlocked`).
  3. On quit, pending blocks still fire during the final runloop turns — harmless today because
     `applicationShouldTerminate` replies late, but there is no way to cancel them.
- **Risk**: low (debug builds only). No pixel change.
- Note: in Swift 6 mode these blocks compile because `DispatchQueue.main.asyncAfter`'s closure
  is `@MainActor`-annotated in current SDKs — so this is a maintainability gap, not a
  compiler-visible concurrency violation.

## 4. macOS 26 "Liquid Glass" — confirmed API names and guard shape

Context7 surfaced Apple's macOS 26 SwiftUI docs. These are **real, confirmed** (all
macOS 26.0+; `Glass.regular` page explicitly lists "macOS 26.0+"):

| API | Signature / usage | URL |
|---|---|---|
| `View.glassEffect(_:in:)` | `nonisolated func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View` | https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:) |
| `Glass` | `static var regular: Glass { get }`; `.regular.tint(.orange).interactive()` | https://developer.apple.com/documentation/swiftui/glass/regular |
| `GlassEffectContainer` | `struct GlassEffectContainer`; wraps views; combines/morphs shapes. `GlassEffectContainer(spacing: 40.0) { ... }` (full init signature: unverified) | https://developer.apple.com/documentation/swiftui/glasseffectcontainer |
| `glassEffectID(_:in:)` | `.glassEffectID("pencil", in: namespace)` with `@Namespace` (exact generic signature: unverified) | https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views |
| `buttonStyle(.glass)` | `Button { } label: { }.buttonStyle(.glass)` — confirmed real | https://developer.apple.com/documentation/swiftui/landmarks-displaying-custom-activity-badges |

Guide: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
("apply glassEffect after any other modifiers that affect the view's visual appearance").

**AppKit `NSGlassEffectView`: unverified.** Context7 did not surface any AppKit Liquid Glass
page. I will not invent its signature; verify against the macOS 26 AppKit SDK headers
(`NSGlassEffectView` is believed to exist with a `contentView` property — treat as rumor until
header-checked).

### Guard shape (deploying to macOS 15)

Compiling requires the macOS 26 SDK (Xcode 26); the guard keeps runtime safety on 15:

```swift
extension View {
    @ViewBuilder
    func glassSurface(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape) // pre-26 fallback
        }
    }
}

// Buttons:
if #available(macOS 26.0, *) {
    content.buttonStyle(.glass)
} else {
    content.buttonStyle(.bordered)
}
```

Rendering caveat for this app: StickyDeck deliberately pins `NSApp.appearance = .aqua`
(AppDelegate.swift:58) on a custom pastel palette; Liquid Glass tints toward window/backdrop
content, so `.tint(NoteColor…)` would be required to keep notes recognizable. Pixel impact:
high if adopted; zero if deferred.
