import AppKit
import SwiftUI
import SidekickCore

/// Render `AppIcon.iconset` at every size macOS expects, from a SwiftUI view.
/// Same pattern as Clonk/FileDen — `make icon` calls `Sidekick --icon <dir>`
/// to materialise the PNGs which `iconutil` then bundles into an `.icns`.
///
/// The icon design (per the icon design system memo): a full-bleed continuous
/// squircle at corner ratio 0.2237, two interlocking rectangles for "screens",
/// no inset. Refine the artwork later — the renderer just needs *some* shape
/// to ship.
@MainActor
enum AppIconRenderer {
    static func run(directory path: String) {
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(name: String, px: Int)] = [
            ("icon_16x16",       16),  ("icon_16x16@2x",       32),
            ("icon_32x32",       32),  ("icon_32x32@2x",       64),
            ("icon_128x128",    128),  ("icon_128x128@2x",    256),
            ("icon_256x256",    256),  ("icon_256x256@2x",    512),
            ("icon_512x512",    512),  ("icon_512x512@2x",   1024),
        ]
        for (name, px) in sizes {
            let url = dir.appendingPathComponent("\(name).png")
            render(size: px, to: url)
        }
        // Gallery copies: 512px for appstage/README, 1024px for iOS AppIcon.
        render(size: 512,  to: dir.appendingPathComponent("../icon-512.png"))
        render(size: 1024, to: dir.appendingPathComponent("../icon-1024.png"))
    }

    private static func render(size: Int, to url: URL) {
        let view = AppIconArtwork()
            .frame(width: CGFloat(size), height: CGFloat(size))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: size, height: size)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}

/// Sidekick icon: a Mac screen and an iPhone, linked by a glowing cursor.
/// Dark navy → indigo background; electric teal/violet cursor accent.
private struct AppIconArtwork: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Background: very dark navy → deep indigo-purple
                RoundedRectangle(cornerRadius: s * 0.2237, style: .continuous)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.027, green: 0.063, blue: 0.118),
                            Color(red: 0.067, green: 0.035, blue: 0.294),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                // Ambient inner glow (upper-left)
                RoundedRectangle(cornerRadius: s * 0.2237, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Color(red: 0.13, green: 0.45, blue: 0.88).opacity(0.20), .clear],
                        center: UnitPoint(x: 0.30, y: 0.28),
                        startRadius: 0,
                        endRadius: s * 0.58
                    ))

                // Mac screen (landscape) — upper-left anchor
                RoundedRectangle(cornerRadius: s * 0.042, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .frame(width: s * 0.50, height: s * 0.34)
                    .offset(x: -s * 0.08, y: -s * 0.09)

                // iPhone (portrait) — lower-right, overlaps Mac screen corner
                RoundedRectangle(cornerRadius: s * 0.056, style: .continuous)
                    .fill(.white.opacity(0.68))
                    .frame(width: s * 0.22, height: s * 0.40)
                    .offset(x: s * 0.20, y: s * 0.11)

                // Cursor arrow: electric teal → violet, centred at the junction
                Image(systemName: "cursorarrow")
                    .font(.system(size: s * 0.19, weight: .regular))
                    .foregroundStyle(LinearGradient(
                        colors: [
                            Color(red: 0.208, green: 0.753, blue: 1.000),
                            Color(red: 0.424, green: 0.314, blue: 1.000),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .shadow(color: Color(red: 0.208, green: 0.753, blue: 1.0).opacity(0.80), radius: s * 0.04)
                    .offset(x: s * 0.04, y: s * 0.04)
            }
            .frame(width: s, height: s)
        }
    }
}
