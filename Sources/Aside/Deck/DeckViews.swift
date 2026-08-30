import SwiftUI

/// Balanced pointing-hand cursor management. Panels can vanish while hovered
/// (deck collapse), which would leave a pushed cursor stuck — all hover
/// cursors go through here, and the deck resets it on collapse.
@MainActor
enum DeckCursor {
    private static var owner: AnyHashable?

    static func setPointing(owner newOwner: AnyHashable, active: Bool) {
        if active {
            if owner == nil {
                NSCursor.pointingHand.push()
            }
            owner = newOwner
        } else if owner == newOwner {
            NSCursor.pop()
            owner = nil
        }
    }

    static func reset() {
        guard owner != nil else { return }
        NSCursor.pop()
        owner = nil
    }
}

// MARK: - Pill (rest state)

struct PillView: View {
    @ObservedObject var viewModel: DeckViewModel
    let screen: NSScreen
    let onHoverDeck: () -> Void

    var body: some View {
        PillSurface(
            viewModel: viewModel,
            height: DeckMetrics.pillHeight(noteCount: viewModel.deckNotes.count, screen: screen)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: viewModel.edge == .right ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { onHoverDeck() }
        }
        .onTapGesture(perform: onHoverDeck)
        .contextMenu { DeckMenu(viewModel: viewModel) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note deck, \(viewModel.deckNotes.count) notes")
        .accessibilityHint("Hover to fan out your notes")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onHoverDeck() }
    }
}

/// The visible resting control shared by the small pill panel and the deck's
/// final in-panel morph frame. Sharing this surface makes the window handoff
/// pixel-identical instead of asking two implementations to stay in sync.
struct PillSurface: View {
    @ObservedObject var viewModel: DeckViewModel
    let height: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color(white: 0.16).opacity(reduceTransparency ? 0.82 : 0.52))
                .shadow(color: .black.opacity(0.22), radius: 4, x: -1.5, y: 1)

            VStack(spacing: DeckMetrics.pillChipGap) {
                if viewModel.deckNotes.isEmpty {
                    Capsule()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: DeckMetrics.pillDashWidth, height: DeckMetrics.pillDashHeight)
                } else {
                    ForEach(Array(viewModel.deckNotes.prefix(DeckMetrics.pillMaxChips).enumerated()), id: \.element.id) { _, note in
                        Capsule()
                            .fill(NoteColor.at(note.colorIndex).fill)
                            .frame(width: DeckMetrics.pillDashWidth, height: DeckMetrics.pillDashHeight)
                    }
                }
            }
        }
        .frame(width: DeckMetrics.pillWidth, height: height)
    }
}

// MARK: - Fan (hover state)

struct FanView: View {
    @ObservedObject var viewModel: DeckViewModel
    var selectedID: UUID?
    @State private var pageStart = 0
    @FocusState private var keyboardFocusedNoteID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRightEdge: Bool { viewModel.edge == .right }

    /// Fan fitted to the current panel height (D26): tightens the stagger,
    /// then drops tabs on short displays so the fan never clips.
    private var layout: (visibleCount: Int, tabStep: CGFloat) {
        DeckMetrics.fanLayout(
            noteCount: viewModel.deckNotes.count,
            panelHeight: viewModel.panelHeight
        )
    }

    private var visibleNotes: [(offset: Int, note: Note)] {
        viewModel.deckNotes
            .dropFirst(pageStart)
            .prefix(layout.visibleCount)
            .enumerated()
            .map { (offset: $0.offset, note: $0.element) }
    }

