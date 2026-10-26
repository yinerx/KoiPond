import AppKit
import CoreText
import Metal
import PondCore

/// Every glyph in `Glyph.table`, pre-drawn once into a single-channel texture (white on black).
/// Slot `code` sits at column `code % columns`, row `code / columns`.
final class GlyphAtlas {
    let texture: MTLTexture
    let columns = 16
    let slotPixels: Int
    var size: Int { columns * slotPixels }

    init?(device: MTLDevice, cellPoints: Double, scale: Double) {
        let slot = max(8, Int((cellPoints * scale).rounded(.up)))
        slotPixels = slot
        let side = columns * slot                         // 256 codes → 16 × 16 slots
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)

        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(Double(slot) * 0.78), weight: .medium) as CTFont
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        for (code, ch) in Glyph.table where ch != " " {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: attrs))
            let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
            let col = Int(code) % columns, row = Int(code) / columns
            // CG's origin is bottom-left; the bitmap's first row is the top of the image
            let x = CGFloat(col * slot) + (CGFloat(slot) - CGFloat(advance)) / 2
            let y = CGFloat(side - (row + 1) * slot) + (CGFloat(slot) - (ascent + descent)) / 2 + descent
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        guard let data = ctx.data else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: data, bytesPerRow: side)
        texture = tex
    }
}
