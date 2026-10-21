// ForwardFlow — UIKit + Metal driver.
//
// One full-screen view aligned with window coordinates:
//   meshView — above everything incl. the share sheet (the copies flowing into the avatars).
// The avatars themselves stay host views: the animator reports their scale and ripple per frame.
// See README.md for the integration into Telegram-iOS.

import MetalKit
import UIKit

/// The forwarded message: its frame in window coordinates and a snapshot of exactly that size.
public struct ForwardFlowSource {
    public let frame: CGRect
    public let image: CGImage
    /// Dim over the message while the sheet is shown (ShareController: 0.5). The copy starts with it
    /// and brightens while it lifts, so there is no jump over the dimmed original.
    public let dimmed: Double
    public init(frame: CGRect, image: CGImage, dimmed: Double = 0) {
        self.frame = frame
        self.image = image
        self.dimmed = dimmed
    }
}

public final class ForwardFlowAnimator {
    public let config: ForwardFlowConfig
    public let meshView: UIView

    /// Called every frame while running: one state per target, in the order of the targets.
    /// Apply `scale` to the avatar and draw the ripple around it.
    public var onUpdate: (([ForwardFlowAvatarState]) -> Void)?
    /// The last point of the copy for target `index` is gone: a light haptic fits here.
    public var onTargetAbsorbed: ((Int) -> Void)?
    /// Every avatar has settled; the view is hidden again. Dismiss the sheet and show the toast now.
    public var onCompletion: (() -> Void)?

    public private(set) var isRunning = false

    /// Bundle with the compiled shader: `<name>.bundle` next to this module's binary
    /// (Bazel `apple_resource_bundle`, see BUILD), or the module bundle itself.
    public static func resourceBundle(named name: String = "ForwardFlowResourcesBundle") -> Bundle {
        let moduleBundle = Bundle(for: ForwardFlowRenderer.self)
        if let path = moduleBundle.path(forResource: name, ofType: "bundle"), let bundle = Bundle(path: path) {
            return bundle
        }
        return moduleBundle
    }

    private let renderer: ForwardFlowRenderer
    private let mesh: ForwardFlowMetalView
    private var link: CADisplayLink?
    private var run: ForwardFlowRun?
    private var dimmed: Double = 0
    private var time: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var absorbed = Set<Int>()
    private var texture: MTLTexture?
    private var startGeneration: UUID?

    /// - Parameter bundle: bundle with the compiled `ForwardFlow.metal` (default.metallib).
    ///   In Telegram-iOS — `ForwardFlowAnimator.resourceBundle()`.
    public init?(config: ForwardFlowConfig = .default, bundle: Bundle = .main) {
        guard let renderer = ForwardFlowRenderer(bundle: bundle) else { return nil }
        self.config = config
        self.renderer = renderer
        mesh = ForwardFlowMetalView(device: renderer.device)
        meshView = mesh
        mesh.isHidden = true
    }

    /// Compiles the pipeline off the main thread. Call when the sheet appears — otherwise the first
    /// run waits for shader compilation.
    public func prewarm() {
        renderer.prewarm()
    }

    /// Starts the animation. The texture is prepared off the main thread first (a few ms), then the
    /// first frame is drawn and `onStart` is called. The original message stays where it is: a copy
    /// flows, so the host hides nothing.
    /// - Parameters:
    ///   - source: the message snapshot in window coordinates.
    ///   - targets: recipient avatars in window coordinates; the first one is drawn on top.
    public func start(source: ForwardFlowSource, targets: [ForwardFlowTarget], onStart: (() -> Void)? = nil) {
        cancel()
        guard !targets.isEmpty else {
            onCompletion?()
            return
        }
        isRunning = true
        let device = renderer.device
        let generation = UUID()
        startGeneration = generation
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let texture = ForwardFlowRenderer.makeTexture(device: device, image: source.image)
            DispatchQueue.main.async {
                guard let self, self.startGeneration == generation else { return }
                guard let texture else {
                    self.cancel()
                    self.onCompletion?()
                    return
                }
                self.begin(source: source, targets: targets, texture: texture)
                onStart?()
            }
        }
    }

    private func begin(source: ForwardFlowSource, targets: [ForwardFlowTarget], texture: MTLTexture) {
        run = ForwardFlowRun(frame: source.frame, targets: targets, config: config)
        dimmed = source.dimmed
        self.texture = texture
        time = 0
        absorbed = []
        mesh.isHidden = false

        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.tick() }, selector: #selector(DisplayLinkTarget.fire))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
        render()
    }

    /// Stops immediately and hides everything (no completion callback).
    public func cancel() {
        startGeneration = nil
        link?.invalidate()
        link = nil
        run = nil
        isRunning = false
        texture = nil
        mesh.isHidden = true
    }

    private func tick() {
        guard let run else { return }
        let now = CACurrentMediaTime()
        if ProcessInfo.processInfo.environment["FORWARDFLOW_DEBUG_FRAMES"] != nil, now - lastTick > 0.025 {
            print(String(format: "ForwardFlow slow frame %.0f ms at t=%.2f", (now - lastTick) * 1000, time))
        }
        // Time advances by frames with a capped step: after a dropped frame the animation continues
        // from where it was instead of jumping ahead.
        time += min(now - lastTick, 1.0 / 30)
        lastTick = now
        for (index, track) in run.tracks.enumerated() where time >= track.end && !absorbed.contains(index) {
            absorbed.insert(index)
            onTargetAbsorbed?(index)
        }
        if time >= run.total {
            onUpdate?(run.tracks.map { _ in ForwardFlowAvatarState.rest })
            cancel()
            onCompletion?()
            return
        }
        render()
    }

    private func render() {
        guard let run, let texture else { return }
        let c = run.config
        let t = time
        onUpdate?(run.tracks.map { ForwardFlowAvatarState.at(t, track: $0, config: c) })

        let lift = run.lift(at: t)
        let frame = run.frame(at: t)
        let dim = Float(dimmed * (1 - lift))
        mesh.render { [renderer] encoder, size, scale in
            // Grid cell ~6 pt: smooth enough for the bend and the stream.
            let cols = max(4, Int((frame.width / 6).rounded())), rows = max(3, Int((frame.height / 6).rounded()))
            let maxLod = Float(log2(max(c.fadeBlur * Double(scale), 1)))
            // The first recipient is drawn last, on top: until the copies part they read as one bubble.
            for track in run.tracks.reversed() {
                let target = track.target
                let r = Double(target.radius)
                var u = MeshUniformsCPU(
                    view: SIMD4(Float(size.width), Float(size.height), Float(scale), 0),
                    hole: SIMD4(Float(target.center.x), Float(target.center.y), Float(r), Float(t - track.start)),
                    flow: SIMD4(Float(track.flowSpeed), Float(c.pullStrength), Float(c.pullReach * r), Float(c.flowRamp)),
                    extra: SIMD4(Float(c.sinkDepth * r), Float(track.swirl), Float(c.arcShape), Float(c.flowAccel)),
                    fade: SIMD4(Float(c.fadeOuter), Float(min(c.fadeInner, c.fadeOuter - 0.05)), maxLod, Float(c.lean * lift)),
                    frame: SIMD4(Float(frame.minX), Float(frame.minY), Float(frame.width), Float(frame.height)),
                    grid: SIMD4(Float(cols), Float(rows), Float(track.axis.dx), Float(track.axis.dy)),
                    tint: SIMD4(Float(target.tint.red), Float(target.tint.green), Float(target.tint.blue), dim))
                renderer.drawMesh(encoder: encoder, uniforms: &u, texture: texture, vertexCount: cols * rows * 6)
            }
        }
    }
}