    var body: some View {
        VStack(alignment: isRightEdge ? .trailing : .leading, spacing: DeckMetrics.tileGap) {
            ZStack(alignment: isRightEdge ? .topTrailing : .topLeading) {
                ForEach(visibleNotes, id: \.note.id) { index, note in
                    if note.id == selectedID {
                        // The open note is rendered by the expanded card, which
                        // is a separate always-mounted layer. This placeholder
                        // holds the slot so the fan doesn't shift under it.
                        Color.clear
                            .frame(width: DeckMetrics.tabWidth, height: DeckMetrics.tabHeight)
                            .offset(y: CGFloat(index) * layout.tabStep)
                    } else {
                        DeckTabView(
                            note: note,
                            index: index,
                            isPeeked: viewModel.peekedNoteID == note.id,
                            isKeyboardFocused: keyboardFocusedNoteID == note.id,
                            isRightEdge: isRightEdge,
                            action: { viewModel.select(note.id) },
                            onHoverChanged: { hovering in
                                viewModel.setPeek(note.id, hovering: hovering)
                            },
                            onTogglePin: { viewModel.togglePin(of: note.id) },
                            onSetColor: { viewModel.setColor($0, of: note.id) },
                            onDuplicate: { viewModel.duplicate(note.id) },
                            onDelete: { viewModel.deleteWithUndo(note.id) }
                        )
                        .focused($keyboardFocusedNoteID, equals: note.id)
                        .offset(y: CGFloat(index) * layout.tabStep)
                    }
                }
            }
            .frame(
                width: DeckMetrics.tabInteractionWidth(isPeeking: viewModel.peekedNoteID != nil),
                height: DeckMetrics.tabsExtent(visibleCount: visibleNotes.count, step: layout.tabStep),
                alignment: isRightEdge ? .topTrailing : .topLeading
            )
            .onMoveCommand(perform: moveKeyboardFocus)

            PlusButton {
                Task { await viewModel.newNote() }
            }

            if viewModel.deckNotes.count > layout.visibleCount {
                MoreTile(count: hiddenCount, action: showNextPage)
            } else if viewModel.deckNotes.isEmpty {
                EmptyDeckTile()
            }
        }
        .padding(isRightEdge ? .leading : .trailing, DeckMetrics.fanPadding)
        .background(
            ScrollWheelMonitor { deltaY in
                if deltaY < 0 { showNextPage() }
                if deltaY > 0 { showPreviousPage() }
            }
        )
        .onChange(of: viewModel.deckNotes.count) {
            clampPageStart()
            viewModel.drawnTabCount = visibleNotes.count
        }
        // The hit rect has to track the tabs on the *current page*, not the
        // layout's page size, or the blank strip on a partial last page
        // swallows clicks and pins the fan open.
        .onAppear { viewModel.drawnTabCount = visibleNotes.count }
        .onChange(of: pageStart) {
            viewModel.drawnTabCount = visibleNotes.count
        }
        // A display or Dock change resizes the panel, which changes how many
        // tabs fit; without this the hit rect keeps the old, smaller count and
        // the newly drawn tabs are click-through.
        .onChange(of: viewModel.panelHeight) {
            viewModel.drawnTabCount = visibleNotes.count
        }
        .onDisappear { viewModel.drawnTabCount = 0 }
    }

    private var hiddenCount: Int {
        max(viewModel.deckNotes.count - visibleNotes.count, 0)
    }

    private func showNextPage() {
        guard viewModel.deckNotes.count > layout.visibleCount else { return }
        viewModel.clearPeek()
        let next = pageStart + layout.visibleCount
        withAnimation(DeckInteraction.cardAnimation(reduceMotion: reduceMotion)) {
            pageStart = next >= viewModel.deckNotes.count ? 0 : next
        }
    }

    private func showPreviousPage() {
        guard viewModel.deckNotes.count > layout.visibleCount else { return }
        viewModel.clearPeek()
        withAnimation(DeckInteraction.cardAnimation(reduceMotion: reduceMotion)) {
            if pageStart == 0 {
                pageStart = ((viewModel.deckNotes.count - 1) / layout.visibleCount) * layout.visibleCount
            } else {
                pageStart = max(pageStart - layout.visibleCount, 0)
            }
        }
    }

    private func clampPageStart() {
        if pageStart >= viewModel.deckNotes.count {
            pageStart = 0
        }
    }

    private func moveKeyboardFocus(_ direction: MoveCommandDirection) {
        let notes = visibleNotes.map(\.note)
        guard !notes.isEmpty else { return }
        let current = keyboardFocusedNoteID.flatMap { id in notes.firstIndex { $0.id == id } }
        switch direction {
        case .down, .right:
            keyboardFocusedNoteID = notes[min((current ?? -1) + 1, notes.count - 1)].id
        case .up, .left:
            keyboardFocusedNoteID = notes[max((current ?? notes.count) - 1, 0)].id
        default:
            break
        }
    }
}

