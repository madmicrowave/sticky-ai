import AppKit

func generateAppIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    
    // Background: sleek modern rounded rect (squircle-like radius) or full rounded rect
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.2237 // Apple standard squircle corner radius
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    
    NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1.0).setFill()
    path.fill()
    
    // Subtle border
    NSColor(calibratedWhite: 1.0, alpha: 0.15).setStroke()
    path.lineWidth = max(1.0, size * 0.015)
    path.stroke()
    
    // Draw Text "SAI"
    let text = "SAI"
    let fontSize = size * 0.40
    let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
    
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraphStyle,
        .kern: size * -0.01
    ]
    
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let textSize = attrStr.size()
    
    // Center vertically & horizontally
    let textRect = NSRect(
        x: (size - textSize.width) / 2.0,
        y: (size - textSize.height) / 2.0 + (size * 0.01),
        width: textSize.width,
        height: textSize.height
    )
    
    attrStr.draw(in: textRect)
    
    img.unlockFocus()
    return img
}

func savePNG(image: NSImage, path: String) {
    guard let tiffData = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiffData),
          let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert image to PNG")
    }
    try! pngData.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconsetDir = "/tmp/AppIcon.iconset"
try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    let img = generateAppIcon(size: size)
    savePNG(image: img, path: "\(iconsetDir)/\(name)")
}

print("Iconset generated successfully at \(iconsetDir)")
