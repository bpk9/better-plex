import AppKit
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.035, green: 0.043, blue: 0.055, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let gold = NSColor(calibratedRed: 1, green: 0.73, blue: 0.22, alpha: 1)
gold.setStroke()
let frame = NSBezierPath(roundedRect: NSRect(x: 200, y: 240, width: 624, height: 540), xRadius: 100, yRadius: 100)
frame.lineWidth = 42
frame.stroke()
gold.setFill()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 472, y: 660)); arrow.line(to: NSPoint(x: 552, y: 660)); arrow.line(to: NSPoint(x: 552, y: 470)); arrow.line(to: NSPoint(x: 628, y: 470)); arrow.line(to: NSPoint(x: 512, y: 350)); arrow.line(to: NSPoint(x: 396, y: 470)); arrow.line(to: NSPoint(x: 472, y: 470)); arrow.close(); arrow.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
