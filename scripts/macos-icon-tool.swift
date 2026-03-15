#!/usr/bin/env swift
import AppKit
import Foundation

enum ToolError: Error {
    case usage
    case loadImage(String)
    case writeImage(String)
    case invalidDimensions(String)
}

func bitmap(path: String) throws -> (width: Int, height: Int, data: UnsafeMutablePointer<UInt8>) {
    guard let img = NSImage(contentsOfFile: path) else {
        throw ToolError.loadImage(path)
    }
    let w = Int(img.size.width)
    let h = Int(img.size.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: w * 4,
        bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.bitmapData else {
        throw ToolError.loadImage(path)
    }
    return (w, h, data)
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw ToolError.writeImage(path)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        throw ToolError.writeImage(path)
    }
}

func captureMask(appPath: String, outPath: String) throws {
    let icon = NSWorkspace.shared.icon(forFile: appPath)
    icon.size = NSSize(width: 1024, height: 1024)
    guard let tiff = icon.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        throw ToolError.loadImage(appPath)
    }
    try writePNG(rep, to: outPath)
    print(outPath)
}

func validate(iconPath: String, maskPath: String) throws {
    let (iw, ih, id) = try bitmap(path: iconPath)
    let (mw, mh, md) = try bitmap(path: maskPath)
    guard iw == 1024, ih == 1024, mw == 1024, mh == 1024 else {
        throw ToolError.invalidDimensions("both icon and mask must be 1024x1024")
    }

    let iconAlphaMin = 10
    let maskAlphaMin = 18

    var covered = 0
    var outside = 0
    var strongOutside = 0

    for i in 0..<(1024 * 1024) {
        let ia = Int(id[i * 4 + 3])
        if ia > iconAlphaMin {
            covered += 1
            let ma = Int(md[i * 4 + 3])
            if ma <= maskAlphaMin {
                outside += 1
                if ia > 160 {
                    strongOutside += 1
                }
            }
        }
    }

    let ratio = covered == 0 ? 0.0 : (Double(outside) / Double(covered) * 100.0)
    print("icon=\(iconPath)")
    print("covered_pixels=\(covered)")
    print("outside_mask_pixels=\(outside)")
    print(String(format: "outside_ratio=%.4f%%", ratio))
    print("strong_outside_pixels=\(strongOutside)")
    print(outside == 0 ? "PASS" : "FAIL")
}

func fit(iconPath: String, maskPath: String, outPath: String) throws {
    let (iw, ih, id) = try bitmap(path: iconPath)
    let (mw, mh, md) = try bitmap(path: maskPath)
    guard iw == 1024, ih == 1024, mw == 1024, mh == 1024 else {
        throw ToolError.invalidDimensions("both icon and mask must be 1024x1024")
    }

    let iconAlphaMin = 10
    let maskAlphaMin = 18
    let size = 1024
    let center = Double(size - 1) / 2.0

    var points = [(Int, Int)]()
    points.reserveCapacity(size * size / 2)
    for y in 0..<size {
        for x in 0..<size {
            let ia = Int(id[(y * size + x) * 4 + 3])
            if ia > iconAlphaMin {
                points.append((x, y))
            }
        }
    }

    func fits(scale: Double) -> Bool {
        for (x, y) in points {
            let dx = Int(round((Double(x) - center) * scale + center))
            let dy = Int(round((Double(y) - center) * scale + center))
            if dx < 0 || dx >= size || dy < 0 || dy >= size {
                return false
            }
            let ma = Int(md[(dy * size + dx) * 4 + 3])
            if ma <= maskAlphaMin {
                return false
            }
        }
        return true
    }

    var lo = 0.5
    var hi = 1.0
    for _ in 0..<28 {
        let mid = (lo + hi) / 2.0
        if fits(scale: mid) {
            lo = mid
        } else {
            hi = mid
        }
    }

    let safety = 0.985
    let finalScale = lo * safety
    let inset = (1.0 - finalScale) * 1024.0 / 2.0

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1024,
        pixelsHigh: 1024,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 1024 * 4,
        bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()

    let side = CGFloat(1024.0 * finalScale)
    let origin = CGFloat((1024.0 - Double(side)) / 2.0)
    let dest = NSRect(x: origin, y: origin, width: side, height: side)
    if let src = NSImage(contentsOfFile: iconPath) {
        src.draw(
            in: dest,
            from: NSRect(x: 0, y: 0, width: src.size.width, height: src.size.height),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
    NSGraphicsContext.restoreGraphicsState()

    try writePNG(rep, to: outPath)

    fputs(String(format: "scale=%.6f inset=%.2f\n", finalScale, inset), stderr)
    print(outPath)
}

func printUsage() {
    print("Usage:")
    print("  scripts/macos-icon-tool.swift mask <APP_PATH> <OUT_PNG>")
    print("  scripts/macos-icon-tool.swift validate <ICON_1024_PNG> <MASK_1024_PNG>")
    print("  scripts/macos-icon-tool.swift fit <ICON_1024_PNG> <MASK_1024_PNG> <OUT_1024_PNG>")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let cmd = args.first else {
        printUsage()
        throw ToolError.usage
    }

    switch cmd {
    case "mask":
        guard args.count == 3 else { throw ToolError.usage }
        try captureMask(appPath: args[1], outPath: args[2])
    case "validate":
        guard args.count == 3 else { throw ToolError.usage }
        try validate(iconPath: args[1], maskPath: args[2])
    case "fit":
        guard args.count == 4 else { throw ToolError.usage }
        try fit(iconPath: args[1], maskPath: args[2], outPath: args[3])
    default:
        throw ToolError.usage
    }
} catch ToolError.usage {
    printUsage()
    exit(2)
} catch ToolError.loadImage(let path) {
    fputs("failed to load image: \(path)\n", stderr)
    exit(1)
} catch ToolError.writeImage(let path) {
    fputs("failed to write image: \(path)\n", stderr)
    exit(1)
} catch ToolError.invalidDimensions(let message) {
    fputs("invalid dimensions: \(message)\n", stderr)
    exit(1)
} catch {
    fputs("unexpected error: \(error)\n", stderr)
    exit(1)
}