/// Observes wheel events over the fan without intercepting button clicks.
/// AppKit's local monitor is scoped to this view's window and bounds.
private struct ScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        weak var view: NSView?
        var onScroll: (CGFloat) -> Void
        private var monitor: Any?
        private var lastPageChange = Date.distantPast

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view, event.window === view.window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point), abs(event.scrollingDeltaY) > 1 else { return event }
                // A single trackpad gesture emits a burst of momentum events.
                // Page once per deliberate gesture instead of cycling through
                // the entire deck before the user's fingers come to rest.
                guard Date().timeIntervalSince(lastPageChange) >= 0.28 else { return event }
                lastPageChange = Date()
                onScroll(event.scrollingDeltaY)
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { uninstall() }
    }
}

/// Press feedback shared by every deck button: a quick, subtle compress.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(DeckInteraction.controlAnimation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct DeckTabView: View {
    let note: Note
    let index: Int
    let isPeeked: Bool
    let isKeyboardFocused: Bool
    let isRightEdge: Bool
    let action: () -> Void
    let onHoverChanged: (Bool) -> Void
    var onTogglePin: (() -> Void)?
    var onSetColor: ((Int) -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: NoteColor { NoteColor.at(note.colorIndex) }
    private var label: String { note.title.isEmpty ? "Untitled" : note.title }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if isRightEdge {
                    strip
                    if isPeeked { preview }
                } else {
                    if isPeeked { preview }
                    strip
                }
            }
            .frame(
                width: isPeeked ? DeckMetrics.peekWidth : DeckMetrics.tabWidth,
                height: DeckMetrics.tabHeight
            )
            .background(
                shingleShape
                    .fill(color.fill)
                    .overlay(shingleShape.strokeBorder(
                        isKeyboardFocused ? Color.accentColor.opacity(0.85) : Color.black.opacity(0.05),
                        lineWidth: isKeyboardFocused ? 2 : 0.5
                    ))
                    .shadow(color: .black.opacity(isPeeked ? 0.24 : 0.15), radius: isPeeked ? 13 : 7, x: -3, y: 5)
            )
        }
        .buttonStyle(PressScaleStyle())
        .frame(width: DeckMetrics.tabInteractionWidth(isPeeking: isPeeked), height: DeckMetrics.tabHeight,
               alignment: isRightEdge ? .trailing : .leading)
        .zIndex(isPeeked ? 100 : Double(50 - index))
        .onHover {
            onHoverChanged($0)
            DeckCursor.setPointing(owner: note.id, active: $0)
        }
        .onDisappear { DeckCursor.setPointing(owner: note.id, active: false) }
        .animation(DeckInteraction.hoverAnimation(reduceMotion: reduceMotion), value: isPeeked)
        .contextMenu {
            Menu {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    Button {
                        onSetColor?(color.rawValue)
                    } label: {
                        HStack {
                            Circle().fill(color.fill).frame(width: 10, height: 10)
                            Text(color.name)
                        }
                        if color.rawValue == note.colorIndex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Label("Color", systemImage: "paintpalette")
            }

            Button(action: { onTogglePin?() }) {
                Label("Pin", systemImage: "pin")
            }
            Button(action: { onDuplicate?() }) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Menu {
                Button("Left") { AppSettings.deckEdge = .left }
                Button("Right") { AppSettings.deckEdge = .right }
            } label: {
                Label("Screen Side", systemImage: "rectangle.righthalf.inset.filled")
            }

            Divider()

            Button {
                NotificationCenter.default.post(name: .openAllNotesRequested, object: nil)
            } label: {
                Label("All Notes…", systemImage: "square.grid.2x2")
            }
            Button {
                NotificationCenter.default.post(name: .openArchiveRequested, object: nil)
            } label: {
                Label("Show Archive…", systemImage: "archivebox")
            }
            Button(role: .destructive, action: { onDelete?() }) {
                Label("Delete", systemImage: "trash")
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Aside", systemImage: "power")
            }
        }
        // The per-tab delay rides on the transition itself. It used to sit in
        // an `.animation(_:value: note.id)`, but `note.id` is this view's
        // ForEach identity and so never changes — the stagger (and with it the
        // whole Brisk/Normal/Gentle setting) was unreachable.
        .transition(.asymmetric(
            insertion: reduceMotion
                ? .identity
                : AnyTransition
                    .move(edge: isRightEdge ? .trailing : .leading)
                    .combined(with: .opacity)
                    .animation(DeckInteraction.tabInsertionAnimation(
                        index: index,
                        reduceMotion: reduceMotion
                    )),
            // AppKit moves the containing panel during close. Tabs never own
            // close motion, which keeps their hover rendering unchanged.
            removal: .identity
        ))
        .modifier(DeckTabAccessibility(
            label: label,
            isPinned: note.pinned,
            open: action,
            togglePin: { onTogglePin?() },
            duplicate: { onDuplicate?() },
            delete: { onDelete?() }
        ))
    }

    private var shingleShape: UnevenRoundedRectangle {
        isRightEdge
            ? UnevenRoundedRectangle(topLeadingRadius: DeckMetrics.tabRadius,
                                     bottomLeadingRadius: DeckMetrics.tabRadius,
                                     bottomTrailingRadius: 0, topTrailingRadius: 0)
            : UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                     bottomTrailingRadius: DeckMetrics.tabRadius,
                                     topTrailingRadius: DeckMetrics.tabRadius)
    }

    private var strip: some View {
        HStack(spacing: 0) {
            if isRightEdge {
                verticalLabel
                stitch
            } else {
                stitch
                verticalLabel
            }
        }
        .frame(width: DeckMetrics.tabWidth, height: DeckMetrics.tabHeight)
    }

    private var stitch: some View {
        StitchLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3.4]))
            .foregroundColor(.black.opacity(0.14))
            .frame(width: 1, height: DeckMetrics.tabHeight - 18)
            .padding(.horizontal, 3)
    }

    private var verticalLabel: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .kerning(1.0)
            .textCase(.uppercase)
            .foregroundColor(.black.opacity(0.52))
            .lineLimit(1)
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: DeckMetrics.tabWidth - 8, height: DeckMetrics.tabHeight - 12)
            .clipped()
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(note.title.isEmpty ? "Untitled note" : note.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(note.updatedAt, style: .relative)
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(.black.opacity(0.36))
            }
            Text(note.body)
                .font(NoteTheme.bodyFont)
                .foregroundStyle(.black.opacity(0.72))
                .multilineTextAlignment(.leading)
                .lineLimit(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: DeckMetrics.peekWidth - DeckMetrics.tabWidth,
               height: DeckMetrics.tabHeight)
    }
}

