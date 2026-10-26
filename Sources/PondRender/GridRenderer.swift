import Metal
import MetalKit
import PondCore

/// Draws a `CellGrid` in one instanced draw call: one quad per cell, a tile (bg) inset by the gap, the glyph on top.
final class GridRenderer {
    private struct Uniforms {
        var viewSize: SIMD2<Float>
        var cell: Float
        var gap: Float
        var cols: UInt32
        var atlasCols: UInt32
        var atlasSlot: Float
        var atlasSize: Float
        var clearColor: SIMD4<Float>
    }
    private struct GPUCell { var glyph: UInt32; var fg: UInt32; var bg: UInt32; var pad: UInt32 }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var atlas: GlyphAtlas?
    private var atlasKey: (Double, Double) = (0, 0)
    private var cellBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)

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
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("KoiPond: Metal pipeline failed: \(error)")
            return nil
        }
    }

    func draw(grid: CellGrid, settings: GlobalSettings, background: RGBA, in view: MTKView) {
        guard grid.cols > 0, grid.rows > 0 else { return }
        let scale = Double(view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 2)
        if atlas == nil || atlasKey != (grid.cellSize, scale) {
            atlas = GlyphAtlas(device: device, cellPoints: grid.cellSize, scale: scale)
            atlasKey = (grid.cellSize, scale)
        }
        guard let atlas else { return }

        inFlight.wait()
        let count = grid.cols * grid.rows
        let bytes = count * MemoryLayout<GPUCell>.stride
        if cellBuffers.count < 3 || cellBuffers[0].length < bytes {
            cellBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: max(bytes, 16), options: .storageModeShared) }
        }
        guard cellBuffers.count == 3 else { inFlight.signal(); return }
        bufferIndex = (bufferIndex + 1) % 3
        let buf = cellBuffers[bufferIndex]
        let dst = buf.contents().bindMemory(to: GPUCell.self, capacity: count)
        grid.cells.withUnsafeBufferPointer { src in
            for i in 0..<count {
                let c = src[i]
                dst[i] = GPUCell(glyph: UInt32(c.glyph), fg: c.fg.packed, bg: c.bg.packed, pad: 0)
            }
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let bg = SIMD4<Float>(Float(background.r) / 255, Float(background.g) / 255, Float(background.b) / 255, 1)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        var u = Uniforms(viewSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)),
                         cell: Float(grid.cellSize), gap: Float(settings.tileGap),
                         cols: UInt32(grid.cols), atlasCols: UInt32(atlas.columns),
                         atlasSlot: Float(atlas.slotPixels), atlasSize: Float(atlas.size), clearColor: bg)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        enc.endEncoding()
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
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
        float4 clearColor;
    };
    struct GPUCell { uint glyph; uint fg; uint bg; uint pad; };
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
        uint col = iid % u.cols, row = iid / u.cols;
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

    fragment float4 cellFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                 texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float h = u.gap * 0.5;
        bool inTile = in.local.x >= h && in.local.y >= h && in.local.x <= u.cell - h && in.local.y <= u.cell - h;
        float3 base = u.clearColor.rgb;
        if (inTile && in.bg.a > 0.0) base = mix(base, in.bg.rgb, in.bg.a);
        float cov = atlas.sample(s, in.uv).r;
        return float4(mix(base, in.fg.rgb, cov * in.fg.a), 1.0);
    }
    """
}
