import AppKit
import CryptoKit
import ServiceManagement
import SwiftUI

/// Four-step first-run walkthrough matching the reference flow. A welcome
/// note is seeded behind the walkthrough; the final action creates and opens
/// a separate blank note in the edge editor.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private let store: any NoteStore
    private let onCreateNewNote: () -> Void
    private let defaults: UserDefaults
    private var window: NSWindow?
    private var backingObservationTask: Task<Void, Never>?
    private var seedTask: Task<Void, Never>?
    private var seedGeneration = 0

    private static let completedKey = "onboardingCompleted"
    /// Libraries that have been seen holding at least one note. Keyed per
    /// library rather than per user: the walkthrough is a once-per-user event,
    /// but seeding follows the library (D24).
    private static let knownLibrariesKey = "seededLibraryKeys"

    init(
        store: any NoteStore,
        onCreateNewNote: @escaping () -> Void,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.onCreateNewNote = onCreateNewNote
        self.defaults = defaults
    }

    /// Identifies the library the store is currently backed by, so the marker
    /// travels with the library and not with the user. The bookmark is the
    /// authoritative identity of a sync folder; hashing keeps an opaque,
    /// launch-stable key out of the defaults plist (`hashValue` is seeded per
    /// process and would change every launch).
    private static var libraryKey: String {
        guard let bookmark = AppSettings.syncFolderBookmark else { return "local" }
        let digest = SHA256.hash(data: bookmark)
        return "sync:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private var knownLibraries: Set<String> {
        Set(defaults.stringArray(forKey: Self.knownLibrariesKey) ?? [])
    }

    private func rememberLibrary(_ key: String) {
        var known = knownLibraries
        guard known.insert(key).inserted else { return }
        defaults.set(Array(known), forKey: Self.knownLibrariesKey)
    }

    func install() {
        if !defaults.bool(forKey: Self.completedKey) {
            show()
        }
        scheduleWelcomeSeed()
        backingObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .noteStoreBackingChanged) {
                self?.scheduleWelcomeSeed()
            }
        }
    }

    deinit {
        backingObservationTask?.cancel()
        seedTask?.cancel()
    }

    private func scheduleWelcomeSeed() {
        seedGeneration &+= 1
        let generation = seedGeneration
        let prior = seedTask
        seedTask = Task { [weak self] in
            await prior?.value
            guard let self, generation == self.seedGeneration else { return }
            await self.seedWelcomeNoteIfLibraryIsNew()
            if generation == self.seedGeneration {
                self.seedTask = nil
            }
        }
    }

    /// Storage transitions wait for the outgoing library's emptiness check and
    /// optional seed write. This keeps the check and write on one backing.
    func flushPendingWork() async {
        while let task = seedTask {
            await task.value
        }
    }

    var hasPendingWork: Bool { seedTask != nil }

    func refreshActiveLibrary() async {
        scheduleWelcomeSeed()
        await flushPendingWork()
    }

    /// Seeds the welcome note when the *store* has nothing in it, not when a
    /// global `UserDefaults` flag says we have never seeded. The flag and the
    /// library disagree the moment the library changes underneath it: pointing
    /// StickyDeck at a fresh sync folder (D24: separate libraries, no
    /// migration) left the user with a blank deck, no welcome note and no way
    /// to ask for one. The walkthrough itself is not re-shown — that is still
    /// a once-per-user event.
    ///
    /// The emptiness test is `allKnownIDs`, which counts archived and
    /// soft-deleted rows too. That alone is not enough to tell a never-used
    /// library from a deliberately emptied one: tombstones are purged ten
    /// seconds after the last delete (or on quit), so a user who clears the
    /// deck and relaunches met an empty library and got the welcome note
    /// handed back. Every library seen holding a note is therefore recorded,
    /// and a recorded library is never seeded again however empty it becomes.
    private func seedWelcomeNoteIfLibraryIsNew() async {
        let library = Self.libraryKey
        guard !knownLibraries.contains(library) else { return }

        let isEmpty: Bool
        do {
            isEmpty = try await store.allKnownIDs().isEmpty
        } catch {
            // Could not tell — an unreadable store would only be made worse by
            // writing into it. The next launch retries.
            NSLog("StickyDeck could not check the library before seeding: %@", error.localizedDescription)
            return
        }
        guard isEmpty else {
            rememberLibrary(library)
            return
        }
        await seedWelcomeNote(library: library)
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 436),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // A one-time splash drawn on pastel note paper, like the deck itself.
        window.appearance = NSAppearance(named: .aqua)

        window.contentView = NSHostingView(
            rootView: OnboardingView(
                edgeLabel: Self.edgeLabel,
                onCreate: { [weak self] addToLoginItems in
                    self?.setLaunchAtLogin(addToLoginItems)
                    self?.complete()
                    self?.window?.orderOut(nil)
                    self?.onCreateNewNote()
                },
                onDismiss: { [weak self] in
                    self?.complete()
                    self?.window?.orderOut(nil)
                }
            )
        )
        window.delegate = self
        return window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { complete() }
    }

    private func complete() {
        defaults.set(true, forKey: Self.completedKey)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Launch-at-login is optional. Ad-hoc/debug builds may not be in
            // an install location where ServiceManagement can register them.
            NSLog("StickyDeck could not update Login Items: %@", error.localizedDescription)
        }
    }

    private static var edgeLabel: String {
        AppSettings.deckEdge == .right ? "right" : "left"
    }

    private func seedWelcomeNote(library: String) async {
        let note = Note(
            title: "Getting started",
            body: """
            Hover the \(Self.edgeLabel) edge of the screen to open your deck.

            - Click a card to open it
            - Drag an open note up / down to reposition it
            - Pin a note to keep it on your desktop
            - ⌥⌘N makes a new note
            - ⌥⌘A lists all notes, ⌥⌘L opens the archive

            Replace this with your first note.
            """,
            colorIndex: NoteColor.amber.rawValue,
            tag: "getting-started"
        )
        do {
            try await store.upsert(note)
            rememberLibrary(library)
        } catch {
            // Deliberately not recorded: the store is still empty, so the next
            // launch simply tries again.
            NSLog("StickyDeck could not seed the welcome note: %@", error.localizedDescription)
        }
    }
}

