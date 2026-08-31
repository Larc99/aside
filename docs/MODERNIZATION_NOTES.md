# Modernization Notes — macOS 15+ SwiftUI (researched via Apple docs, Aug 2026)

Target: macOS 15+, Swift 6 language mode. Facts below pulled from Apple docs via context7
unless marked **unverified**.

---

## 1. Observation framework (`@Observable`)

Migration guide:
https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro

### Replacement rules

| Old (ObservableObject)         | New (@Observable)                                  |
|--------------------------------|----------------------------------------------------|
| `class Book: ObservableObject` | `@Observable class Book`                           |
| `@Published var title`         | `var title` (plain stored property)                |
| `@StateObject var m = Model()` | `@State private var m = Model()`                   |
| `@ObservedObject var m: Model` | plain `var`/`let m: Model` — or `@Bindable` if you need `$m.field` bindings |
| `@EnvironmentObject var m: M`  | `@Environment(M.self) private var m`               |

```swift
// BEFORE
class Book: ObservableObject, Identifiable {
    @Published var title = "Sample Book Title"
    let id = UUID()
}

// AFTER
@Observable class Book: Identifiable {
    var title = "Sample Book Title"
    let id = UUID()
}
```

Environment: set with `.environment(library)` (not `.environmentObject`), read with type keypath:

```swift
@Observable class Library { var books: [Book] = [] }

@main struct BookReaderApp: App {
    @State private var library = Library()
    var body: some Scene {
        WindowGroup { LibraryView().environment(library) }
    }
}
struct LibraryView: View {
    @Environment(Library.self) private var library
    // ...
}
```

### Bindings into subviews

- View owns/creates the model (`@State`): bindings work directly — `$model.title` — no wrapper needed.
- Model arrives as a read-only property or from `@Environment`: use `@Bindable`:

```swift
struct TitleEditView: View {
    @Environment(Book.self) private var book
    var body: some View {
        @Bindable var book = book          // local Bindable in body
        TextField("Title", text: $book.title)
    }
}

struct BookEditView: View {
    @Bindable var book: Book               // replaces @ObservedObject when binding needed
    var body: some View { TextField("Title", text: $book.title) }
}
```

https://developer.apple.com/documentation/SwiftUI/Bindable

### `objectWillChange.send()` replacement

