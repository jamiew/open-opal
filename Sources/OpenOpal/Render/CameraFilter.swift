import Foundation

/// Built-in host-side effects, shared by the browser and renderer.
/// Artwork is procedural; these are not downloadable lenses or generated avatars.
enum CameraFilter: String, CaseIterable, Identifiable, Sendable {
    case none
    case cowboy
    case cat
    case beauty
    case monochrome
    case warm
    case pointCloud
    case glitch
    case anime
    case cyberWarrior
    case halftone
    case blueprint
    case thermal
    case pixelate
    case hologram
    case risograph
    case babyFace
    case animeFace
    case beard
    case glamHair
    case sunglasses
    case beardedCowboy

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case portrait
        case color
        case art
        case digital

        var id: String { rawValue }

        var title: String {
            switch self {
            case .portrait: "Portrait"
            case .color: "Color"
            case .art: "Art"
            case .digital: "Digital"
            }
        }
    }

    /// Stable renderer IDs, independent of catalog order and raw string identifiers.
    var shaderID: Int32 {
        switch self {
        case .none: 0
        case .cowboy: 1
        case .cat: 2
        case .beauty: 3
        case .monochrome: 4
        case .warm: 5
        case .pointCloud: 6
        case .glitch: 7
        case .anime: 8
        case .cyberWarrior: 9
        case .halftone: 10
        case .blueprint: 11
        case .thermal: 12
        case .pixelate: 13
        case .hologram: 14
        case .risograph: 15
        case .babyFace: 16
        case .animeFace: 17
        case .beard: 18
        case .glamHair: 19
        case .sunglasses: 20
        case .beardedCowboy: 21
        }
    }

    var category: Category {
        switch self {
        case .none, .cowboy, .cat, .beauty, .cyberWarrior: .portrait
        case .babyFace, .animeFace, .beard, .glamHair, .sunglasses, .beardedCowboy: .portrait
        case .monochrome, .warm, .thermal: .color
        case .anime, .halftone, .blueprint, .risograph: .art
        case .pointCloud, .glitch, .pixelate, .hologram: .digital
        }
    }

    var isAnimated: Bool {
        switch self {
        case .pointCloud, .glitch, .cyberWarrior, .hologram: true
        default: false
        }
    }

    /// None is a separate, always-available reset control rather than a search result.
    static func matching(query: String, category: Category? = nil) -> [CameraFilter] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.filter { filter in
            filter != .none
                && (category == nil || filter.category == category)
                && (query.isEmpty
                    || filter.title.localizedStandardContains(query)
                    || filter.detail.localizedStandardContains(query)
                    || filter.category.title.localizedStandardContains(query))
        }
    }

    var title: String {
        switch self {
        case .none: "None"
        case .cowboy: "Cowboy"
        case .cat: "Cat"
        case .beauty: "Beauty"
        case .monochrome: "Monochrome"
        case .warm: "Warm"
        case .pointCloud: "Point Cloud"
        case .glitch: "Glitch"
        case .anime: "Anime Ink"
        case .cyberWarrior: "Cyber Warrior"
        case .halftone: "Halftone"
        case .blueprint: "Blueprint"
        case .thermal: "Thermal"
        case .pixelate: "Pixel Art"
        case .hologram: "Hologram"
        case .risograph: "Risograph"
        case .babyFace: "Baby Face"
        case .animeFace: "Anime Face"
        case .beard: "Beard"
        case .glamHair: "Glam Hair"
        case .sunglasses: "Sunglasses"
        case .beardedCowboy: "Bearded Cowboy"
        }
    }

    var detail: String {
        switch self {
        case .none: "No filter. Your background and image settings still apply."
        case .cowboy: "An original illustrated cowboy hat that follows your face."
        case .cat: "Playful ears, a nose and whiskers. Not a full-face avatar."
        case .beauty: "Subtle softening around your face, leaving the rest of the image alone."
        case .monochrome: "A classic black-and-white grade across the whole image."
        case .warm: "A gentle golden warmth across the whole image."
        case .pointCloud: "A 2D dot visualization with luminous animated points. Not a 3D depth scan."
        case .glitch: "Animated digital distortion with RGB channel splits and broken scan lines."
        case .anime: "Cel shading and ink outlines for a cartoon look. Not a neural face replacement."
        case .cyberWarrior: "Original 2D cyber face armor with an animated visor and neon accents. Not a 3D avatar."
        case .halftone: "Comic-book print dots turn light and shadow into a graphic halftone pattern."
        case .blueprint: "Technical drawing edges and a drafting grid in blueprint blue."
        case .thermal: "A false-color heat-map palette based on image brightness. No temperature sensing."
        case .pixelate: "Chunky pixel blocks give the whole image a retro mosaic look."
        case .hologram: "A cyan sci-fi projection with animated scan lines and a luminous hologram glow."
        case .risograph: "Layered colored ink, paper grain and offset print texture inspired by risograph art."
        case .babyFace: "Bigger eyes, rounder cheeks and a smaller nose. A playful baby-face warp, not realistic de-aging."
        case .animeFace: "Enlarged eyes and face-local cel shading. A stylized anime portrait, not a generated character."
        case .beard: "An illustrated beard, mustache and sideburns that follow your face. For anyone."
        case .glamHair: "Long illustrated waves with caramel highlights. A 2D hairstyle, not a gender transformation."
        case .sunglasses: "Dark lenses, shaped rims and reflections anchored to your eyes."
        case .beardedCowboy: "A full illustrated beard and cowboy hat together in one face-tracked look."
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .cowboy: "sun.horizon"
        case .cat: "cat"
        case .beauty: "sparkles"
        case .monochrome: "circle.lefthalf.filled"
        case .warm: "sun.max"
        case .pointCloud: "circle.grid.3x3.fill"
        case .glitch: "waveform.path"
        case .anime: "pencil.tip.crop.circle"
        case .cyberWarrior: "shield.lefthalf.filled"
        case .halftone: "circle.dotted"
        case .blueprint: "ruler"
        case .thermal: "flame"
        case .pixelate: "square.grid.3x3.fill"
        case .hologram: "line.3.horizontal"
        case .risograph: "square.3.layers.3d"
        case .babyFace: "face.smiling"
        case .animeFace: "eyes"
        case .beard: "person.crop.square"
        case .glamHair: "person.crop.circle"
        case .sunglasses: "sunglasses"
        case .beardedCowboy: "sun.horizon"
        }
    }

    var requiresFace: Bool {
        switch self {
        case .cowboy, .cat, .beauty, .cyberWarrior: true
        case .babyFace, .animeFace, .beard, .glamHair, .sunglasses, .beardedCowboy: true
        default: false
        }
    }
}