struct OnboardingView: View {
    let edgeLabel: String
    let onCreate: (Bool) -> Void
    let onDismiss: () -> Void

    @State private var step = 0
    @State private var addToLoginItems = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pages: [OnboardingPage] { [
        OnboardingPage(
            title: "One stripe per note,\nand nothing else",
            body: "A thin strip on the \(edgeLabel) edge of your screen is all you see. Each stripe is a note, in its own color, so you can tell what is there at a glance.",
            key: "Nothing to click",
            hint: "the pill sits out of the way until\nyou need it"
        ),
        OnboardingPage(
            title: "Reach over and the\ndeck fans out",
            body: "Bring the pointer to the \(edgeLabel) edge and the notes slide out as a stack. Hover one and it lifts forward so you can read it without opening anything.",
            key: edgeLabel == "right" ? "→ right edge" : "left edge ←",
            hint: "no click, no keyboard"
        ),
        OnboardingPage(
            title: "Open one and\nstart typing",
            body: "The note grows into an editor in place. Type and it saves as you go — no save button, no window to manage. Pick a color from the row along the bottom.",
            key: "⌥⌘N",
            hint: "creates a new note from anywhere"
        ),
        OnboardingPage(
            title: "Finished notes step\nout of the way",
            body: "Archived notes leave the deck but are kept. Search the archive by title or by anything written inside a note, then restore it to the deck in one click.",
            key: "⌥⌘L",
            hint: "opens the archive"
        ),
    ] }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 375)
            OnboardingMiniature(step: step, edgeLabel: edgeLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NoteTheme.paper)
        .frame(minWidth: 780, minHeight: 436)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STEP \(step + 1) OF 4")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .kerning(1.2)
                .foregroundStyle(.black.opacity(0.38))
                .padding(.top, 61)

            Text(pages[step].title)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.black.opacity(0.84))
                .lineSpacing(5)
                .padding(.top, 16)

            Text(pages[step].body)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.black.opacity(0.58))
                .lineSpacing(8)
                .padding(.top, 13)

            HStack(spacing: 9) {
                Text(pages[step].key)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.50))
                    .padding(.horizontal, 10)
                    .frame(height: 29)
                    .background(.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                Text(pages[step].hint)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.black.opacity(0.40))
            }
            .padding(.top, 15)

            Spacer()

            if step == 3 {
                Toggle(isOn: $addToLoginItems) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add to Login Items")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text("open automatically at sign-in")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.black.opacity(0.38))
                    }
                }
                .toggleStyle(.checkbox)
                .padding(10)
                .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                .padding(.bottom, 15)
            }

            HStack {
                // Hit area only. Each dot keeps its drawn size (6 pt tall,
                // 22/6 pt wide) and the row keeps its 7 pt pitch: the cell
                // swallows the gap (Self.dotGap, halved on each side and
                // cancelled by the negative padding below) and grows to
                // Self.dotHitHeight, which fits inside the 36 pt button row so
                // nothing around it moves either. Width stops at the gap
                // because four 20 pt-wide targets do not fit in a 61 pt row —
                // claiming more would move artwork, so height carries the
                // target to Apple's 28 pt.
                HStack(spacing: 0) {
                    ForEach(0..<4) { index in
                        Button { changeStep(to: index) } label: {
                            Capsule()
                                .fill(.black.opacity(index == step ? 0.55 : 0.16))
                                .frame(width: Self.dotWidth(current: index == step), height: 6)
                                .frame(
                                    width: Self.dotWidth(current: index == step) + Self.dotGap,
                                    height: Self.dotHitHeight
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Go to step \(index + 1)")
                    }
                }
                .padding(.horizontal, -Self.dotGap / 2)

                Spacer()

                if step < 3 {
                    Button("Skip", action: onDismiss)
                        .buttonStyle(.plain)
                        .foregroundStyle(.black.opacity(0.42))
                        .keyboardShortcut(.cancelAction)
                        .help("Skip Introduction")
                    Button("Continue") { changeStep(to: step + 1) }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Make my first note") { onCreate(addToLoginItems) }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 26)
    }

    // Step-dot geometry (drawn size and spacing) plus the hit height.
    static let dotGap: CGFloat = 7
    static let dotHitHeight: CGFloat = 28

    static func dotWidth(current: Bool) -> CGFloat { current ? 22 : 6 }

    private func changeStep(to newStep: Int) {
        let clamped = min(max(newStep, 0), pages.count - 1)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            step = clamped
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Step \(clamped + 1) of \(pages.count): \(pages[clamped].title.replacingOccurrences(of: "\n", with: " "))",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

private struct OnboardingPage {
    let title: String
    let body: String
    let key: String
    let hint: String
}

private struct OnboardingMiniature: View {
    let step: Int
    let edgeLabel: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.43, green: 0.78, blue: 0.80),
                         Color(red: 0.04, green: 0.35, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            switch step {
            case 0: miniPill
            case 1: miniFan
            case 2: miniEditor
            default: miniArchive
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 15))
        .accessibilityHidden(true)
    }

    private var miniPill: some View {
        HStack {
            if edgeLabel == "right" { Spacer() }
            VStack(spacing: 3) {
                ForEach(NoteColor.allCases.prefix(4), id: \.self) { color in
                    Capsule().fill(color.fill).frame(width: 4, height: 9)
                }
            }
            .padding(4)
            .background(.black.opacity(0.42), in: Capsule())
            if edgeLabel == "left" { Spacer() }
        }
    }

    private var miniFan: some View {
        ZStack(alignment: edgeLabel == "right" ? .trailing : .leading) {
            ForEach(Array(NoteColor.allCases.prefix(4).enumerated()), id: \.offset) { index, color in
                HStack(spacing: 0) {
                    Text(["ALICE", "BOOKS", "Q3", "SPRINT"][index])
                        .font(.system(size: 6, weight: .semibold, design: .rounded))
                        .kerning(0.7)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 28)
                    if index == 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Call w/ Alice").font(.system(size: 12, weight: .bold))
                            Text("Budget approval — send the deck before Thursday.")
                                .font(.custom(AppSettings.noteFontName, size: 12))
                        }
                        .padding(10)
                    }
                }
                .frame(width: index == 0 ? 210 : 42, height: 122)
                .background(color.fill, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14))
                .shadow(color: .black.opacity(0.16), radius: 9, x: -4, y: 4)
                .offset(y: CGFloat(index - 1) * 62)
            }
        }
    }

    private var miniEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(.black.opacity(0.20)).frame(width: 6, height: 6)
                Text("Sprint 24").font(.system(size: 10, weight: .bold))
                Spacer()
                Text("Saved").font(.system(size: 7)).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider().opacity(0.15)
            Text("Cut the onboarding modal, ship search first.")
                .font(.custom(AppSettings.noteFontName, size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            HStack(spacing: 5) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    RoundedRectangle(cornerRadius: 3).fill(color.fill).frame(width: 13, height: 13)
                }
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 212, height: 214)
        .background(NoteColor.amber.fill, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.17), radius: 10, y: 4)
    }

    private var miniArchive: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                Text("⌕ Search").foregroundStyle(.secondary)
                ForEach(["Q2 retro", "Lisbon", "Sourdough", "Interview", "Reading"], id: \.self) {
                    Text($0).font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 105)
            .background(NoteTheme.paper)

            VStack(alignment: .leading, spacing: 6) {
                Text("Q2 retro notes").font(.system(size: 12, weight: .bold))
                Text("Velocity was fine, review load was not. Two people carried most reviews — rotate weekly.")
                    .font(.custom(AppSettings.noteFontName, size: 13))
                Spacer()
            }
            .padding(12)
            .background(NoteColor.amber.fill)
        }
        .frame(width: 285, height: 245)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .shadow(color: .black.opacity(0.17), radius: 10, y: 4)
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black.opacity(0.72))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(NoteColor.amber.fill.opacity(configuration.isPressed ? 0.78 : 1))
                    .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
            )
    }
}