/// Deck-tab accessibility, kept in a modifier so the tab's own body stays
/// within the type checker's reach.
///
/// `accessibilityElement(children: .ignore)` on a `Button` silently destroys
/// its default activation, so VoiceOver could reach a tab but never open it.
/// Restoring the default action and naming the tab's other commands means the
/// context menu is no longer the only route to them.
private struct DeckTabAccessibility: ViewModifier {
    let label: String
    let isPinned: Bool
    let open: () -> Void
    let togglePin: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Note: \(label)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityAction(named: "Open note") { open() }
            .accessibilityAction(named: isPinned ? "Unpin note" : "Pin note") { togglePin() }
            .accessibilityAction(named: "Duplicate note") { duplicate() }
            .accessibilityAction(named: "Delete note") { delete() }
    }
}

/// A 1pt vertical line shape used for the stitched edge detail.
struct StitchLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

struct PlusButton: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(white: 0.96).opacity(0.82))
                    .shadow(color: .black.opacity(hovered ? 0.22 : 0.12), radius: hovered ? 7 : 4, y: 2)
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.black.opacity(0.62))
            }
            .frame(width: DeckMetrics.plusSize, height: DeckMetrics.plusSize)
            .scaleEffect(!reduceMotion && hovered ? 1.08 : 1.0)
        }
        .buttonStyle(PressScaleStyle())
        .onHover {
            hovered = $0
            DeckCursor.setPointing(owner: "deck-new-note", active: $0)
        }
        .onDisappear { DeckCursor.setPointing(owner: "deck-new-note", active: false) }
        .animation(DeckInteraction.controlAnimation(reduceMotion: reduceMotion), value: hovered)
        .accessibilityLabel("New note")
    }
}

