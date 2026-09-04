import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-icon.swift <output.png>\n", stderr)
    exit(2)
}

let canvasSize = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvasSize)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let iconRect = NSRect(x: 52, y: 52, width: 920, height: 920)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 214, yRadius: 214)
NSColor(calibratedRed: 0.10, green: 0.39, blue: 0.86, alpha: 1).setFill()
iconPath.fill()

let insetPath = NSBezierPath(roundedRect: NSRect(x: 157, y: 157, width: 710, height: 710), xRadius: 112, yRadius: 112)
NSColor.white.withAlphaComponent(0.12).setFill()
insetPath.fill()

let tileSize: CGFloat = 150
let positions: [CGFloat] = [220, 437, 654]
let colors: [NSColor] = [
    .white,
    NSColor(calibratedRed: 0.93, green: 0.97, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.99, green: 0.83, blue: 0.25, alpha: 1),
    NSColor(calibratedRed: 0.93, green: 0.97, blue: 1.00, alpha: 1),
    .white,
    NSColor(calibratedRed: 0.25, green: 0.82, blue: 0.61, alpha: 1),
    NSColor(calibratedRed: 0.99, green: 0.45, blue: 0.44, alpha: 1),
    NSColor(calibratedRed: 0.93, green: 0.97, blue: 1.00, alpha: 1),
    .white
]

var colorIndex = 0
for y in positions.reversed() {
    for x in positions {
        let tile = NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: tileSize, height: tileSize),
            xRadius: 38,
            yRadius: 38
        )
        colors[colorIndex].setFill()
        tile.fill()
        colorIndex += 1
    }
}

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to create icon PNG\n", stderr)
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
