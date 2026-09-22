// Renders Vigil's app icon at every size macOS wants, then hands off to
// iconutil. Generated rather than checked in as a binary so the design is
// reviewable in a diff — the icon is the same idea as the app: a watchful eye,
// lit amber, on a dark ground.
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: "Resources/Vigil.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// DESIGN.md's amber, and a ground dark enough that the glyph carries at 16pt.
let amber = NSColor(srgbRed: 1.00, green: 0.70, blue: 0.25, alpha: 1)
let ground = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1)

func render(_ px: Int) -> NSImage {
  let size = NSSize(width: px, height: px)
  let image = NSImage(size: size)
  image.lockFocus()
  defer { image.unlockFocus() }

  let rect = NSRect(origin: .zero, size: size)
  // macOS rounds app icons to roughly 22% of their width.
  let squircle = NSBezierPath(
    roundedRect: rect.insetBy(dx: CGFloat(px) * 0.06, dy: CGFloat(px) * 0.06),
    xRadius: CGFloat(px) * 0.22, yRadius: CGFloat(px) * 0.22)
  ground.setFill()
  squircle.fill()

  // The eye, drawn as two arcs meeting at the corners — a lens shape rather
  // than an ellipse, so it reads as an eye and not a circle in a box.
  let w = CGFloat(px) * 0.62
  let h = CGFloat(px) * 0.34
  let cx = CGFloat(px) / 2
  let cy = CGFloat(px) / 2
  let lens = NSBezierPath()
  lens.move(to: NSPoint(x: cx - w / 2, y: cy))
  lens.curve(
    to: NSPoint(x: cx + w / 2, y: cy),
    controlPoint1: NSPoint(x: cx - w / 4, y: cy + h),
    controlPoint2: NSPoint(x: cx + w / 4, y: cy + h))
  lens.curve(
    to: NSPoint(x: cx - w / 2, y: cy),
    controlPoint1: NSPoint(x: cx + w / 4, y: cy - h),
    controlPoint2: NSPoint(x: cx - w / 4, y: cy - h))
  // Close it, or the two curves leave a visible notch where they meet.
  lens.close()
  lens.lineWidth = max(1, CGFloat(px) * 0.055)
  lens.lineJoinStyle = .round
  lens.lineCapStyle = .round
  amber.setStroke()
  lens.stroke()

  // The pupil, filled — this is what survives at 16pt when the arcs blur.
  let r = CGFloat(px) * 0.115
  amber.setFill()
  NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()

  return image
}

for size in sizes {
  for (scale, suffix) in [(1, ""), (2, "@2x")] {
    let px = size * scale
    guard px <= 1024 else { continue }
    let image = render(px)
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { continue }
    try png.write(to: out.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}
print("wrote \(out.path)")