struct MoreTile: View {
    let count: Int
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text("+\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.black.opacity(0.6))
                .frame(width: DeckMetrics.plusSize, height: DeckMetrics.plusSize)
                .background(
                    Circle()
                        .fill(Color(white: 0.96).opacity(0.82))
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                )
                .scaleEffect(!reduceMotion && hovered ? 1.08 : 1.0)
        }
        .buttonStyle(PressScaleStyle())
        .onHover {
            hovered = $0
            DeckCursor.setPointing(owner: "deck-more-notes", active: $0)
        }
        .onDisappear { DeckCursor.setPointing(owner: "deck-more-notes", active: false) }
        .animation(DeckInteraction.controlAnimation(reduceMotion: reduceMotion), value: hovered)
        .accessibilityLabel("\(count) more notes")
        .accessibilityHint("Shows the next notes in the deck")
    }
}

struct EmptyDeckTile: View {
    var body: some View {
        Text("Empty")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .kerning(0.8)
            .textCase(.uppercase)
            .foregroundColor(.black.opacity(0.4))
            .frame(width: DeckMetrics.plusSize, height: DeckMetrics.plusSize)
    }
}

// MARK: - Expanded note editor

struct ExpandedNoteView: View {
    @ObservedObject var viewModel: DeckViewModel
    let note: Note
    /// False while the editor is mounted but translated off-screen. The
    /// subtree stays alive for a fast open, so its shortcuts and saves have to
    /// be switched off explicitly or ⌘⌫ deletes a note nothing is showing.
    var isActive: Bool = true

    @State private var title: String = ""
    @State private var body_: String = ""
    /// The note as it stood when the draft was last loaded, used to tell an
    /// unsaved local edit apart from an unchanged draft.
    @State private var baseline: Note?
    /// True while `loadDraft` is assigning, so its own writes to `title` and
    /// `body_` are not mistaken for typing.
    @State private var isLoadingDraft = false

    var body: some View {
        NoteEditorCard(
            title: $title,
            noteBody: $body_,
            colorIndex: note.colorIndex,
            updatedAt: note.updatedAt,
            isPinned: note.pinned,
            onClose: { viewModel.closeNote() },
            onTogglePin: { performAfterFlush { viewModel.togglePin(of: note.id) } },
            onSetColor: { viewModel.setColor($0, of: note.id) },
            onDelete: { performAfterFlush { viewModel.deleteWithUndo(note.id) } },
            onArchive: { performAfterFlush { viewModel.archiveNote(note.id) } },
            onDrag: { viewModel.dragCard(translationY: $0) },
            onDragEnd: { viewModel.finishDraggingCard() },
            autoFocus: viewModel.notePresentationPhase == .editing
        )
        .onAppear(perform: loadDraft)
        .onChange(of: note.id) { loadDraft() }
        .onChange(of: note.updatedAt) { adoptExternalChangeIfSafe() }
        .onChange(of: title) { scheduleSave() }
        .onChange(of: body_) { scheduleSave() }
        .onExitCommand { viewModel.closeNote() }
        // ⌘. cycles the open note's color (README shortcut table). A hidden
        // button carries the shortcut the same way Esc does.
        //
        // There is deliberately no ⌘⌫ "delete note" shortcut here. macOS
        // defines ⌘⌫ in a text view as delete-to-start-of-line, and the body
        // editor holds focus almost the whole time this card is open — so the
        // shortcut shadowed a standard editing command with a destructive one.
        // Delete stays available from the footer button, the tab context menu
        // and All Notes. This is an intentional divergence from the reference
        // app's shortcut set (see SPEC.md).
        .background(
            Button("Cycle color") { viewModel.cycleColor(of: note.id) }
                .keyboardShortcut(".", modifiers: .command)
                .opacity(0)
                .disabled(!isActive)
                .accessibilityHidden(true)
        )
        .contextMenu { editorMenu }
    }

    private func scheduleSave() {
        guard !isLoadingDraft, isActive, viewModel.state == .expanded(note.id) else { return }
        viewModel.saveDraft(id: note.id, title: title, body: body_, tag: note.tag)
    }

    /// Pin / archive / delete rewrite the note and drop it out of `deckNotes`,
    /// which makes the pending debounced save find nothing and silently
    /// discard the last few hundred milliseconds of typing.
    private func performAfterFlush(_ action: @escaping () -> Void) {
        Task {
            await viewModel.flushDraft(id: note.id, title: title, body: body_, tag: note.tag)
            action()
        }
    }

