// Renders the app icon (SF Symbol "arrow.triangle.branch" — a railway switch — on a blue gradient)
// to a 1024x1024 PNG. Usage: swift appicon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-square background with a vertical blue gradient.
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
path.addClip()
let top = NSColor(calibratedRed: 0.16, green: 0.49, blue: 0.96, alpha: 1)   // #2A7DF5
let bottom = NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.58, alpha: 1) // #0D3894
NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

// The branch symbol, white, centred.
let pt = size * 0.60
let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = sym.size
    let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
    sym.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
_ = ctx
