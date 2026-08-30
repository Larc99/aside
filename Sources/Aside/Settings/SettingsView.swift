import SwiftUI
import Combine

/// Refreshes the settings UI when settings change elsewhere (status item,
/// pill context menu) while the window is open. Values themselves are read
/// from / written through `AppSettings`, so there is a single source of truth.
@MainActor
final class SettingsModel: ObservableObject {
    private var cancellable: AnyCancellable?

    init() {
        cancellable = NotificationCenter.default.publisher(for: .appSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

struct SettingsView: View {
    @ObservedObject private var model = SettingsModel()
    @State private var selectedPane: Pane = .general
    @State private var confirmsStoppingSync = false
    @State private var folderError: String?

    private enum Pane: Hashable {
        case general
        case advanced
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .tabItem { Label("General", systemImage: "macwindow") }
                .tag(Pane.general)

            advancedPane
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
                .tag(Pane.advanced)
        }
        .padding(.top, 8)
        .frame(width: 460, height: 430)
        .confirmationDialog(
            "Stop syncing this folder?",
            isPresented: $confirmsStoppingSync
        ) {
            Button("Stop Syncing", role: .destructive) {
                AppSettings.syncFolderBookmark = nil
                AppSettings.syncFolderName = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your notes remain in the folder. New changes will be stored on this Mac only.")
        }
        // A sheet on the Settings window rather than `NSAlert.runModal()`:
        // this app is LSUIElement, so an app-modal alert can end up behind the
        // frontmost app with the whole app blocked behind it, and the failure
        // belongs to the window the user is working in anyway.
        .alert(
            "Could not use that folder",
            isPresented: Binding(
                get: { folderError != nil },
                set: { if !$0 { folderError = nil } }
            ),
            presenting: folderError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var generalPane: some View {
        Form {
            Section("Deck") {
                Picker("Screen side", selection: edgeBinding) {
                    Text("Left").tag(AppSettings.Edge.left)
                    Text("Right").tag(AppSettings.Edge.right)
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Moves the note deck to the chosen screen edge")

                LabeledContent("Open the deck") {
                    Text("Move the pointer to the screen edge")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keyboard Shortcuts") {
                ShortcutRow(title: "New note", keys: "⌥⌘N", isAvailable: isAvailable(HotKeyID.newNote))
                ShortcutRow(title: "All Notes", keys: "⌥⌘A", isAvailable: isAvailable(HotKeyID.allNotes))
                ShortcutRow(title: "Archive", keys: "⌥⌘L", isAvailable: isAvailable(HotKeyID.archive))
            }
        }
        .formStyle(.grouped)
    }

    private var advancedPane: some View {
        Form {
            Section("Deck Behavior") {
                Picker("Animation speed", selection: speedBinding) {
                    Text("Brisk").tag(AppSettings.AnimationSpeed.brisk)
                    Text("Normal").tag(AppSettings.AnimationSpeed.normal)
                    Text("Gentle").tag(AppSettings.AnimationSpeed.gentle)
                }
                .pickerStyle(.segmented)

                Toggle("Show over full-screen apps", isOn: fullscreenBinding)
                    .accessibilityHint("Allows the edge deck to appear above full-screen windows")
            }

            Section("Note Typography") {
                Picker("Typeface", selection: fontNameBinding) {
                    ForEach(SettingsView.fontOptions, id: \.family) { option in
                        Text(option.label).tag(option.family)
                    }
                }

                Stepper("Size: \(Int(fontSizeBinding.wrappedValue)) pt", value: fontSizeBinding, in: 10...32)

                Text("Hover the edge to fan out your notes")
                    .font(previewFont)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Note font preview")
            }

            Section("Storage & Sync") {
                LabeledContent("Location") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(syncFolderLabel)
                            .lineLimit(1)
                        Text(syncFolderHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                HStack {
                    Button("Choose Folder…") {
                        Task { await chooseSyncFolder() }
                    }

                    Spacer()

                    Button("Stop Syncing", role: .destructive) {
                        confirmsStoppingSync = true
                    }
                    .disabled(AppSettings.syncFolderBookmark == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Keyboard shortcuts

    /// Carbon refuses a hotkey another app already owns, and that failure is
    /// permanent for the session. Say so rather than advertise a dead key.
    private func isAvailable(_ id: UInt32) -> Bool {
        !HotKeyCenter.unavailableStandardIDs.contains(id)
    }

    // MARK: - Bindings (write through to AppSettings)

    private var edgeBinding: Binding<AppSettings.Edge> {
        Binding(get: { AppSettings.deckEdge }, set: { AppSettings.deckEdge = $0 })
    }

    private var speedBinding: Binding<AppSettings.AnimationSpeed> {
        Binding(get: { AppSettings.animationSpeed }, set: { AppSettings.animationSpeed = $0 })
    }

    private var fullscreenBinding: Binding<Bool> {
        Binding(get: { AppSettings.showOverFullScreen }, set: { AppSettings.showOverFullScreen = $0 })
    }

    private var fontNameBinding: Binding<String> {
        Binding(get: { AppSettings.noteFontName }, set: { AppSettings.noteFontName = $0 })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { AppSettings.noteFontSize }, set: { AppSettings.noteFontSize = $0 })
    }

    // MARK: - Sync folder

    private var syncFolderLabel: String {
        let name = AppSettings.syncFolderName
        return name.isEmpty ? "This Mac only" : name
    }

    private var syncFolderHint: String {
        AppSettings.syncFolderBookmark == nil
            ? "Encrypted on this Mac"
            : "Markdown files"
    }

    private func chooseSyncFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to sync notes through (e.g. iCloud Drive)"
        panel.prompt = "Sync Here"

        guard let url = await withCheckedContinuation({ continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }) else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            AppSettings.syncFolderBookmark = bookmark
            AppSettings.syncFolderName = url.lastPathComponent
        } catch {
            folderError = error.localizedDescription
        }
    }

    // MARK: - Font options

    /// Empty family string = the system rounded face (AppSettings contract:
    /// empty `noteFontName` means system rounded). Bundled OFL fonts appear
    /// automatically once they are installed into Resources/Fonts.
    private static let fontOptions: [(family: String, label: String)] = {
        var options = [(family: "", label: "System Rounded")]
        let candidates = ["Caveat", "Comic Neue", "Nunito", "Cascadia Code", "Excalifont"]
        for family in candidates where NSFont(name: family, size: 13) != nil {
            options.append((family: family, label: family))
        }
        return options
    }()

    private var previewFont: Font {
        let name = AppSettings.noteFontName
        let size = AppSettings.noteFontSize
        guard !name.isEmpty, NSFont(name: name, size: size) != nil else {
            return .system(size: size, weight: .regular, design: .rounded)
        }
        return .custom(name, size: size)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: String
    var isAvailable = true

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(keys)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(isAvailable ? .secondary : .tertiary)
                    .accessibilityLabel(keys.accessibilityShortcutDescription)
                if !isAvailable {
                    Text("Unavailable — another app is using this shortcut")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

private extension String {
    var accessibilityShortcutDescription: String {
        replacingOccurrences(of: "⌥", with: "Option ")
            .replacingOccurrences(of: "⌘", with: "Command ")
    }
}