    /// Picks up an edit made elsewhere (All Notes, a sticky window, another
    /// Mac) without ever discarding unsaved local typing.
    private func adoptExternalChangeIfSafe() {
        // Our own save echoing back: nothing to adopt, just re-baseline.
        if note.title == title && note.body == body_ {
            baseline = note
            return
        }
        // Unsaved local edits win — the user is mid-sentence.
        if let baseline, title != baseline.title || body_ != baseline.body { return }
        loadDraft()
    }

    private func loadDraft() {
        isLoadingDraft = true
        title = note.title
        body_ = note.body
        baseline = note
        // Let this run loop's onChange callbacks settle before re-arming saves,
        // otherwise the assignments above are read back as user input and
        // replace the pending write with the pre-edit text.
        DispatchQueue.main.async { isLoadingDraft = false }
    }

    @ViewBuilder
    private var editorMenu: some View {
        Menu {
            ForEach(NoteColor.allCases, id: \.self) { color in
                Button(color.name) { viewModel.setColor(color.rawValue, of: note.id) }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        Button {
            viewModel.togglePin(of: note.id)
        } label: {
            Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin")
        }
        Button {
            viewModel.duplicate(note.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Menu {
            Button("Left") { AppSettings.deckEdge = .left }
            Button("Right") { AppSettings.deckEdge = .right }
        } label: {
            Label("Screen Side", systemImage: "rectangle.righthalf.inset.filled")
        }

        Divider()

        Button {
            NotificationCenter.default.post(name: .openAllNotesRequested, object: nil)
        } label: {
            Label("All Notes…", systemImage: "square.grid.2x2")
        }
        Button {
            NotificationCenter.default.post(name: .openArchiveRequested, object: nil)
        } label: {
            Label("Show Archive…", systemImage: "archivebox")
        }
        Button(role: .destructive) {
            viewModel.deleteWithUndo(note.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }

        Divider()

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Aside", systemImage: "power")
        }
    }
}

/// The exact editor chrome is shared by an expanded deck note and its pinned
/// desktop form. Pinning deliberately does not switch to a native titled
/// window; the same 400×450 card remains on screen.
struct NoteEditorCard: View {
    private enum EditorField: Hashable {
        case title
        case body
    }

    @Binding var title: String
    @Binding var noteBody: String
    let colorIndex: Int
    let updatedAt: Date
    let isPinned: Bool
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onSetColor: (Int) -> Void
    let onDelete: () -> Void
    let onArchive: () -> Void
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var autoFocus = true
    /// Pinned notes opt out: on a sticky, `onClose` unpins, and Escape is the
    /// reflex for dismissing an IME candidate or cancelling a field — it must
    /// not rip the note off the desktop mid-sentence.
    var closesOnEscape = true

    @FocusState private var focusedField: EditorField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: NoteColor { NoteColor.at(colorIndex) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.16).padding(.horizontal, 16)

            TextEditor(text: $noteBody)
                .font(NoteTheme.bodyFont)
                .foregroundStyle(.black.opacity(0.76))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .focused($focusedField, equals: .body)

            Divider().opacity(0.16)
            footer
        }
        .frame(width: DeckMetrics.noteWidth, height: DeckMetrics.expandedCardHeight)
        .background(color.fill)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.black.opacity(0.035), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, x: -2, y: 7)
        .onAppear {
            requestFocusIfNeeded()
        }
        .onChange(of: autoFocus) { _, shouldFocus in
            if shouldFocus {
                requestFocusIfNeeded()
            } else {
                focusedField = nil
            }
        }
        .animation(DeckInteraction.controlAnimation(reduceMotion: reduceMotion), value: colorIndex)
    }

    private func requestFocusIfNeeded() {
        guard autoFocus else { return }
        DispatchQueue.main.async {
            focusedField = title.isEmpty ? .title : .body
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Circle().fill(.black.opacity(0.21)).frame(width: 9, height: 9)
                    // 9pt of artwork is far below Apple's 20pt minimum target.
                    // SwiftUI clips hit-testing to the frame, so the frame has
                    // to grow; the negative padding hands the growth back to
                    // layout, which keeps the rendering pixel-identical
                    // (verified by bitmap diff). Horizontally the gain is
                    // bounded by the neighbouring dot, which wins the overlap;
                    // vertically the 44pt header has room to spare.
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
                    .padding(.horizontal, -7.5)
            }
            .buttonStyle(.plain)
            .modifier(EscapeShortcut(enabled: closesOnEscape))
            .help("Close note")
            .accessibilityLabel("Close note")

            editorDragHandle

            TextField("Untitled note", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.black.opacity(0.78))
                .lineLimit(1)
                .focused($focusedField, equals: .title)
                .onSubmit { focusedField = .body }

            Spacer(minLength: 8)

            (Text("Saved · ") + Text(updatedAt, style: .relative))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.black.opacity(0.40))
                .lineLimit(1)

            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black.opacity(0.42))
                    // Same pattern as the close dot: grow the frame for the
                    // hit target, give the growth back so nothing moves.
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
                    .padding(.horizontal, -7)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin from desktop" : "Pin to desktop")
            .accessibilityLabel(isPinned ? "Unpin note from desktop" : "Pin note to desktop")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    @ViewBuilder
    private var editorDragHandle: some View {
        ZStack {
            Circle().fill(.black.opacity(0.10)).frame(width: 9, height: 9)
            if let onDrag {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { onDrag($0.translation.height) }
                            .onEnded { _ in onDragEnd?() }
                    )
            } else {
                NativeWindowDragHandle()
            }
        }
        .frame(width: 14, height: 22)
        .help("Drag note")
        .accessibilityLabel("Drag note")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(NoteColor.allCases, id: \.self) { swatch in
                Button { onSetColor(swatch.rawValue) } label: {
                    RoundedRectangle(cornerRadius: swatch == color ? 7 : 5, style: .continuous)
                        .fill(swatch == color ? Color.clear : swatch.fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: swatch == color ? 7 : 5, style: .continuous)
                                .stroke(.black.opacity(swatch == color ? 0.43 : 0.035), lineWidth: swatch == color ? 2 : 0.5)
                        )
                        .frame(width: swatch == color ? 29 : 20, height: swatch == color ? 29 : 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(swatch.name) color")
            }

            Spacer(minLength: 8)

            Button("Delete", role: .destructive, action: onDelete)
                .buttonStyle(.bordered)
            Button("Mark complete", action: onArchive)
                .buttonStyle(.bordered)
            Button("Close", action: onClose)
                .buttonStyle(.bordered)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .controlSize(.regular)
        .padding(.horizontal, 7)
        .frame(height: 55)
    }
}

