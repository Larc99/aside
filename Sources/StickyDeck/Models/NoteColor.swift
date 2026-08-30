import SwiftUI

enum NoteColor: Int, CaseIterable, Sendable {
    // Raw values 0...3 deliberately preserve the colors used by earlier
    // StickyDeck builds. Coral takes the former peach slot, so existing note
    // libraries keep their closest visual color without a data migration.
    case amber = 0
    case mint = 1
    case sky = 2
    case lilac = 3
    case coral = 4

    /// The swatch order the editor presents, left to right.
    static let allCases: [NoteColor] = [.amber, .coral, .mint, .sky, .lilac]

    var name: String {
        switch self {
        case .amber: return "Amber"
        case .coral: return "Coral"
        case .mint: return "Mint"
        case .sky: return "Sky"
        case .lilac: return "Lilac"
        }
    }

    var fill: Color {
        switch self {
        // Sampled from the center of each live v1.0.5 editor surface.
        case .amber: return Color(red: 251 / 255, green: 223 / 255, blue: 138 / 255)
        case .coral: return Color(red: 242 / 255, green: 177 / 255, blue: 148 / 255)
        case .mint: return Color(red: 192 / 255, green: 232 / 255, blue: 216 / 255)
        case .sky: return Color(red: 192 / 255, green: 222 / 255, blue: 251 / 255)
        case .lilac: return Color(red: 222 / 255, green: 213 / 255, blue: 249 / 255)
        }
    }

    var dash: Color {
        // The reference pill uses the same pastel paper colors.
        fill
    }

    var next: NoteColor {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return Self.allCases[(index + 1) % Self.allCases.count]
    }

    static func at(_ index: Int) -> NoteColor {
        if let exact = NoteColor(rawValue: index) { return exact }
        let normalized = ((index % NoteColor.allCases.count) + NoteColor.allCases.count) % NoteColor.allCases.count
        return NoteColor.allCases[normalized]
    }
}
