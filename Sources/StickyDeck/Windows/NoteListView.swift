import AppKit
import SwiftUI

/// The All Notes and Archive surfaces.
/// Row focus drives the preview; checkboxes are a separate bulk-selection
/// state and only replace the detail pane when two or more notes are checked.
struct NoteListView: View {
    enum Mode {
        case all
        case archive
    }

    @StateObject private var model: NoteListModel
    @State private var bulkExportShape: ExportShape = .markdownPerNote
    @FocusState private var focusedArea: FocusArea?
    @AccessibilityFocusState private var deleteToastAccessibilityFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var deleteToastHovered = false

    /// Not private: the preview card takes a binding to the same focus state
    /// so Return can move focus from the list into the note body.
    enum FocusArea: Hashable {
        case search
        case noteList
        case preview
    }

    init(store: any NoteStore, mode: Mode) {
        _model = StateObject(wrappedValue: NoteListModel(store: store, mode: mode))
    }

    var body: some View {
        NavigationSplitView {
            listPane
                .background(NoteTheme.paper)
                // Applied to the sidebar's own content: on the split view it
                // left the toggle button visible in the titlebar.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(
                    min: model.mode == .archive ? 320 : 360,
                    // NavigationSplitView adds eight points of internal
                    // chrome. These ideals land the visible dividers at the
                    // reference's x=348 / x=388 positions.
                    ideal: model.mode == .archive ? 340 : 380,
                    max: model.mode == .archive ? 380 : 420
                )
        } detail: {
            detailPane
        }
        .background(NoteTheme.paper)
        .task { await model.reload() }
        .onDisappear {
            model.flushAutosave()
            // A hovered toast pauses the Undo countdown. If the window closes
            // while it is paused nothing else would ever resume it, and the
            // batch would stay soft-deleted with no toast to undo it.
            model.resumePendingDeleteExpiry()
        }
        .onChange(of: model.pendingDelete?.id) { _, id in
            guard id != nil, let pending = model.pendingDelete else { return }
            announce(pending.notes.count == 1 ? "Deleted one note. Undo is available." : "Deleted \(pending.notes.count) notes. Undo is available.")
        }
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                primaryButton: .default(Text("Try Again")) { Task { await model.reload() } },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.mode == .archive ? "Archive" : "All Notes")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.73))
                Spacer()
                if model.mode == .all {
                    Button(action: importNotes) {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .padding(.bottom, 9)

            searchField

            if model.mode == .all {
                filterBar
            }

            if model.isLoading {
                ProgressView("Loading notes…")
                    .controlSize(.small)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading notes")
            } else if model.notes.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(model.notes) { note in
                                if model.mode == .all {
                                    SelectableNoteRow(
                                        note: note,
                                        isFocused: model.focusedID == note.id,
                                        isChecked: model.selection.contains(note.id),
                                        onFocus: { focus(note.id) },
                                        onToggle: { toggleChecked(note.id) }
                                    )
                                } else {
                                    ArchiveNoteRow(
                                        note: note,
                                        isFocused: model.focusedID == note.id,
                                        onFocus: { focus(note.id) }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .focusable()
                    // `focusable()` draws AppKit's system focus ring around
                    // the whole scroll view — a heavy accent rectangle over
                    // the entire pane on every row click. The region still
                    // takes focus (arrows, Home/End, Space all depend on it);
                    // only the ring is suppressed. The focused row's own
                    // highlight is what shows where focus is.
                    .focusEffectDisabled()
                    .focused($focusedArea, equals: .noteList)
                    .onMoveCommand { direction in
                        switch direction {
                        case .up: model.moveFocus(by: -1)
                        case .down: model.moveFocus(by: 1)
                        default: return
                        }
                    }
                    .onKeyPress(.space) {
                        // Archive rows have no checkboxes, so Space has to
                        // fall through to the list's page-scroll there.
                        model.toggleFocusedSelection() ? .handled : .ignored
                    }
                    // A source list is expected to answer more than the arrows:
                    // without these, Home/End/Page Up/Page Down scrolled the
                    // rows out from under a focus ring that never moved.
                    .onKeyPress(.home) {
                        model.moveFocusToFirst()
                        return .handled
                    }
                    .onKeyPress(.end) {
                        model.moveFocusToLast()
                        return .handled
                    }
                    .onKeyPress(.pageUp) {
                        model.moveFocus(by: -NoteListModel.pageLength)
                        return .handled
                    }
                    .onKeyPress(.pageDown) {
                        model.moveFocus(by: NoteListModel.pageLength)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        // Return opens the focused note where there is
                        // something to open: All Notes edits the body in the
                        // preview card, so focus moves there. Archive's preview
                        // is deliberately read-only, and the bulk pane replaces
                        // the card entirely, so in both cases Return is left
                        // alone rather than given an invented meaning — moving
                        // focus to an editor that is not on screen would only
                        // strip the list of its own focus.
                        guard model.mode == .all,
                              model.selectedNotes.count <= 1,
                              model.focusedNote != nil else { return .ignored }
                        focusedArea = .preview
                        return .handled
                    }
                    // Deliberately no focus ring around the whole list region.
                    // One was tried and it drew a heavy accent rectangle over
                    // the entire pane, empty space included, every time a row
                    // was clicked. The focused row's own highlight already
                    // says where focus is, which is what a native list does.
                    .onChange(of: model.focusedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let pending = model.pendingDelete {
                deleteToast(pending)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.black.opacity(0.28))
            TextField(
                model.mode == .archive ? "Search archived notes" : "Search all notes",
                text: $model.query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .rounded))
            .focused($focusedArea, equals: .search)
            .accessibilityLabel(model.mode == .archive ? "Search archive" : "Search all notes")
            .onExitCommand {
                if model.query.isEmpty {
                    focusedArea = .noteList
                } else {
                    model.query = ""
                }
            }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.black.opacity(0.25))
                        // The glyph alone is a 13x13 target, well under the
                        // 20x20 minimum. The shape grows into the empty gap at
                        // the field's trailing edge and the glyph stays
                        // trailing-aligned inside it, so the artwork keeps both
                        // its size and its position.
                        .frame(width: 22, height: 22, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear search")
            }

            Spacer(minLength: 4)
            Text(model.notes.count == 1 ? "1 note" : "\(model.notes.count) notes")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.black.opacity(0.36))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        // Same reason as the list's ring: the field is plain-styled, so
        // without this nothing on screen says the search field has focus.
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(focusedArea == .search ? 0.55 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 13)
        .padding(.bottom, model.mode == .archive ? 7 : 5)
        .background {
            Button("Search") { focusedArea = .search }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            filterButton("All", filter: .all)
            filterButton("Active", filter: .active)
            filterButton("Archived", filter: .archived)
            Spacer()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 4)
        .accessibilityRepresentation {
            Picker("Notes shown", selection: $model.filter) {
                Text("All").tag(NoteFilter.all)
                Text("Active").tag(NoteFilter.active)
                Text("Archived").tag(NoteFilter.archived)
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func filterButton(_ title: String, filter: NoteFilter) -> some View {
        Button(title) { model.filter = filter }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: model.filter == filter ? .semibold : .regular, design: .rounded))
            .foregroundStyle(.black.opacity(model.filter == filter ? 0.75 : 0.47))
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(model.filter == filter ? Color.black.opacity(0.065) : .clear)
            )
            .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: model.mode == .archive ? "archivebox" : "note.text")
                .font(.system(size: 28))
                .foregroundStyle(.black.opacity(0.18))
            Text(model.query.isEmpty
                 ? (model.mode == .archive ? "Nothing archived yet." : "No notes yet.")
                 : "No matching notes.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.black.opacity(0.42))
            Text(emptyStateHint)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.black.opacity(0.30))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyStateHint: String {
        if !model.query.isEmpty { return "Try a different search." }
        return model.mode == .archive
            ? "Completed notes appear here."
            : "Create a note from the menu bar or press ⌥⌘N."
    }

    private func focus(_ id: UUID) {
        model.focusedID = id
        focusedArea = .noteList
    }

    private func toggleChecked(_ id: UUID) {
        // Checking a row moves the focus onto it too, so the focus ring, the
        // preview and the action bar never point at a different note than the
        // one the user just ticked.
        focus(id)
        if model.selection.contains(id) {
            model.selection.remove(id)
        } else {
            model.selection.insert(id)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        // Counted over the visible notes: checks on rows hidden by the current
        // filter survive a reload, but they must not steer the pane.
        if model.mode == .all, model.selectedNotes.count > 1 {
            bulkSelectionPane
        } else {
            normalDetailPane
        }
    }

    private var normalDetailPane: some View {
        VStack(spacing: 0) {
            if let note = detailNote {
                normalActionBar(note)
                NotePreviewCard(
                    note: note,
                    showDates: model.mode == .all,
                    fillsAvailableHeight: model.mode == .archive,
                    focusArea: $focusedArea,
                    onEditBody: model.mode == .all
                        ? { edited in
                            var updated = note
                            updated.body = edited
                            model.autosave(updated)
                        }
                        : nil
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 28))
                        .foregroundStyle(.black.opacity(0.17))
                    Text("Select a note")
                        .foregroundStyle(.black.opacity(0.40))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Focus is authoritative for the preview. Preferring the checked note
    /// let the preview jump to row 9 while the focus ring stayed on row 1,
    /// silently retargeting the action bar with it.
    private var detailNote: Note? {
        model.focusedNote
    }

    private func normalActionBar(_ note: Note) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3)
                .fill(NoteColor.at(note.colorIndex).fill)
                .frame(width: 10, height: 10)
            Text(statusText(for: note))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .kerning(0.8)
                .foregroundStyle(.black.opacity(0.44))
                .lineLimit(2)
                // The label yields first; the buttons keep their full titles
                // rather than truncating to "Mark compl…".
                .layoutPriority(0)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Button(note.archivedAt == nil ? "Mark complete" : "Restore to deck") {
                Task { await model.setArchived([note.id], archived: note.archivedAt == nil) }
            }
            .buttonStyle(.bordered)
            .fixedSize()

            if model.mode == .all {
                Menu("Export…") {
                    Button("Markdown") { export([note], as: .markdownPerNote) }
                    Button("Plain text") { export([note], as: .textPerNote) }
                    Button("Single file") { export([note], as: .singleFile) }
                    Button("Sticky archive") { export([note], as: .stickyArchive) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button("Delete", role: .destructive) {
                Task { await model.deleteSelection([note.id]) }
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .frame(height: model.mode == .archive ? 64 : 58)
    }

    private func statusText(for note: Note) -> String {
        if let archivedAt = note.archivedAt {
            return "ARCHIVED \(archivedAt.formatted(.relative(presentation: .named)))".uppercased()
        }
        return "ACTIVE · IN\nTHE DECK"
    }

    // MARK: Bulk selection

    private var bulkSelectionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.selectedNotes.count) notes selected")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.67))
                Spacer()
                Button("Clear") { model.clearSelection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.black.opacity(0.42))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            selectedStack
                .padding(.leading, 20)
                .padding(.top, 14)

            Text("EXPORT AS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .kerning(1)
                .foregroundStyle(.black.opacity(0.38))
                .padding(.horizontal, 20)
                .padding(.top, 17)
                .padding(.bottom, 7)

            VStack(spacing: 3) {
                exportChoice(.markdownPerNote, title: "Markdown", detail: "— one .md file per note")
                exportChoice(.textPerNote, title: "Plain text", detail: "— one .txt file per note")
                exportChoice(.singleFile, title: "Single file", detail: "— all notes in one document")
                exportChoice(.stickyArchive, title: "Sticky archive", detail: "— .stickies — colors and dates kept")
            }
            .padding(.horizontal, 20)
            .accessibilityRepresentation {
                Picker("Export format", selection: $bulkExportShape) {
                    Text("Markdown, one file per note").tag(ExportShape.markdownPerNote)
                    Text("Plain text, one file per note").tag(ExportShape.textPerNote)
                    Text("Single file").tag(ExportShape.singleFile)
                    Text("Sticky archive, colors and dates kept").tag(ExportShape.stickyArchive)
                }
                .pickerStyle(.radioGroup)
            }

            Spacer()

            HStack(spacing: 9) {
                Button("Export \(model.selectedNotes.count) notes") {
                    export(model.selectedNotes, as: bulkExportShape)
                }
                .buttonStyle(.borderedProminent)
                .tint(NoteColor.amber.fill)
                .foregroundStyle(.black.opacity(0.74))

                Spacer()

                Button("Archive") {
                    Task { await model.setArchived(model.selection, archived: true) }
                }
                .buttonStyle(.bordered)
                Button("Delete", role: .destructive) {
                    Task { await model.deleteSelection(model.selection) }
                }
                .buttonStyle(.bordered)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(20)
        }
    }

    private var selectedStack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.selectedNotes.prefix(3).enumerated()).reversed(), id: \.element.id) { index, note in
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title.isEmpty ? "Untitled note" : note.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(note.body)
                        .font(.custom(AppSettings.noteFontName, size: 13))
                        .lineLimit(2)
                }
                .foregroundStyle(.black.opacity(0.72))
                .padding(10)
                .frame(width: 150, height: 72, alignment: .topLeading)
                .background(NoteColor.at(note.colorIndex).fill, in: RoundedRectangle(cornerRadius: 11))
                .shadow(color: .black.opacity(0.11), radius: 5, y: 2)
                .offset(x: CGFloat(index) * 11, y: CGFloat(index) * 5)
            }
        }
        .frame(width: 180, height: 86, alignment: .topLeading)
    }

    private func exportChoice(_ shape: ExportShape, title: String, detail: String) -> some View {
        Button {
            bulkExportShape = shape
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(bulkExportShape == shape ? NoteColor.amber.fill : .clear)
                    .overlay(Circle().stroke(.black.opacity(0.20), lineWidth: 1.2))
                    .overlay {
                        if bulkExportShape == shape {
                            Circle().fill(.black.opacity(0.45)).frame(width: 5, height: 5)
                        }
                    }
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.black.opacity(0.40))
                Spacer()
            }
            .foregroundStyle(.black.opacity(0.70))
            .padding(.horizontal, 10)
            .frame(height: 35)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(bulkExportShape == shape ? Color.black.opacity(0.055) : .clear)
            )
            // Both the glyph and the row background are `Color.clear` when the
            // choice is not selected, and clear fills take no clicks: only the
            // text was ever clickable. The shape makes the whole 35pt row the
            // target, as a radio row is expected to be.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Import, export, delete

    private func export(_ notes: [Note], as shape: ExportShape) {
        guard !notes.isEmpty else { return }
        Task { await TransferService.export(notes: notes, shape: shape) }
    }

    private func importNotes() {
        Task { await TransferService.importNotes(into: model.store) }
    }

    private func deleteToast(_ pending: NoteListModel.Delete) -> some View {
        HStack(spacing: 9) {
            Text(pending.notes.count == 1 ? "Deleted 1 note" : "Deleted \(pending.notes.count) notes")
            Button("Undo") { Task { await model.undoDelete() } }
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(.system(size: 12, design: .rounded))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            reduceTransparency ? NoteTheme.paper : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .background {
            if !reduceTransparency {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pending.notes.count == 1 ? "Deleted one note. Undo available." : "Deleted \(pending.notes.count) notes. Undo available.")
        .accessibilityFocused($deleteToastAccessibilityFocused)
        .onHover { hovering in
            deleteToastHovered = hovering
            updateDeleteFeedbackEngagement()
        }
        .onChange(of: deleteToastAccessibilityFocused) { _, _ in
            updateDeleteFeedbackEngagement()
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func updateDeleteFeedbackEngagement() {
        if deleteToastHovered || deleteToastAccessibilityFocused {
            model.pausePendingDeleteExpiry()
        } else {
            model.resumePendingDeleteExpiry()
        }
    }
}

// MARK: - Rows

struct SelectableNoteRow: View {
    let note: Note
    let isFocused: Bool
    let isChecked: Bool
    let onFocus: () -> Void
    let onToggle: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        // Spacing is one point tighter than the drawn gap because the checkbox
        // below claims a 20pt slot for its hit target; together they leave the
        // row's content exactly where it has always sat.
        HStack(spacing: 7) {
            Button(action: onToggle) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isChecked ? NoteColor.at(note.colorIndex).fill : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(.black.opacity(isChecked ? 0.08 : 0.20), lineWidth: 1.4)
                    )
                    .overlay {
                        if isChecked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black.opacity(0.58))
                        }
                    }
                    .frame(width: 19, height: 19)
                    // An unchecked box is filled with `Color.clear`, which takes
                    // no clicks: the click fell through to the row's own tap
                    // gesture, so a mouse user could never start a bulk
                    // selection. The shape also lifts the target to the 20x20
                    // minimum — leading-aligned in the wider slot so the drawn
                    // 19pt box does not move.
                    .frame(width: 20, height: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isChecked ? "Deselect note" : "Select note")
            .help(isChecked ? "Remove from selection" : "Add to selection")
            .accessibilityRepresentation {
                Toggle(
                    "Select \(note.title.isEmpty ? "Untitled note" : note.title)",
                    isOn: Binding(
                        get: { isChecked },
                        set: { newValue in
                            if newValue != isChecked { onToggle() }
                        }
                    )
                )
            }

            NoteRow(note: note)
        }
        .padding(.horizontal, 5)
        .frame(height: 58)
        .background(focusBackground)
        .overlay(focusOutline)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .id(note.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title.isEmpty ? "Untitled note" : note.title)
        .accessibilityValue(isChecked ? "Selected for bulk actions" : "Not selected for bulk actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onFocus() }
    }

    private var selection: RowSelection {
        RowSelection(isFocused: isFocused, contrast: contrast, activeState: activeState)
    }

    private var focusBackground: some View {
        RoundedRectangle(cornerRadius: 8).fill(selection.fill)
    }

    private var focusOutline: some View {
        RoundedRectangle(cornerRadius: 8).stroke(selection.outline, lineWidth: 1)
    }
}