/// Applies Escape-to-close only where it belongs. Binding a decoy shortcut
/// instead would leave a real, if obscure, key combination wired to closing.
private struct EscapeShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.escape, modifiers: [])
        } else {
            content
        }
    }
}

/// Lets AppKit own desktop-note movement, including pointer capture and the
/// native dragging behavior across displays. It occupies only the second dot
/// so title selection and header buttons never accidentally move the card.
private struct NativeWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

    }
}

// MARK: - Undo toast

struct UndoToastView: View {
    @ObservedObject var viewModel: DeckViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let pending = viewModel.pendingDelete {
            let label = pending.note.title.isEmpty ? "Untitled" : pending.note.title
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                Text("Deleted \"\(label)\"")
                    .font(.callout)
                    .lineLimit(1)
                Button("Undo") {
                    viewModel.undoDelete()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // No timer here: the view model owns expiry. This used to run a
            // second, competing `Task.sleep` with no cancellation guard, so a
            // replacing delete resumed the cancelled task and instantly purged
            // the *new* note.
            .onHover { hovering in
                if hovering {
                    viewModel.pausePendingDeleteExpiry()
                } else {
                    viewModel.resumePendingDeleteExpiry()
                }
            }
        }
    }
}

// MARK: - Shared menu

struct DeckMenu: View {
    @ObservedObject var viewModel: DeckViewModel

