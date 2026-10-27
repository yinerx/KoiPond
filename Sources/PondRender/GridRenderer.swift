import Metal
import MetalKit
import QuartzCore
import PondCore

/// Draws a `CellGrid`: one instanced quad per *non-empty* cell (empty water is just the clear colour),
/// a tile (bg) inset by the gap, the glyph on top. A frame identical to the last one is not drawn at all.
final class GridRenderer {
    private struct Uniforms {
        var viewSize: SIMD2<Float>
        var cell: Float
        var gap: Float
        var cols: UInt32
        var atlasCols: UInt32
        var atlasSlot: Float
        var atlasSize: Float
    }
    /// One visible cell: where it is, what it shows.
    private struct GPUCell: Equatable { var index: UInt32; var glyph: UInt32; var fg: UInt32; var bg: UInt32 }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var atlas: GlyphAtlas?
    private var atlasKey: (Double, Double) = (0, 0)
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 2)
    private var staging: [GPUCell] = []
    private var lastFrame: [GPUCell] = []
    private var lastKey: FrameKey?

    /// What else, besides the cells, decides how a frame looks.
    private struct FrameKey: Equatable {
        var cols: Int, rows: Int, cell: Double, gap: Double, bg: UInt32, drawable: CGSize
    }

    /// Cells drawn in the last presented frame (for the performance overlay).
    private(set) var lastCellCount = 0
    /// Frames skipped because nothing changed (for the performance overlay).
    private(set) var skippedFrames = 0

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        do {
            let lib = try device.makeLibrary(source: GridRenderer.shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "cellVertex")
            d.fragmentFunction = lib.makeFunction(name: "cellFragment")
            d.colorAttachments[0].pixelFormat = pixelFormat
            // premultiplied "over" onto the cleared water colour
            let ca = d.colorAttachments[0]!
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("KoiPond: Metal pipeline failed: \(error)")
            return nil
        }
    }

    /// Forget the last frame so the next one is drawn even if unchanged (after a resize, a resume…).
    func invalidate() { lastKey = nil }

    /// Returns true if a frame was encoded and presented, false if it was skipped (unchanged) or impossible.
    @discardableResult
    func draw(grid: CellGrid, settings: GlobalSettings, background: RGBA, in view: MTKView) -> Bool {
        guard grid.cols > 0, grid.rows > 0, view.bounds.width > 0 else { return false }
        let pixelScale = Double(view.drawableSize.width / view.bounds.width)

        // gather the visible cells; empty water is left to the clear colour
        staging.removeAll(keepingCapacity: true)
        grid.cells.withUnsafeBufferPointer { src in
            for i in 0..<src.count {
                let c = src[i]
                if c.glyph == Glyph.space && c.bg.a == 0 { continue }
                if c.glyph != Glyph.space && c.fg.a == 0 && c.bg.a == 0 { continue }
                staging.append(GPUCell(index: UInt32(i), glyph: UInt32(c.glyph), fg: c.fg.packed, bg: c.bg.packed))
            }
        }
        let key = FrameKey(cols: grid.cols, rows: grid.rows, cell: grid.cellSize, gap: settings.tileGap,
                           bg: background.packed, drawable: view.drawableSize)
        if key == lastKey && staging == lastFrame { skippedFrames += 1; return false }

        if atlas == nil || atlasKey != (grid.cellSize, pixelScale) {
            atlas = GlyphAtlas(device: device, cellPoints: grid.cellSize, scale: pixelScale)
            atlasKey = (grid.cellSize, pixelScale)
        }
        guard let atlas else { return false }

        inFlight.wait()
        let count = staging.count
        let bytes = max(1, count) * MemoryLayout<GPUCell>.stride
        if buffers.count < 2 || buffers[0].length < bytes {
            // grow with headroom; a pond rarely uses more than a few thousand cells
            let size = max(bytes * 3 / 2, 64 * 1024)
            buffers = (0..<2).compactMap { _ in device.makeBuffer(length: size, options: .storageModeShared) }
        }
        guard buffers.count == 2 else { inFlight.signal(); return false }
        bufferIndex = (bufferIndex + 1) % 2
        let buf = buffers[bufferIndex]
        if count > 0 {
            staging.withUnsafeBytes { src in buf.contents().copyMemory(from: src.baseAddress!, byteCount: src.count) }
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { inFlight.signal(); return false }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(background.r) / 255, green: Double(background.g) / 255,
                                                            blue: Double(background.b) / 255, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return false }
        if count > 0 {
            var u = Uniforms(viewSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)),
                             cell: Float(grid.cellSize), gap: Float(settings.tileGap),
                             cols: UInt32(grid.cols), atlasCols: UInt32(atlas.columns),
                             atlasSlot: Float(atlas.slotPixels), atlasSize: Float(atlas.size))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        enc.endEncoding()
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()

        swap(&lastFrame, &staging)
        lastKey = key
        lastCellCount = count
        return true
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewSize;
        float cell;
        float gap;
        uint cols;
        uint atlasCols;
        float atlasSlot;
        float atlasSize;
    };
    struct GPUCell { uint index; uint glyph; uint fg; uint bg; };
    struct VOut {
        float4 pos [[position]];
        float2 local;
        float2 uv;
        float4 fg;
        float4 bg;
    };

    vertex VOut cellVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           constant Uniforms& u [[buffer(0)]], const device GPUCell* cells [[buffer(1)]]) {
        GPUCell c = cells[iid];
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        uint col = c.index % u.cols, row = c.index / u.cols;
        float2 p = (float2(float(col), float(row)) + corner) * u.cell;          // points, top-left origin
        VOut o;
        o.pos = float4(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0, 0.0, 1.0);
        o.local = corner * u.cell;
        float2 slot = float2(float(c.glyph % u.atlasCols), float(c.glyph / u.atlasCols));
        o.uv = (slot + corner) * u.atlasSlot / u.atlasSize;
        o.fg = unpack_unorm4x8_to_float(c.fg);
        o.bg = unpack_unorm4x8_to_float(c.bg);
        return o;
    }

    // Blended over the cleared water colour, so empty cells never reach the GPU.
    fragment float4 cellFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                 texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float h = u.gap * 0.5;
        bool inTile = in.local.x >= h && in.local.y >= h && in.local.x <= u.cell - h && in.local.y <= u.cell - h;
        float tileA = inTile ? in.bg.a : 0.0;
        float cov = atlas.sample(s, in.uv).r * in.fg.a;
        // premultiplied: tile under glyph
        float3 rgb = in.fg.rgb * cov + in.bg.rgb * tileA * (1.0 - cov);
        float a = cov + tileA * (1.0 - cov);
        return float4(rgb, a);
    }
    """
}
