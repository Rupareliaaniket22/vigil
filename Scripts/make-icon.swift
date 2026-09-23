// Builds Vigil.iconset from Resources/icon-source.png.
//
// The artwork is masked to Apple's icon grid rather than used as-is: since Big
// Sur, a macOS app icon is an 824pt continuous-curvature squircle centred on a
// 1024pt canvas. The 100pt margin is not decoration — the system draws the
// Dock's reflection and shadow into it, and an icon that fills its canvas sits
// visibly larger than every neighbour.
//
// Generated rather than checked in as an iconset so the geometry is reviewable
// in a diff and one source file drives every size.
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let source = URL(fileURLWithPath: "Resources/icon-source.png")
let out = URL(fileURLWithPath: "Resources/Vigil.iconset")

guard let artwork = NSImage(contentsOf: source) else {
  FileHandle.standardError.write(Data("error: \(source.path) not found\n".utf8))
  exit(1)
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Apple's proportions, expressed as fractions so they hold at every size.
private enum Grid {
  /// 824 of 1024.
  static let content: CGFloat = 824.0 / 1024.0
  /// 185.4 of 824 — the squircle's radius relative to its own width.
  static let radius: CGFloat = 185.4 / 824.0
}

func render(_ px: Int) -> NSImage {
  let canvas = CGFloat(px)
  let side = (canvas * Grid.content).rounded()
  let origin = ((canvas - side) / 2).rounded()
  let rect = NSRect(x: origin, y: origin, width: side, height: side)

  let image = NSImage(size: NSSize(width: canvas, height: canvas))
  image.lockFocus()
  defer { image.unlockFocus() }

  NSGraphicsContext.current?.imageInterpolation = .high

  // A CALayer gives us `cornerCurve = .continuous`; NSBezierPath's rounded rect
  // is a circular arc, which reads visibly more "pill" at icon sizes. Drawing
  // the layer into the image is the cheapest way to get the real squircle.
  let layer = CALayer()
  layer.frame = CGRect(origin: .zero, size: CGSize(width: side, height: side))
  layer.cornerRadius = side * Grid.radius
  layer.cornerCurve = .continuous
  layer.masksToBounds = true
  layer.contents = artwork
  layer.contentsGravity = .resizeAspectFill

  if let context = NSGraphicsContext.current?.cgContext {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY)
    layer.render(in: context)
    context.restoreGState()
  }

  return image
}

for size in sizes {
  for (scale, suffix) in [(1, ""), (2, "@2x")] {
    let px = size * scale
    guard px <= 1024 else { continue }
    guard let tiff = render(px).tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { continue }
    try png.write(to: out.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}
print("wrote \(out.path)")
