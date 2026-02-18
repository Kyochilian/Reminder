#!/usr/bin/env swift

import AppKit

enum RenderError: Error {
    case bitmapCreationFailed
    case contextCreationFailed
    case pngEncodingFailed
}

func eyeOutline(in rect: CGRect) -> CGPath {
    let left = CGPoint(x: rect.minX, y: rect.midY)
    let right = CGPoint(x: rect.maxX, y: rect.midY)
    let sideInset = rect.width * 0.22
    let topOffset = rect.height * 0.56

    let path = CGMutablePath()
    path.move(to: left)
    path.addCurve(
        to: right,
        control1: CGPoint(x: rect.minX + sideInset, y: rect.midY + topOffset),
        control2: CGPoint(x: rect.maxX - sideInset, y: rect.midY + topOffset)
    )
    path.addCurve(
        to: left,
        control1: CGPoint(x: rect.maxX - sideInset, y: rect.midY - topOffset),
        control2: CGPoint(x: rect.minX + sideInset, y: rect.midY - topOffset)
    )
    path.closeSubpath()
    return path
}

func drawRoundedTile(in context: CGContext, rect: CGRect, size: CGFloat) {
    let corner = rect.width * 0.24
    let tilePath = CGPath(
        roundedRect: rect,
        cornerWidth: corner,
        cornerHeight: corner,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.018),
        blur: size * 0.05,
        color: NSColor.black.withAlphaComponent(0.26).cgColor
    )
    context.addPath(tilePath)
    context.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceGray(),
        colors: [
            NSColor(calibratedWhite: 0.98, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.90, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.84, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!

    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
    context.restoreGState()

    context.addPath(tilePath)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.16).cgColor)
    context.setLineWidth(size * 0.004)
    context.strokePath()

    let glareRect = CGRect(
        x: rect.minX + rect.width * 0.08,
        y: rect.maxY - rect.height * 0.36,
        width: rect.width * 0.84,
        height: rect.height * 0.26
    )
    let glarePath = CGPath(
        roundedRect: glareRect,
        cornerWidth: glareRect.height * 0.5,
        cornerHeight: glareRect.height * 0.5,
        transform: nil
    )
    context.saveGState()
    context.addPath(glarePath)
    context.clip()
    let glare = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceGray(),
        colors: [
            NSColor(calibratedWhite: 1.0, alpha: 0.45).cgColor,
            NSColor(calibratedWhite: 1.0, alpha: 0.02).cgColor,
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        glare,
        start: CGPoint(x: glareRect.midX, y: glareRect.maxY),
        end: CGPoint(x: glareRect.midX, y: glareRect.minY),
        options: []
    )
    context.restoreGState()
}

func drawSymbol(in context: CGContext, rect: CGRect, size: CGFloat) {
    let eyeRect = CGRect(
        x: rect.minX + rect.width * 0.18,
        y: rect.minY + rect.height * 0.30,
        width: rect.width * 0.64,
        height: rect.height * 0.40
    )
    let eyePath = eyeOutline(in: eyeRect)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.006),
        blur: size * 0.012,
        color: NSColor.black.withAlphaComponent(0.16).cgColor
    )
    context.addPath(eyePath)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    context.addPath(eyePath)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.92).cgColor)
    context.setLineWidth(size * 0.022)
    context.setLineJoin(.round)
    context.strokePath()

    let clockRadius = eyeRect.height * 0.23
    let clockRect = CGRect(
        x: eyeRect.midX - clockRadius,
        y: eyeRect.midY - clockRadius,
        width: clockRadius * 2,
        height: clockRadius * 2
    )

    context.addEllipse(in: clockRect)
    context.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 1).cgColor)
    context.fillPath()

    context.addEllipse(in: clockRect)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.94).cgColor)
    context.setLineWidth(size * 0.018)
    context.strokePath()

    context.setLineCap(.round)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.94).cgColor)
    context.setLineWidth(size * 0.016)
    context.move(to: CGPoint(x: clockRect.midX, y: clockRect.midY))
    context.addLine(
        to: CGPoint(
            x: clockRect.midX,
            y: clockRect.midY + clockRadius * 0.54
        )
    )
    context.strokePath()

    context.setLineWidth(size * 0.014)
    context.move(to: CGPoint(x: clockRect.midX, y: clockRect.midY))
    context.addLine(
        to: CGPoint(
            x: clockRect.midX + clockRadius * 0.42,
            y: clockRect.midY + clockRadius * 0.28
        )
    )
    context.strokePath()

    let centerDotRadius = size * 0.012
    context.addEllipse(
        in: CGRect(
            x: clockRect.midX - centerDotRadius,
            y: clockRect.midY - centerDotRadius,
            width: centerDotRadius * 2,
            height: centerDotRadius * 2
        )
    )
    context.setFillColor(NSColor.black.withAlphaComponent(0.94).cgColor)
    context.fillPath()
}

func renderIcon(to outputPath: String, size: CGFloat) throws {
    let pixelSize = Int(size.rounded())
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw RenderError.bitmapCreationFailed
    }
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw RenderError.contextCreationFailed
    }

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.125
    let tileRect = canvas.insetBy(dx: inset, dy: inset)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let context = graphicsContext.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.clear(canvas)

    drawRoundedTile(in: context, rect: tileRect, size: size)
    drawSymbol(in: context, rect: tileRect, size: size)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw RenderError.pngEncodingFailed
    }
    let fileURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: fileURL)
}

let outputPath = CommandLine.arguments.dropFirst().first ?? "assets/icon_source.png"
let sizeArg = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 1024.0) : 1024.0
let size = CGFloat(max(256.0, sizeArg))

do {
    try renderIcon(to: outputPath, size: size)
    print("Rendered \(Int(size))x\(Int(size)) icon: \(outputPath)")
} catch {
    fputs("Icon render failed: \(error)\n", stderr)
    exit(1)
}
