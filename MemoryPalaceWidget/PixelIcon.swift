import SwiftUI

// Widget target cannot see JournalKit.swift. The app copy remains there for macOS;
// keep this renderer and the three shared glyphs in sync with that file.
struct PixelIcon: View {
    let bitmap: [String]
    var size: CGFloat = 15
    var color: Color = Palette.ink

    var body: some View {
        Canvas { context, canvasSize in
            let rows = bitmap.count
            let columns = bitmap.map(\.count).max() ?? 1
            let cellWidth = canvasSize.width / CGFloat(columns)
            let cellHeight = canvasSize.height / CGFloat(rows)
            for (y, row) in bitmap.enumerated() {
                for (x, character) in row.enumerated() where character == "X" {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(x) * cellWidth,
                            y: CGFloat(y) * cellHeight,
                            width: cellWidth + 0.2,
                            height: cellHeight + 0.2
                        )),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum PixelGlyph {
    static let reload = [
        "............XX......",
        "............XX......",
        "............XXXX....",
        "............XXXX....",
        "..XXXXXXXXXXXXXXXX..",
        "..XXXXXXXXXXXXXXXX..",
        "XX..........XXXX....",
        "XX..........XXXX....",
        "XX..........XX......",
        "XX..........XX....XX",
        "XX....XX..........XX",
        "......XX..........XX",
        "....XXXX..........XX",
        "....XXXX..........XX",
        "..XXXXXXXXXXXXXXXX..",
        "..XXXXXXXXXXXXXXXX..",
        "....XXXX............",
        "....XXXX............",
        "......XX............",
        "......XX............",
    ]

    static let wifi = [
        "......................",
        "......................",
        "......XXXXXXXXXX......",
        "......XXXXXXXXXX......",
        "....XX..........XX....",
        "....XX..........XX....",
        "..XX..............XX..",
        "..XX...XXXXXXXX...XX..",
        "XX.....XXXXXXXX.....XX",
        "XX...XX........XX...XX",
        ".....XX........XX.....",
        "...XX............XX...",
        "...XX...XXXXXX...XX...",
        "........XXXXXX........",
        "......XX......XX......",
        "......XX......XX......",
        "......................",
        "..........XX..........",
        "..........XX..........",
        "......................",
        "......................",
        "......................",
    ]

    static let battery = [
        "....................",
        "....................",
        "....................",
        "..XXXXXXXXXXXXXXXX..",
        "..XXXXXXXXXXXXXXXX..",
        "XX..............XX..",
        "XX..............XX..",
        "XX..XX..XX..XX..XXXX",
        "XX..XX..XX..XX..XXXX",
        "XX..XX..XX..XX..XXXX",
        "XX..XX..XX..XX..XXXX",
        "XX..XX..XX..XX..XXXX",
        "XX..XX..XX..XX..XXXX",
        "XX..............XX..",
        "XX..............XX..",
        "..XXXXXXXXXXXXXXXX..",
        "..XXXXXXXXXXXXXXXX..",
        "....................",
        "....................",
        "....................",
    ]
}