`@Observable` classes have **no `objectWillChange`**. Manual notification goes through the
`Observable` protocol's `withMutation(keyPath:)` / `registerTransaction` low-level members
(https://developer.apple.com/documentation/observation). In practice: **just mutate a tracked
stored property** — the macro-generated accessors do the registration for you. Direct
`withMutation(keyPath:) { ... }` is only needed for exotic cases (e.g. mutation triggered from
non-property code paths). Exact signature: **unverified** via context7 — see
`Observable` protocol page before relying on it.

### Gotchas

- **Computed properties**: not themselves tracked; observation tracks the *stored* properties a
  computed property reads, transitively, at access time in `body`.
- **`didSet`**: still runs, but the observation "mutation" is registered by the macro's generated
  setter around your code — mutations performed *inside* `didSet` are not separately announced.
  Prefer doing derived updates before/without `didSet`. (Partially **unverified**; WWDC24
  guidance.)
- **MainActor**: `@Observable` adds no isolation. In Swift 6 mode, mark UI models
  `@MainActor @Observable final class` yourself; macro accessors are `nonisolated` where possible.
- **Arrays/Sets of value types**: the whole collection is one observed dependency. Mutating one
  element invalidates every reader of that property (no per-element granularity).
- **Strict concurrency**: `@Observable` models are not implicitly `Sendable`. Keep them
  `@MainActor` and don't share across actors; `@State` ownership is the safe pattern.

---

## 2. `ContentUnavailableView` — macOS 14+

https://developer.apple.com/documentation/swiftui/contentunavailableview

```swift
// Full initializer (label/description/actions are ContentBuilder closures)
nonisolated init(
    @ContentBuilder label: () -> Label,
    @ContentBuilder description: () -> Description = { EmptyView() },
    @ContentBuilder actions: () -> Actions = { EmptyView() }
)
// https://developer.apple.com/documentation/swiftui/contentunavailableview/init(label:description:actions:)

// Static search variants
static var search: ContentUnavailableView<SearchUnavailableContent.Label,
                                           SearchUnavailableContent.Description,
                                           SearchUnavailableContent.Actions> { get }
static func search(text: String)
    -> ContentUnavailableView<Label, Description, Actions>
// https://developer.apple.com/documentation/swiftui/contentunavailableview/search
// https://developer.apple.com/documentation/swiftui/contentunavailableview/search(text:)
```

Usage with actions:

```swift
ContentUnavailableView {
    Label("No notes", systemImage: "note.text")
} description: {
    Text("Notes you add will appear here.")
} actions: {
    Button("New Note") { newNote() }
}

// Inside a .searchable hierarchy:
List { ... }
    .searchable(text: $query)
    .overlay {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }
```

`search`/`search(text:)` are designed for use inside a `searchable` hierarchy (the query is
parsed into the description).

---

## 3. Text-input polish (macOS 15+)

```swift
TextEditor(text: $text)
    .writingToolsBehavior(.complete)        // or .default/.none/.automatic
    .textEditorStyle(.plain)                // .automatic / .plain
    .scrollContentBackground(.hidden)       // macOS 13+; then .background(...) yourself
    .findNavigator(isPresented: $showFind)  // find & replace UI (macOS 13+)
    .textSelection(.enabled)                // macOS 12+ (TextField/Text)
    .autocorrectionDisabled(true)           // macOS 12+
    .spellChecking(.disabled)               // macOS 12+
    .onSubmit { save() }
```

| Modifier | Availability | Notes |
|---|---|---|
| `writingToolsBehavior(_:)` | macOS 15.x (exact minor **unverified** — Writing Tools shipped with Apple Intelligence, macOS 15.1) | `WritingToolsBehavior`: `.automatic`, `.default`, `.none`, `.complete`. Applies to selectable `Text`, `TextField`, `TextEditor`. https://developer.apple.com/documentation/swiftui/view/writingtoolsbehavior(_:) |
| `textEditorStyle(_:)` | macOS 14+ (**unverified** minor) | `func textEditorStyle(_ style: some TextEditorStyle) -> some View`; styles `.automatic`, `.plain`. https://developer.apple.com/documentation/swiftui/view/texteditorstyle(_:) |
| `scrollContentBackground(_:)` | macOS 13+ | `.visible` / `.hidden` / `.automatic`. https://developer.apple.com/documentation/swiftui/view/scrollcontentbackground(_:) |
| `findNavigator(isPresented:)` | macOS 13+ | Shows find-and-replace bar for `TextEditor`. https://developer.apple.com/documentation/swiftui/view/findnavigator(ispresented:) |
| `textSelection(_:)` | macOS 12+ | `.enabled` / `.disabled`. https://developer.apple.com/documentation/swiftui/view/textselection(_:) |
| `autocorrectionDisabled(_:)` | macOS 12+ | Replaces deprecated `autocorrection(_:)`. https://developer.apple.com/documentation/swiftui/view/autocorrectiondisabled(_:) |
| `spellChecking(_:)` | macOS 12+ | `.disabled` / `.enabled` / `.automatic`. https://developer.apple.com/documentation/swiftui/view/spellchecking(_:) |

`WritingToolsBehavior.automatic` is `static let automatic: WritingToolsBehavior` — system decides
(https://developer.apple.com/documentation/swiftui/writingtoolsbehavior/automatic).
Rich `TextEditor(text:selection:)` with `AttributedString` + `AttributedTextSelection` also
available for custom-formatting toolbars.

---

## 4. SF Symbols animation in SwiftUI — macOS 14+

```swift
// Effect triggered by a value change (bounce the icon when count changes)
Image(systemName: "checkmark.circle")
    .symbolEffect(.bounce, options: .nonRepeating, value: count)

// Indefinite effect while active (signature confirmed)
nonisolated func symbolEffect<T>(
    _ effect: T,
    options: SymbolEffectOptions = .default,
    isActive: Bool = true
) -> some View where T: IndefiniteSymbolEffect, T: SymbolEffect
// https://developer.apple.com/documentation/swiftui/view/symboleffect(_:options:isactive:)

// Content transition for symbol *replacement* changes
static func symbolEffect<T>(
    _ effect: T,
    options: SymbolEffectOptions = .default
) -> ContentTransition where T: ContentTransitionSymbolEffect, T: SymbolEffect
// https://developer.apple.com/documentation/swiftui/contenttransition/symboleffect(_:options:)

// Also: Transition.symbolEffect — for insert/remove transitions
static func symbolEffect<T>(_ effect: T, options: SymbolEffectOptions) -> SymbolEffectTransition
// https://developer.apple.com/documentation/swiftui/transition/symboleffect
```

Effects: `.bounce`, `.pulse`, `.variableColor`, `.scale` (+ `.replace` for
`ContentTransitionSymbolEffect`). Options: `.repeating`, `.nonRepeating`, `.speed(_)`,
`.repeat(_)`, default is `.default`.

```swift
// Change one symbol into another with animation
Image(systemName: isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
    .contentTransition(.symbolEffect(.replace))
    .animation(.snappy, value: isOn)

// Variant & rendering mode
Image(systemName: "person").symbolVariant(.fill)      // macOS 12+
// https://developer.apple.com/documentation/swiftui/view/symbolvariant(_:)
Image(systemName: "heart.fill").symbolRenderingMode(.hierarchical)  // macOS 12+
// https://developer.apple.com/documentation/swiftui/view/symbolrenderingmode(_:)
// .monochrome / .hierarchical / .palette / .multicolor
```

`symbolEffect(_:options:isActive:)` and `ContentTransition.symbolEffect` confirmed macOS 14.0+.
`symbolEffect(_:options:value:)` availability macOS 14+ (**unverified** minor; constraint is
`T: DiscreteSymbolEffect & SymbolEffect`, `U: Equatable` — **unverified** exact where-clause).
