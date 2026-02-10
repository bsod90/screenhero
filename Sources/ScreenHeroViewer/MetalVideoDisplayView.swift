// MetalVideoDisplayView.swift
// Zero-copy Metal-based video display view

import AppKit
import CoreVideo
import Metal
import MetalKit

/// Metal-based video display view with zero-copy rendering
/// Uses CVMetalTextureCache for direct CVPixelBuffer -> MTLTexture without GPU readback
public class MetalVideoDisplayView: MTKView, MTKViewDelegate {
    // Metal objects
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    // Current frame texture and dimensions
    private var currentTexture: MTLTexture?
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    private let textureLock = NSLock()

    // Debug counters
    private var displayCallCount: UInt64 = 0
    private var drawCallCount: UInt64 = 0
    private var textureCreateSuccessCount: UInt64 = 0
    private var textureCreateFailCount: UInt64 = 0

    // Frame pacing - drop frames if we're falling behind
    private var lastDrawTime: UInt64 = 0
    private let minFrameIntervalNs: UInt64 = 8_000_000  // ~120fps max to avoid overwhelming GPU
    private var droppedFrames: UInt64 = 0

    // Render state tracking - prevent queueing frames while GPU is busy
    private var isRendering = false
    private let renderLock = NSLock()

    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        commonInit()
    }

    public convenience init(frame: NSRect) {
        self.init(frame: frame, device: MTLCreateSystemDefaultDevice())
    }

    private func commonInit() {
        guard let device = self.device else {
            print("[MetalVideoDisplayView] ERROR: No Metal device available")
            return
        }

        // Configure view for low-latency rendering
        self.delegate = self
        self.isPaused = true  // We'll call draw() manually for each frame
        self.enableSetNeedsDisplay = false
        self.autoResizeDrawable = false
        self.framebufferOnly = true
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Create command queue
        commandQueue = device.makeCommandQueue()
        commandQueue?.label = "VideoDisplayQueue"

        // Create texture cache for CVPixelBuffer -> MTLTexture
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        if status == kCVReturnSuccess {
            textureCache = cache
        } else {
            print("[MetalVideoDisplayView] ERROR: Failed to create texture cache: \(status)")
        }

        // Create render pipeline
        createPipeline()
        updateDrawableSize()
    }

    private func createPipeline() {
        guard let device = self.device else { return }

        // Load shaders from the default library
        // In a CLI app, we need to load from a compiled metallib or compile at runtime
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.main) ?? device.makeDefaultLibrary() else {
            // Fallback: Create shaders at runtime
            createPipelineWithEmbeddedShaders()
            return
        }

        guard let vertexFunction = library.makeFunction(name: "videoVertexShader"),
              let fragmentFunction = library.makeFunction(name: "videoFragmentShader") else {
            print("[MetalVideoDisplayView] ERROR: Failed to load shader functions")
            createPipelineWithEmbeddedShaders()
            return
        }

        createPipelineWithFunctions(vertexFunction: vertexFunction, fragmentFunction: fragmentFunction)
    }

    private func createPipelineWithEmbeddedShaders() {
        guard let device = self.device else { return }

        // Embedded shader source for fallback with aspect-ratio support
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float viewAspect;
            float textureAspect;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut videoVertexShader(uint vertexID [[vertex_id]],
                                            constant Uniforms& uniforms [[buffer(0)]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            float2 texCoords[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            float2 pos = positions[vertexID];

            // Calculate scale for aspect-fit rendering
            if (uniforms.textureAspect > uniforms.viewAspect) {
                // Wider video than view - letterbox (black bars top/bottom)
                float scale = uniforms.viewAspect / uniforms.textureAspect;
                pos.y *= scale;
            } else {
                // Taller video than view - pillarbox (black bars left/right)
                float scale = uniforms.textureAspect / uniforms.viewAspect;
                pos.x *= scale;
            }

            VertexOut out;
            out.position = float4(pos, 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        fragment float4 videoFragmentShader(VertexOut in [[stage_in]],
                                             texture2d<float> videoTexture [[texture(0)]]) {
            constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
            float4 color = videoTexture.sample(textureSampler, in.texCoord);
            return float4(color.rgb, 1.0);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "videoVertexShader"),
                  let fragmentFunction = library.makeFunction(name: "videoFragmentShader") else {
                print("[MetalVideoDisplayView] ERROR: Failed to create shader functions from source")
                return
            }
            createPipelineWithFunctions(vertexFunction: vertexFunction, fragmentFunction: fragmentFunction)
        } catch {
            print("[MetalVideoDisplayView] ERROR: Failed to compile shaders: \(error)")
        }
    }

    private func createPipelineWithFunctions(vertexFunction: MTLFunction, fragmentFunction: MTLFunction) {
        guard let device = self.device else { return }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoRenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("[MetalVideoDisplayView] ERROR: Failed to create pipeline state: \(error)")
        }
    }

    /// Display a CVPixelBuffer with zero-copy Metal rendering
    public func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        displayCallCount += 1

        // Check if GPU is still busy with previous frame - if so, drop this one
        renderLock.lock()
        if isRendering {
            renderLock.unlock()
            droppedFrames += 1
            if droppedFrames % 100 == 1 {
                print("[MetalVideoDisplayView] GPU busy: dropped \(droppedFrames) frames")
            }
            return
        }
        renderLock.unlock()

        // Frame pacing - drop frames if arriving too fast for GPU to handle
        let now = DispatchTime.now().uptimeNanoseconds
        if lastDrawTime > 0 && (now - lastDrawTime) < minFrameIntervalNs {
            droppedFrames += 1
            if droppedFrames % 100 == 1 {
                print("[MetalVideoDisplayView] Frame pacing: dropped \(droppedFrames) frames")
            }
            return
        }

        guard let textureCache = textureCache else {
            textureCreateFailCount += 1
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Create Metal texture from CVPixelBuffer (zero-copy if IOSurface-backed)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture = cvTexture else {
            textureCreateFailCount += 1
            if textureCreateFailCount == 1 {
                print("[MetalVideoDisplayView] ERROR: Failed to create texture from pixel buffer: \(status)")
            }
            return
        }

        guard let metalTexture = CVMetalTextureGetTexture(cvTexture) else {
            textureCreateFailCount += 1
            return
        }

        textureCreateSuccessCount += 1
        if textureCreateSuccessCount == 1 {
            print("[MetalVideoDisplayView] First frame displayed via Metal: \(width)x\(height)")
        }

        // Mark as rendering before updating texture
        renderLock.lock()
        isRendering = true
        renderLock.unlock()

        // Update current texture and dimensions thread-safely
        textureLock.lock()
        currentTexture = metalTexture
        textureWidth = width
        textureHeight = height
        textureLock.unlock()

        // Trigger immediate draw
        draw()
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle resize if needed
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateDrawableSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        let newSize = Self.drawableSize(for: bounds, backingScaleFactor: scale)
        guard drawableSize != newSize else { return }
        drawableSize = newSize
    }

    static func drawableSize(for bounds: CGRect, backingScaleFactor: CGFloat) -> CGSize {
        CGSize(
            width: max(1, bounds.width * backingScaleFactor),
            height: max(1, bounds.height * backingScaleFactor)
        )
    }

    public func draw(in view: MTKView) {
        drawCallCount += 1

        guard let commandQueue = commandQueue,
              let pipelineState = pipelineState,
              let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor else {
            // Clear rendering flag if we can't render
            renderLock.lock()
            isRendering = false
            renderLock.unlock()
            return
        }

        // Get current texture and dimensions
        textureLock.lock()
        let texture = currentTexture
        let texWidth = textureWidth
        let texHeight = textureHeight
        textureLock.unlock()

        guard let videoTexture = texture else {
            // No frame yet, just clear to black and release render lock
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                renderLock.lock()
                isRendering = false
                renderLock.unlock()
                return
            }
            encoder.endEncoding()
            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self = self else { return }
                self.renderLock.lock()
                self.isRendering = false
                self.renderLock.unlock()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // Create command buffer and encoder
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "VideoFrame"

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(videoTexture, index: 0)

        // Calculate aspect ratios for uniform buffer
        let viewSize = self.drawableSize
        let viewAspect: Float = viewSize.width > 0 && viewSize.height > 0
            ? Float(viewSize.width / viewSize.height)
            : 1.0
        let textureAspect: Float = texWidth > 0 && texHeight > 0
            ? Float(texWidth) / Float(texHeight)
            : 1.0

        // Pass uniforms to vertex shader
        var uniforms = (viewAspect: viewAspect, textureAspect: textureAspect)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)

        // Draw fullscreen quad using triangle strip (4 vertices)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.endEncoding()

        // Present and commit with completion handler to track render state
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.renderLock.lock()
            self.isRendering = false
            self.renderLock.unlock()
        }
        commandBuffer.commit()

        // Update frame pacing timestamp
        lastDrawTime = DispatchTime.now().uptimeNanoseconds
    }

    deinit {
        // Flush texture cache
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
