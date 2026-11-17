#!/usr/bin/env swift
// Renders design/app-icon.svg into the AppIcon asset catalog PNGs.
// Usage: swift scripts/render-app-icon.swift   (run from the repo root)

import AppKit

let source = URL(fileURLWithPath: "design/app-icon.svg")
let output = URL(fileURLWithPath: "TuneNook/Resources/Assets.xcassets/AppIcon.appiconset")

guard let svg = NSImage(contentsOf: source) else {
    fatalError("Can't load \(source.path)")
}

struct Slot {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
}

let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

for slot in slots {
    let size = slot.pixels
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Can't make a \(size)px bitmap") }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Can't encode \(slot.filename)")
    }
    try png.write(to: output.appendingPathComponent(slot.filename))
}

let images = slots.map {
    """
        { "filename" : "\($0.filename)", "idiom" : "mac", "scale" : "\($0.scale)x", "size" : "\($0.points)x\($0.points)" }
    """
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Rendered \(slots.count) icons into \(output.path)")
