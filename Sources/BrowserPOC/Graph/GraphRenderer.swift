import AppKit
import Metal
import MetalKit

struct GraphUniforms {
    var viewSize: SIMD2<Float> = .zero
    var center: SIMD2<Float> = .zero
    var scale: Float = 1
    var lineWidth: Float = 1
    var arrowSize: Float = 6
    var hovered: Int32 = -1
    var ringColor: SIMD4<Float> = .one
    var hoverRingColor: SIMD4<Float> = .one
    var labelColor: SIMD4<Float> = .one
}

struct NodeStyleGPU {
    var color: SIMD4<Float>
    var radius: Float
    var alpha: Float
    var ring: Float
    var hollow: Float
}

struct EdgeGPU {
    var a: UInt32
    var b: UInt32
    /// Colour index, plus 0x100 for a directed edge.
    var type: UInt32
    var weight: Float
}

struct LabelGPU {
    var world: SIMD2<Float>
    var offset: SIMD2<Float>
    var size: SIMD2<Float>
    var uv: SIMD4<Float>
    var alpha: Float
    var pad: Float = 0
}

/// One frame's worth of things to draw.
struct GraphFrame {
    var uniforms = GraphUniforms()
    var background: SIMD4<Float> = .zero
    var styles: [NodeStyleGPU] = []
    var labels: [LabelGPU] = []
    var arrows = false
}

/// Draws the graph with Metal: one instanced pass each for lines, arrows, nodes and names.
/// Lines and arrows read node positions on the GPU, so only positions and styles change per frame.
final class GraphRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let edgePipeline: MTLRenderPipelineState
    private let arrowPipeline: MTLRenderPipelineState
    private let nodePipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    let atlas: LabelAtlas
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private var edgeBuffer: MTLBuffer?
    private(set) var edgeCount = 0
    private var colorBuffer: MTLBuffer?
    private var positions: [MTLBuffer?] = [nil, nil, nil]
    private var styles: [MTLBuffer?] = [nil, nil, nil]
    private var labelBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var slot = 0
    private let inFlight = DispatchSemaphore(value: 3)
    /// GPU time of the last frame, in milliseconds.
    private(set) var lastGPUTime: Double = 0

    nonisolated(unsafe) private static var cachedLibrary: MTLLibrary?

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelRatio: CGFloat = 2, theme: GraphTheme = .dark) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        if let l = Self.cachedLibrary, l.device === device {
            library = l
        } else {
            do { library = try device.makeLibrary(source: GraphShaders.source, options: nil) } catch {
                appLog.error("graph shaders failed: \(String(describing: error), privacy: .public)")
                return nil
            }
            Self.cachedLibrary = library
        }
        func pipeline(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let c = d.colorAttachments[0]!
            c.pixelFormat = Self.pixelFormat
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let e = pipeline("edgeVertex", "edgeFragment"), let a = pipeline("arrowVertex", "arrowFragment"),
              let n = pipeline("nodeVertex", "nodeFragment"), let l = pipeline("labelVertex", "labelFragment"),
              let atlas = LabelAtlas(device: device, pixelRatio: pixelRatio, fontSize: theme.labelFontSize, maxWidth: theme.labelMaxWidth)
        else { return nil }
        edgePipeline = e; arrowPipeline = a; nodePipeline = n; labelPipeline = l
        self.atlas = atlas
        setTheme(theme)
    }

    func setTheme(_ theme: GraphTheme) {
        var colors = [SIMD4<Float>](repeating: .zero, count: 8)
        for t in GraphEdgeType.allCases { colors[Self.colorIndex(t)] = theme.color(t) }
        colorBuffer = device.makeBuffer(bytes: colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count, options: .storageModeShared)
    }

    static func colorIndex(_ t: GraphEdgeType) -> Int { GraphEdgeType.allCases.firstIndex(of: t) ?? 0 }

    func setEdges(_ edges: [EdgeGPU]) {
        edgeCount = edges.count
        edgeBuffer = edges.isEmpty ? nil : device.makeBuffer(bytes: edges, length: MemoryLayout<EdgeGPU>.stride * edges.count, options: .storageModeShared)
    }

    private func buffer(_ list: inout [MTLBuffer?], _ bytes: Int) -> MTLBuffer? {
        if let b = list[slot], b.length >= bytes { return b }
        let b = device.makeBuffer(length: max(bytes, 256) * 3 / 2, options: .storageModeShared)
        list[slot] = b
        return b
    }

    /// Encodes the frame into a pass that clears to the background.
    private func encode(_ cb: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, _ frame: GraphFrame,
                        positions src: (UnsafeMutableRawPointer, Int) -> Int) {
        let bg = frame.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let n = frame.styles.count
        var u = frame.uniforms
        if n > 0, let pb = buffer(&positions, n * MemoryLayout<SIMD2<Float>>.stride),
           let sb = buffer(&styles, n * MemoryLayout<NodeStyleGPU>.stride) {
            let copied = src(pb.contents(), n)
            if copied >= n {
                frame.styles.withUnsafeBytes { sb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                if let eb = edgeBuffer, edgeCount > 0, let cbuf = colorBuffer {
                    enc.setRenderPipelineState(edgePipeline)
                    enc.setVertexBytes(&u, length: MemoryLayout<GraphUniforms>.stride, index: 0)
                    enc.setVertexBuffer(pb, offset: 0, index: 1)
                    enc.setVertexBuffer(sb, offset: 0, index: 2)
                    enc.setVertexBuffer(eb, offset: 0, index: 3)
                    enc.setVertexBuffer(cbuf, offset: 0, index: 4)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: edgeCount)
                    if frame.arrows {
                        enc.setRenderPipelineState(arrowPipeline)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: edgeCount)
                    }
                }
                enc.setRenderPipelineState(nodePipeline)
                enc.setVertexBytes(&u, length: MemoryLayout<GraphUniforms>.stride, index: 0)
                enc.setVertexBuffer(pb, offset: 0, index: 1)
                enc.setVertexBuffer(sb, offset: 0, index: 2)
                enc.setFragmentBytes(&u, length: MemoryLayout<GraphUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)
            }
        }
        if !frame.labels.isEmpty, let lb = buffer(&labelBuffers, frame.labels.count * MemoryLayout<LabelGPU>.stride) {
            frame.labels.withUnsafeBytes { lb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            enc.setRenderPipelineState(labelPipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<GraphUniforms>.stride, index: 0)
            enc.setVertexBuffer(lb, offset: 0, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<GraphUniforms>.stride, index: 0)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.labels.count)
        }
        enc.endEncoding()
    }

    /// Draws into the view's next drawable. `positions` copies node positions into the buffer
    /// and returns how many it wrote.
    func draw(in view: MTKView, _ frame: GraphFrame, positions: (UnsafeMutableRawPointer, Int) -> Int) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        inFlight.wait()
        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        encode(cb, pass, frame, positions: positions)
        let sem = inFlight
        cb.addCompletedHandler { [weak self] b in
            self?.lastGPUTime = (b.gpuEndTime - b.gpuStartTime) * 1000
            sem.signal()
        }
        cb.present(drawable)
        cb.commit()
        slot = (slot + 1) % 3
    }

    /// Draws offscreen and returns an image. For snapshots and the performance check.
    func renderImage(width: Int, height: Int, _ frame: GraphFrame, positions: (UnsafeMutableRawPointer, Int) -> Int) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        inFlight.wait()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        encode(cb, pass, frame, positions: positions)
        cb.commit()
        cb.waitUntilCompleted()
        lastGPUTime = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        inFlight.signal()
        slot = (slot + 1) % 3
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        bytes.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
