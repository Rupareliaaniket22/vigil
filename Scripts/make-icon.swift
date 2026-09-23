// Builds Vigil.iconset and the menu bar template from Resources/mark.png.
//
// The source is the amber mark alone on transparency, so the ground is drawn
// here rather than baked in. That buys two things: the icon can sit on Apple's
// grid at any size without rescaling someone else's rounded corners, and the
// alpha channel doubles as the menu bar silhouette.
//
// Apple's grid, since Big Sur: an 824pt continuous-curvature squircle centred
// on a 1024pt canvas. The 100pt margin is not decoration — the system draws the
// Dock's reflection and shadow into it, and an icon that fills its own canvas
// sits visibly larger than every neighbour.
import AppKit
import Foundation

let markURL = URL(fileURLWithPath: "Resources/mark.png")
guard let mark = NSImage(contentsOf: markURL) else {
  FileHandle.standardError.write(Data("error: \(markURL.path) not found\n".utf8))
  exit(1)
}

/// DESIGN.md's amber, and a ground dark enough that the mark carries at 16pt.
let amber = NSColor(srgbRed: 1.00, green: 0.70, blue: 0.25, alpha: 1)
let ground = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)

private enum Grid {
  static let content: CGFloat = 824.0 / 1024.0
  static let radius: CGFloat = 185.4 / 824.0
  /// The mark's share of the tile. Apple's own utility icons sit near this.
  static let mark: CGFloat = 0.62
}

func renderIcon(_ px: Int) -> NSImage {
  let canvas = CGFloat(px)
  let side = (canvas * Grid.content).rounded()
  let origin = ((canvas - side) / 2).rounded()

  let image = NSImage(size: NSSize(width: canvas, height: canvas))
  image.lockFocus()
  defer { image.unlockFocus() }
  NSGraphicsContext.current?.imageInterpolation = .high

  // A CALayer gives cornerCurve .continuous; NSBezierPath's rounded rect is a
  // circular arc, which reads visibly more like a pill at icon sizes.
  let tile = CALayer()
  tile.frame = CGRect(x: 0, y: 0, width: side, height: side)
  tile.cornerRadius = side * Grid.radius
  tile.cornerCurve = .continuous
  tile.backgroundColor = ground.cgColor
  tile.masksToBounds = true

  if let context = NSGraphicsContext.current?.cgContext {
    context.saveGState()
    context.translateBy(x: origin, y: origin)
    tile.render(in: context)
    context.restoreGState()
  }

  // Composited as supplied, not filled through its alpha. The cut-out made the
  // mark's outer boundary transparent but left the interior between the arcs
  // opaque, so the alpha channel is the whole eye region rather than the amber
  // — filling through it yields a solid lens with the arcs and pupil gone.
  let markSide = (canvas * Grid.mark).rounded()
  let markOrigin = ((canvas - markSide) / 2).rounded()
  mark.draw(
    in: NSRect(x: markOrigin, y: markOrigin, width: markSide, height: markSide),
    from: .zero, operation: .sourceOver, fraction: 1)

  return image
}

/// Unused, and kept only to record why.
///
/// A menu bar glyph must be black-and-clear — macOS reads the alpha channel and
/// tints it. That needs the alpha to *be* the mark, and here it is the whole eye
/// region, so this produces a solid lens. The status item stays on SF Symbols'
/// eye and eye.fill, which are drawn for 16pt and give the fill-versus-outline
/// pair DESIGN.md uses to carry awake and asleep.
func renderTemplate(_ px: Int) -> NSImage {
  let image = NSImage(size: NSSize(width: px, height: px))
  image.lockFocus()
  defer { image.unlockFocus() }
  NSGraphicsContext.current?.imageInterpolation = .high

  let rect = NSRect(x: 0, y: 0, width: px, height: px)
  mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
  NSColor.black.set()
  rect.fill(using: .sourceAtop)

  image.isTemplate = true
  return image
}

func write(_ image: NSImage, to url: URL) throws {
  guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
  else { return }
  try png.write(to: url)
}

let iconset = URL(fileURLWithPath: "Resources/Vigil.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
  for (scale, suffix) in [(1, ""), (2, "@2x")] {
    let px = size * scale
    guard px <= 1024 else { continue }
    try write(renderIcon(px), to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}

print("wrote \(iconset.path)")