/// The focused row's appearance. Native lists show a dimmed, unaccented
/// selection while their window is not key; this list drew the same strong
/// highlight in front and background windows, so a stack of them all looked
/// equally active. Both row kinds share it so they cannot drift apart.
private struct RowSelection {
    let isFocused: Bool
    let contrast: ColorSchemeContrast
    let activeState: ControlActiveState

    private var isKey: Bool { activeState == .key }

    var fill: Color {
        guard isFocused else { return .clear }
        if contrast == .increased { return .black.opacity(isKey ? 0.10 : 0.06) }
        return .black.opacity(isKey ? 0.052 : 0.030)
    }

    var outline: Color {
        guard isFocused else { return .clear }
        return isKey ? Color.accentColor.opacity(0.28) : Color.black.opacity(0.12)
    }
}

struct ArchiveNoteRow: View {
    let note: Note
    let isFocused: Bool
    let onFocus: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let selection = RowSelection(isFocused: isFocused, contrast: contrast, activeState: activeState)
        return NoteRow(note: note, showsState: false)
            .padding(.horizontal, 8)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 8).fill(selection.fill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection.outline, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocus)
            .id(note.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(note.title.isEmpty ? "Untitled archived note" : note.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onFocus() }
    }
}

struct NoteRow: View {
    let note: Note
    var showsState = true

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(NoteColor.at(note.colorIndex).fill)
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled note" : note.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.75))
                    .lineLimit(1)
                Text(note.body.isEmpty ? "Empty note" : note.body.replacingOccurrences(of: "\n", with: "  "))
                    .font(.custom(AppSettings.noteFontName, size: 14))
                    .foregroundStyle(.black.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 5)