// MARK: - Metal view

/// MTKView drawn manually from the animator's display link (one frame per tick, no own timer).
final class ForwardFlowMetalView: MTKView {
    init(device: MTLDevice) {
        super.init(frame: .zero, device: device)
        isOpaque = false
        backgroundColor = .clear
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = false
        isUserInteractionEnabled = false
        // Drawable size is set explicitly before every frame (see render): automatic resizing
        // missed frame changes made while the view was hidden.
        autoResizeDrawable = false
        contentScaleFactor = UIScreen.main.scale
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private lazy var queue = device?.makeCommandQueue()

    private var pending: ((MTLRenderCommandEncoder, CGSize, CGFloat) -> Void)?

    /// Renders one frame now. Goes through MTKView's own draw cycle: `currentDrawable` is only
    /// refreshed per `draw()`, outside of it every frame would go into the already presented drawable.
    func render(_ body: @escaping (MTLRenderCommandEncoder, CGSize, CGFloat) -> Void) {
        guard !isHidden, bounds.width > 0 else { return }
        let size = CGSize(width: (bounds.width * contentScaleFactor).rounded(), height: (bounds.height * contentScaleFactor).rounded())
        if drawableSize != size { drawableSize = size }
        pending = body
        draw()
        pending = nil
    }

    override func draw(_ rect: CGRect) {
        guard let body = pending, let queue, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        body(encoder, bounds.size, contentScaleFactor)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Renderer

final class ForwardFlowRenderer {
    let device: MTLDevice
    private let library: MTLLibrary
    private var meshPipeline: MTLRenderPipelineState?
    private let lock = NSLock()
    private lazy var mipSampler: MTLSamplerState? = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .clampToZero; d.tAddressMode = .clampToZero
        return device.makeSamplerState(descriptor: d)
    }()

    init?(bundle: Bundle) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeDefaultLibrary(bundle: bundle) else { return nil }
        self.device = device
        self.library = library
    }

    func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = pipeline()
        }
    }

    private func pipeline() -> MTLRenderPipelineState? {
        lock.lock(); defer { lock.unlock() }
        if meshPipeline == nil {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "forwardFlowMeshVertex")
            d.fragmentFunction = library.makeFunction(name: "forwardFlowMeshFragment")
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            // Premultiplied alpha.
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            meshPipeline = try? device.makeRenderPipelineState(descriptor: d)
        }
        return meshPipeline
    }

    func drawMesh(encoder: MTLRenderCommandEncoder, uniforms: inout MeshUniformsCPU, texture: MTLTexture, vertexCount: Int) {
        guard let pipeline = pipeline(), let sampler = mipSampler else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MeshUniformsCPU>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MeshUniformsCPU>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// Texture from a CGImage: redrawn into 8-bit premultiplied RGBA (snapshots come in formats
    /// MTKTextureLoader can't read), with mip levels for the blur near the avatar.
    static func makeTexture(device: MTLDevice, image: CGImage) -> MTLTexture? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        if let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer(),
           let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return texture
    }
}

/// CADisplayLink retains its target — the proxy breaks the cycle.
private final class DisplayLinkTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

// MARK: - Uniform layout (matches ForwardFlow.metal; all fields are float4)

struct MeshUniformsCPU {
    var view, hole, flow, extra, fade, frame, grid, tint: SIMD4<Float>
}
