import CoreText
import Foundation
import SwiftUI

/// Loads the bundled OFL handwriting faces so they are available to both
/// `swift run` (via Bundle.module) and the .app bundle.
enum FontLoader {
    static func registerBundledFonts() {
        var directories: [URL] = []

        // Only touch Bundle.module when its resource bundle is actually
        // present — the generated accessor aborts the process otherwise.
        let moduleBundleName = "Aside_Aside.bundle"
        let moduleCandidates = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ].compactMap { $0 }

        for candidate in moduleCandidates {
            let bundleURL = candidate.appendingPathComponent(moduleBundleName)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else { continue }
            if let resourceURL = Bundle(url: bundleURL)?.resourceURL {
                directories.append(resourceURL.appendingPathComponent("Fonts"))
            }
        }

        if let fontsURL = Bundle.main.resourceURL?.appendingPathComponent("Fonts") {
            directories.append(fontsURL)
        }

        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

/// Shared visual language for note surfaces.
enum NoteTheme {
    static var bodyFont: Font {
        let name = AppSettings.noteFontName
        let size = AppSettings.noteFontSize
        guard !name.isEmpty else {
            return .system(size: size, weight: .regular, design: .rounded)
        }
        return .custom(name, size: size)
    }

    static var titleFont: Font {
        .system(size: 17, weight: .semibold, design: .rounded)
    }

    /// Solid pastel "paper" used by note cards (expanded editor, previews).
    static func cardBackground(_ color: NoteColor) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(color.fill)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.16), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            )
    }

    /// Warm paper tint used by list windows.
    static let paper = Color(red: 245 / 255, green: 244 / 255, blue: 237 / 255)
}