            VStack(alignment: .trailing, spacing: 3) {
                if showsState {
                    Text(note.archivedAt == nil ? "ACTIVE" : "ARCHIVED")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .kerning(0.6)
                        .foregroundStyle(.black.opacity(0.42))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                }
                Text(note.updatedAt, style: .relative)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.black.opacity(0.34))
            }
        }
    }
}

// MARK: - Preview card

struct NotePreviewCard: View {
    let note: Note
    let showDates: Bool
    let fillsAvailableHeight: Bool
    /// The window's shared focus state, so Return in the list can open this
    /// note's body for editing and Escape can hand focus back.
    var focusArea: FocusState<NoteListView.FocusArea?>.Binding
    /// `nil` makes the card read-only. Archive passes nothing — its detail
    /// surface is deliberately read-only. All Notes passes a handler so a typo
    /// can be fixed where it is read.
    var onEditBody: ((String) -> Void)?

    @State private var draft: String = ""
    /// The body as it stood when the draft was last loaded, so an unsaved
    /// local edit can be told apart from an untouched draft.
    @State private var baseline: String = ""
    /// True while `loadDraft` assigns, so its own write to `draft` is not
    /// mistaken for typing and echoed straight back to the store.
    @State private var isLoadingDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title.isEmpty ? "Untitled note" : note.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.78))
                    .lineLimit(1)
                Spacer()
                Text("edited ") + Text(note.updatedAt, format: .dateTime.day().month(.abbreviated))
            }
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(.black.opacity(0.37))
            .padding(.horizontal, 20)
            .padding(.top, 17)

            if let onEditBody {
                // TextEditor scrolls itself, so no ScrollView here. Its own
                // ~4 pt text container inset is subtracted from the padding so
                // the text sits on the same line as the read-only rendering.
                TextEditor(text: $draft)
                    .font(NoteTheme.bodyFont)
                    .foregroundStyle(.black.opacity(0.75))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .accessibilityLabel("Note body")
                    .focused(focusArea, equals: .preview)
                    // Return moved focus in here, so Escape has to be able to
                    // move it back out — otherwise the editor is a keyboard trap.
                    .onExitCommand { focusArea.wrappedValue = .noteList }
                    .onAppear(perform: loadDraft)
                    .onChange(of: note.id) { loadDraft() }
                    .onChange(of: note.body) { adoptExternalBodyIfSafe() }
                    .onChange(of: draft) {
                        guard !isLoadingDraft else { return }
                        onEditBody(draft)
                    }
            } else {
                ScrollView {
                    Text(note.body)
                        .font(NoteTheme.bodyFont)
                        .foregroundStyle(.black.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
            }

            if showDates {
                Divider().opacity(0.14).padding(.horizontal, 20)
                (Text("Created ") + Text(note.createdAt, format: .dateTime.day().month(.abbreviated).year())
                 + Text(" · Updated ") + Text(note.updatedAt, style: .relative))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.black.opacity(0.38))
                    .padding(.horizontal, 20)
                    .frame(height: 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
        .frame(height: fillsAvailableHeight ? nil : 336)
        .background(NoteColor.at(note.colorIndex).fill)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.11), radius: 12, y: 5)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .id(note.id)
    }

    private func loadDraft() {
        isLoadingDraft = true
        draft = note.body
        baseline = note.body
        // Let this run loop's onChange callbacks settle before re-arming the
        // save, or the assignment above is read back as user input.
        DispatchQueue.main.async { isLoadingDraft = false }
    }

    /// Picks up an edit made elsewhere (the deck editor, a sticky window,
    /// another Mac) without ever discarding unsaved local typing.
    private func adoptExternalBodyIfSafe() {
        // Our own save echoing back: nothing to adopt, just re-baseline.
        if note.body == draft {
            baseline = note.body
            return
        }
        // Unsaved local edits win — the user is mid-sentence.
        if draft != baseline { return }
        loadDraft()
    }
}