    var body: some View {
        Button {
            Task { await viewModel.newNote() }
        } label: {
            Label("New Note", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: [.command, .option])

        Button {
            NotificationCenter.default.post(name: .openAllNotesRequested, object: nil)
        } label: {
            Label("All Notes", systemImage: "note.text")
        }
        .keyboardShortcut("a", modifiers: [.command, .option])

        Button {
            NotificationCenter.default.post(name: .openArchiveRequested, object: nil)
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .keyboardShortcut("l", modifiers: [.command, .option])

        Divider()

        Toggle("Show over full-screen apps", isOn: Binding(
            get: { AppSettings.showOverFullScreen },
            set: { AppSettings.showOverFullScreen = $0 }
        ))

        Picker("Deck edge", selection: Binding(
            get: { AppSettings.deckEdge },
            set: { AppSettings.deckEdge = $0 }
        )) {
            Text("Left").tag(AppSettings.Edge.left)
            Text("Right").tag(AppSettings.Edge.right)
        }
        .pickerStyle(.inline)

        Divider()

        Button {
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Aside", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Root

struct DeckView: View {
    @ObservedObject var viewModel: DeckViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRightEdge: Bool { viewModel.edge == .right }

    var body: some View {
        ZStack(alignment: isRightEdge ? .trailing : .leading) {
            if viewModel.state == .pill {
                PillSurface(
                    viewModel: viewModel,
                    height: DeckMetrics.pillHeight(
                        noteCount: viewModel.deckNotes.count,
                        maximumHeight: viewModel.panelHeight / 2
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: isRightEdge ? .trailing : .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .compositingGroup()
                .zIndex(0)
            } else {
                // Width is deliberately intrinsic — the fan's own column —
                // not `maxWidth: .infinity`. Combined with `contentShape`,
                // a full-panel frame laid a transparent hit-testable sheet
                // over the entire panel at zIndex 2, above the expanded
                // editor at zIndex 1: every click on the note card (both
                // close dots, Delete, Mark complete, Close, and the body)
                // was swallowed by the fan. Hovering the card still holds
                // the deck open through the editor layer's own onHover.
                FanView(viewModel: viewModel, selectedID: expandedID)
                    .frame(maxHeight: .infinity,
                           alignment: isRightEdge ? .trailing : .leading)
                    .contentShape(Rectangle())
                    .onHover { viewModel.deckHoverChanged($0) }
                    .zIndex(2)
            }

            // The real editor stays mounted and warm even while the panel is
            // dormant. Opening and closing are only rigid translations from
            // behind the physical screen edge.
            if let note = presentedNote {
                editorLayer(note: note, isActive: isExpanded)
                    .offset(x: isExpanded ? 0 : hiddenEditorOffset)
                    .offset(y: viewModel.cardOffsetY)
                    .animation(
                        DeckInteraction.noteMorphAnimation(reduceMotion: reduceMotion),
                        value: isExpanded
                    )
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
                    .contentShape(Rectangle())
                    .onHover { viewModel.deckHoverChanged($0) }
                    .zIndex(1)
            }

            VStack {
                Spacer()
                UndoToastView(viewModel: viewModel)
                    .padding(.bottom, 14)
            }
            .allowsHitTesting(viewModel.pendingDelete != nil)
            // Above the fan: the toast aligns to the same edge, so its Undo
            // button — the last item in its row — sits directly under the fan
            // column and was unreachable at a lower zIndex.
            .zIndex(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: isRightEdge ? .trailing : .leading)
        .contentShape(Rectangle())
        .contextMenu {
            if viewModel.state != .pill {
                DeckMenu(viewModel: viewModel)
            }
        }
        .animation(DeckInteraction.controlAnimation(reduceMotion: reduceMotion), value: viewModel.pendingDelete)
        .onChange(of: viewModel.state) { _, newState in
            if newState == .pill {
                DeckCursor.reset()
            }
        }
    }

    private func editorLayer(note: Note, isActive: Bool) -> some View {
        HStack(spacing: 0) {
            if isRightEdge { Spacer(minLength: 0) }
            if !isRightEdge {
                Color.clear.frame(width: DeckMetrics.fanPanelWidth() + DeckMetrics.noteGap)
            }
            ExpandedNoteView(viewModel: viewModel, note: note, isActive: isActive)
                .frame(width: DeckMetrics.noteWidth)
            if isRightEdge {
                Color.clear.frame(width: DeckMetrics.fanPanelWidth() + DeckMetrics.noteGap)
            }
            if !isRightEdge { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var presentedNote: Note? {
        guard let id = viewModel.presentedNoteID else { return nil }
        return viewModel.deckNotes.first(where: { $0.id == id })
    }

    private var isExpanded: Bool { expandedID != nil }

    private var hiddenEditorOffset: CGFloat {
        let distance = DeckMetrics.noteWidth
            + DeckMetrics.noteGap
            + DeckMetrics.fanPanelWidth()
            + 24
        return isRightEdge ? distance : -distance
    }

    private var expandedID: UUID? {
        if case .expanded(let id) = viewModel.state { return id }
        return nil
    }
}
