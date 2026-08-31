# Pin-handoff API research (context7, Apple first-party docs, 2026-08-31)

Report only. "Unverified" = no first-party doc page found for the claim; do not build on it
without testing.

---

## 1. `Transaction.disablesAnimations`

```swift
var disablesAnimations: Bool { get set }
// "A Boolean property indicating whether views should disable animations
//  for changes occurring within this transaction. When true, animations
//  are suppressed."
// https://developer.apple.com/documentation/swiftui/transaction/disablesanimations
```

- **Documented direction**: a *view* suppressing an *ancestor's* animation. Apple's own example
  (https://developer.apple.com/documentation/swiftui/view/transaction%28value%3A_%3A%29) wraps a
  `flag.toggle()` in `withAnimation(.easeIn)` and gives one `Text`
  `.transaction(value: flag) { t in t.disableAnimations = true }` — that Text does not animate,
  its siblings do.
- Whether `withTransaction { $0.disablesAnimations = true }` suppresses a **descendant
  `.animation(_:value:)` modifier**: **unverified** — no doc page addresses that direction.
- `withAnimation(nil)` / `Transaction(animation: nil)` set the *ambient* transaction's animation
  to nil for that mutation. Whether a descendant `.animation(_:value:)` then overrides it (its
  documented job is "applies the given animation to this view when the specified value changes")
  or is suppressed: **unverified**.
- **The documented, citable tool for one specific state change**:

```swift
func transaction(value: some Equatable, _ transform: @escaping (inout Transaction) -> Void)
    -> some View
// "Apply this modifier to selectively adjust animation properties or disable
//  animations for specific views within a hierarchy."
```

```swift
Text("...")
    .animation(.spring, value: model.state)          // existing
    .transaction(value: isPinning) { $0.disablesAnimations = true }  // targeted kill switch
```

  The `.transaction(value:_:)` transform runs on every transaction reaching that subtree and
  is the last word for its subtree — that is what the doc example demonstrates. Precedence
  between it and `.animation(_:value:)` *on the same view* is **unverified**; put the
  `.transaction` modifier *below* (inside) the `.animation` in the chain if you need the kill
  to win.

## 2. Ordering a window front and the frame question

```swift
func orderFrontRegardless()  // "moves a window to the front of its level,
                             //  even if the application is not currently active"
func orderFront(_ sender: Any?)  // front of its level; no key/main change
// https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless()
// https://developer.apple.com/documentation/appkit/nswindow/orderfront(_:)
```

- **No documented guarantee** that the window is composited by the next display refresh, or in
  the same frame as other UI changes. **Unverified** — neither page says anything about frame
  timing.
- `func displayIfNeeded()` on NSWindow — "Passes a display message down the window's view
  hierarchy, redrawing all views that need displaying... You rarely need to invoke this method."
  It is the documented way to force pending drawing *now*, but it says nothing about first
  render of not-yet-laid-out content.
  https://developer.apple.com/documentation/appkit/nswindow/displayifneeded()
- `animationBehavior` (macOS 10.7+): `.none` = "Disables automatic animations for the window";
  `.utilityWindow` = "appropriate to the utility window style". Docs describe **which animation
  runs on orderFront/orderOut**, never a timing difference. Whether `.none` vs `.utilityWindow`
  changes *when* the window first appears: **unverified**. (The deck panel currently uses
  `.utilityWindow`, DeckPanels.swift:22.)
- `NSAnimationContext` (grouping, `allowsImplicitAnimation`, `runAnimationGroup`) manages
  *animation* of AppKit property changes; it is documented as functioning similarly to
  `CATransaction` (https://developer.apple.com/documentation/appkit/nsanimationcontext). Neither
  is documented as a same-frame compositing barrier. **Unverified.**

## 3. Moving a live NSView subtree between windows; child windows

```swift
func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode)
func removeChildWindow(_ childWin: NSWindow)
// https://developer.apple.com/documentation/appkit/nswindow/addchildwindow(_:ordered:)
```

- **Yes, parent/child windows are the documented co-movement tool**: "moving the parent window
  will cause the child window to move" and the child keeps "the relative position indicated by
  the ordering mode" (`.above` / `.below`). Documented warning: avoid cycles. This is a real,
  supported way to make two windows behave as one unit.
- `removeFromSuperview()`:
  "Unlinks the view from its superview **and its window**, removes it from the responder chain,
  and invalidates its cursor rectangles... removes any constraints... **Never invoke this method
  during display.**" The view is released — retain before moving.
  https://developer.apple.com/documentation/appkit/nsview/removefromsuperview()
- Re-adding a retained subtree to another window's contentView is *possible*, but the docs
  promise only unlinking — nothing guarantees layer backing, easing, or in-flight state
  survives the trip. For an `NSHostingView` the SwiftUI tree lives inside the hosting view, so
  moving it moves the tree in the AppKit sense; **SwiftUI view identity across the move is
  unverified/undocumented** (see §4).
- No documented AppKit API for atomic "move this live subtree, keep everything running". Treat
  reparenting mid-display as explicitly warned against ("never during display").

## 4. Same SwiftUI view identity across two windows — **Denied**

- WindowGroup: "The hierarchy that you declare as the group's content **serves as a template**
  for each window that the app creates from that group"; windows are "identically structured...
  each maintaining its own view state while sharing the same root view definition."
  https://developer.apple.com/documentation/swiftui/windowgroup
  https://developer.apple.com/documentation/swiftui/windows
- `openWindow(id:)` / `openWindow(value:)` **create a new instance** from that template.
  https://developer.apple.com/documentation/swiftui/environmentvalues/openwindow
- No first-party API exists to transplant view identity, `@State`, or layer backing from one
  window to another. Reusing one `NSHostingView`/`NSHostingController` in two windows is
  documented nowhere; **unverified and unsupported**. The only documented ways to keep state
  across windows are sharing an external model (e.g. an `@Observable` owned outside the view)
  — not view identity.

## 5. `NSHostingView` first-render timing

- **No documented statement** about first-render timing. Nothing in the NSHostingView pages
  says that creating the view and ordering its window front draws SwiftUI content in the same
  frame, and nothing promises the opposite either. The honest answer: **unverified**, and
  absence of a guarantee means you must not rely on same-frame first render.
- What IS documented:
  - `var sizingOptions: NSHostingSizingOptions` — size constraints derived from SwiftUI content
    "are only created when Auto Layout constraints are otherwise being used in the containing
    window"; as `contentView` it updates the window's `contentMinSize`/`contentMaxSize`.
    https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions
  - NSHostingView participates in normal constraint-based layout (`requiresConstraintBasedLayout`,
    `updateConstraints()`, `layout()`, `setFrameSize(_:)` overrides are all in its interface) —
    i.e. first layout follows AppKit's deferred layout pass, like any constraint-based view.
    `layoutSubtreeIfNeeded` is an inherited NSView method, not specifically documented for
    NSHostingView; calling it to force synchronous first SwiftUI layout is **unverified**.
- Practical reading: `setFrame(...)` + `orderFrontRegardless()` + `displayIfNeeded()` is the
  strongest documented synchronous sequence, but no doc says the SwiftUI content is *painted*
  before the next runloop pass.

---

## Implications for the synchronous pin handoff

1. Window-presented-synchronously + store-write-after is the right shape: §4 confirms identity
   cannot be transplanted, so a *new* window with a shared `@Observable` model is the only
   documented model-sharing route.
2. Expect at least one frame where the new sticky window is visible but SwiftUI content is not
   yet painted (§5) — no documented API removes that; if it shows in testing, the options are
   pre-warming a hidden window or accepting it, both undocumented behaviors.
3. `animationBehavior = .none` on the new window is documented to remove the show animation
   (not to change timing) — pair with `.transaction(value:)` `disablesAnimations` inside the
   card for the SwiftUI side (§1).
4. If the deck panel and sticky must not visibly "blink" apart, `addChildWindow` co-movement is
   documented, but it does not solve content transplant (§3).
