import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import UIKit
import simd

final class SplatRenderer: NSObject, MTKViewDelegate {
  final class FrameCounter: @unchecked Sendable {
    private let window: Range<CFTimeInterval>
    private let lock = NSLock()
    private var frames = 0

    init(window: Range<CFTimeInterval>) { self.window = window }

    func recordCompletion(at time: CFTimeInterval) {
      if window.contains(time) { lock.withLock { frames += 1 } }
    }

    var count: Int { lock.withLock { frames } }
  }

  private struct ObstacleRendering {
    let pipeline: MTLRenderPipelineState
    let tag: MTLTexture
    let depthWrite, depthTest: MTLDepthStencilState
  }

  struct Uniforms {
    var viewProjection: simd_float4x4
    var screen: SIMD2<Float>
    var roomSize: SIMD2<Float>
    var camera: SIMD4<Float>
    var sourceRotation: simd_float3x3
  }

  let view: MTKView
  let vision = RenderedVision()
  var frameCounter: FrameCounter?
  var onFrameReady: ((simd_float4x4, simd_float4x4, CGSize) -> Void)?
  var obstacleCenter: SIMD2<Float>?
  private static let renderLimits: [CGFloat] = [900, 1200, 1440, 1800]
  private var qualityLevel = renderLimits.count - 1
  private var slowFrames = 0
  private var fastFrames = 0
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let floorPipeline: MTLRenderPipelineState
  private let routePipeline: MTLRenderPipelineState
  private let obstacleRendering: ObstacleRendering?
  private var routeBuffer: MTLBuffer?
  private var routeCount = 0
  private let routeCellSize: Float
  private let roomSize: SIMD2<Float>
  private let sourceRotation: simd_float3x3
  private let splats: MTLBuffer
  private var sortBuffers: [MTLBuffer] = []
  private var nextBuffer = 0
  // Bound GPU queue age so sampled frames stay useful while turning.
  private static let framesInFlight = 2
  private let inFlight = DispatchSemaphore(value: SplatRenderer.framesInFlight)
  static let bytesPerSplat = 160
  private let count: Int
  private static let binCount = 2048
  private static let groupSize = 64
  private var bins: [Int]
  private var bucket: [Int16]
  private let positions: [SIMD4<Float>]
  private let groups: [(center: SIMD4<Float>, extent: SIMD4<Float>)]
  private var visibleGroups: [Int]
  private var pendingFrame: (pose: simd_float4x4, projection: simd_float4x4, timestamp: CFTimeInterval)?
  private var lastDraw: CFTimeInterval = 0
  static let frameInterval: TimeInterval = 1.0 / 30

  init?(data: Data, roomSize: SIMD2<Float>, sourceRotation: simd_float3x3,
        route: [SIMD3<Float>], cellSize: Float, obstacleEnabled: Bool = false) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
    let format = MTLPixelFormat.bgra8Unorm
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "splatVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "splatFragment")
    let attachment = descriptor.colorAttachments[0]!
    attachment.pixelFormat = format
    attachment.isBlendingEnabled = true
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    let floorDescriptor = MTLRenderPipelineDescriptor()
    floorDescriptor.vertexFunction = library.makeFunction(name: "floorVertex")
    floorDescriptor.fragmentFunction = library.makeFunction(name: "floorFragment")
    floorDescriptor.colorAttachments[0].pixelFormat = format
    // The guide shares the splat pass's premultiplied alpha blend.
    let guideDescriptor = descriptor.copy() as! MTLRenderPipelineDescriptor
    guideDescriptor.vertexFunction = library.makeFunction(name: "guideVertex")
    guideDescriptor.fragmentFunction = library.makeFunction(name: "guideFragment")
    if obstacleEnabled {
      descriptor.depthAttachmentPixelFormat = .depth32Float
      floorDescriptor.depthAttachmentPixelFormat = .depth32Float
      guard let obstacle = Self.makeObstacleRendering(device: device, library: library, colorFormat: format) else {
        return nil
      }
      self.obstacleRendering = obstacle
    } else {
      self.obstacleRendering = nil
    }
    guard let routePipeline = try? device.makeRenderPipelineState(descriptor: guideDescriptor),
          let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
          let floorPipeline = try? device.makeRenderPipelineState(descriptor: floorDescriptor),
          let splats = data.withUnsafeBytes({ bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
          }) else { return nil }
    let count = data.count / Self.bytesPerSplat
    for _ in 0..<Self.framesInFlight {
      guard let buffer = device.makeBuffer(length: count * 4, options: .storageModeShared) else { return nil }
      sortBuffers.append(buffer)
    }
    let source = splats.contents()
    let positions = (0..<count).map {
      var position = source.load(fromByteOffset: $0 * Self.bytesPerSplat, as: SIMD4<Float>.self)
      position.w = 1
      return position
    }
    self.positions = positions
    groups = stride(from: 0, to: count, by: Self.groupSize).map { start in
      var low = positions[start], high = low
      for i in (start + 1)..<min(start + Self.groupSize, count) {
        low = simd_min(low, positions[i])
        high = simd_max(high, positions[i])
      }
      return ((low + high) * 0.5, (high - low) * 0.5)
    }
    visibleGroups = .init(repeating: 0, count: groups.count)
    bins = .init(repeating: 0, count: Self.binCount)
    bucket = .init(repeating: -1, count: count)
    self.count = count
    self.queue = queue
    self.pipeline = pipeline
    self.floorPipeline = floorPipeline
    self.routePipeline = routePipeline
    self.routeCellSize = cellSize
    self.roomSize = roomSize
    self.sourceRotation = sourceRotation
    self.splats = splats
    view = MTKView(frame: .zero, device: device)
    super.init()
    view.delegate = self
    view.colorPixelFormat = format
    if obstacleEnabled { view.depthStencilPixelFormat = .depth32Float }
    view.clearColor = MTLClearColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1)
    view.framebufferOnly = false
    view.isPaused = true
    view.autoResizeDrawable = false
    setRoute(route)
  }

  func setRoute(_ route: [SIMD3<Float>]) {
    let markers = Self.guideMarkers(for: route, cellSize: routeCellSize)
    routeBuffer = markers.withUnsafeBytes { bytes in
      guard !bytes.isEmpty, let base = bytes.baseAddress else { return nil }
      return view.device?.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
    }
    routeCount = markers.count
  }

  private static func makeObstacleRendering(device: MTLDevice, library: MTLLibrary,
                                            colorFormat: MTLPixelFormat) -> ObstacleRendering? {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "crateVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "crateFragment")
    descriptor.colorAttachments[0].pixelFormat = colorFormat
    descriptor.depthAttachmentPixelFormat = .depth32Float
    let depth = MTLDepthStencilDescriptor()
    depth.depthCompareFunction = .lessEqual
    depth.isDepthWriteEnabled = true
    let depthWrite = device.makeDepthStencilState(descriptor: depth)
    depth.isDepthWriteEnabled = false
    let depthTest = device.makeDepthStencilState(descriptor: depth)

    let code = CIFilter.qrCodeGenerator()
    code.message = Data(ObstacleTag.payload.utf8)
    guard let image = code.outputImage,
          let bitmap = CIContext().createCGImage(image, from: image.extent),
          let texture = try? MTKTextureLoader(device: device).newTexture(cgImage: bitmap, options: [
            .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft
          ]),
          let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
          let depthWrite, let depthTest else { return nil }
    return ObstacleRendering(pipeline: pipeline, tag: texture, depthWrite: depthWrite, depthTest: depthTest)
  }

  func render(pose: simd_float4x4, projection: simd_float4x4) {
    let now = CACurrentMediaTime()
    // Allow 1 ms of frame-clock jitter to avoid skipping every other AR frame.
    guard now - lastDraw >= Self.frameInterval - 0.001 else { return }
    pendingFrame = (pose, projection, now)
    view.draw()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard let frame = pendingFrame else { return }
    pendingFrame = nil
    let pose = frame.pose, projection = frame.projection
    let size = view.bounds.size
    guard size.width > 0, size.height > 0,
          inFlight.wait(timeout: .now()) == .success else { return }
    let ratio = min(view.contentScaleFactor, Self.renderLimits[qualityLevel] / max(size.width, size.height))
    let dimensions = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
    if view.drawableSize != dimensions { view.drawableSize = dimensions }
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
          let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      inFlight.signal()
      return
    }
    lastDraw = frame.timestamp
    let buffer = sortBuffers[nextBuffer]
    nextBuffer = (nextBuffer + 1) % sortBuffers.count
    var uniforms = Uniforms(viewProjection: projection * pose.inverse,
                            screen: SIMD2(Float(dimensions.width), Float(dimensions.height)),
                            roomSize: roomSize, camera: pose.columns.3, sourceRotation: sourceRotation)
    let sorted = sort(viewProjection: uniforms.viewProjection, screen: uniforms.screen, into: buffer)
    // Put an approximate floor behind the captured detail. This pass has no
    // effect on the walkability grid.
    encoder.setRenderPipelineState(floorPipeline)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    if let obstacle = obstacleRendering, let center = obstacleCenter {
      var placement = SIMD4(center.x, center.y, ObstacleTag.side, ObstacleTag.height)
      encoder.setRenderPipelineState(obstacle.pipeline)
      encoder.setDepthStencilState(obstacle.depthWrite)
      encoder.setVertexBytes(&placement, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
      encoder.setFragmentTexture(obstacle.tag, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 30)
      // Keep Gaussian splats back-to-front. Only the solid crate writes depth.
      encoder.setDepthStencilState(obstacle.depthTest)
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(splats, offset: 0, index: 0)
    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
    if sorted > 0 {
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: sorted)
    }
    let captureEndedScene = vision.capture(
      drawable.texture, command: command,
      frame: RenderedVision.Frame(pose: pose, projection: projection, timestamp: frame.timestamp,
                                  sourceSize: SIMD2(drawable.texture.width, drawable.texture.height)),
      endScene: encoder.endEncoding
    )
    let separateGuide = captureEndedScene || obstacleRendering != nil
    if separateGuide && !captureEndedScene { encoder.endEncoding() }
    if let routeBuffer {
      // Vision needs the scene without the guide. Other frames can share one pass.
      let guide: MTLRenderCommandEncoder?
      if separateGuide {
        let guidePass = MTLRenderPassDescriptor()
        let color = guidePass.colorAttachments[0]!
        color.texture = drawable.texture
        color.loadAction = .load
        color.storeAction = .store
        guide = command.makeRenderCommandEncoder(descriptor: guidePass)
      } else {
        guide = encoder
      }
      if let guide {
        var cellSize = routeCellSize
        var wavePhase: Float = UIAccessibility.isReduceMotionEnabled
          ? -1 : Float(frame.timestamp.truncatingRemainder(dividingBy: 3)) * (2 * .pi / 3)
        guide.setRenderPipelineState(routePipeline)
        guide.setVertexBuffer(routeBuffer, offset: 0, index: 0)
        guide.setVertexBytes(&cellSize, length: MemoryLayout<Float>.size, index: 1)
        guide.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        guide.setVertexBytes(&wavePhase, length: MemoryLayout<Float>.size, index: 3)
        guide.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: routeCount)
        if separateGuide { guide.endEncoding() }
      }
    }
    if !separateGuide { encoder.endEncoding() }
    command.present(drawable)
    command.addCompletedHandler { [weak self, inFlight, frameCounter] completed in
      inFlight.signal()
      guard completed.status == .completed else { return }
      let now = CACurrentMediaTime()
      frameCounter?.recordCompletion(at: now)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.adjustRenderQuality(frameAge: now - frame.timestamp)
        self.onFrameReady?(pose, projection, size)
      }
    }
    command.commit()
  }

  private func adjustRenderQuality(frameAge: CFTimeInterval) {
    slowFrames = frameAge > 0.12 ? slowFrames + 1 : 0
    fastFrames = frameAge < 0.04 ? fastFrames + 1 : 0
    if slowFrames >= 3, qualityLevel > 0 {
      qualityLevel -= 1
    } else if fastFrames >= 180, qualityLevel < Self.renderLimits.count - 1 {
      qualityLevel += 1
    } else {
      return
    }
    slowFrames = 0
    fastFrames = 0
  }

  static func guideMarkers(for route: [SIMD3<Float>], cellSize: Float) -> [SIMD4<Float>] {
    guard let end = route.last, cellSize > 0 else { return [] }
    let destination = SIMD4(end.x, end.z, 0, -1)
    let points = route.map { SIMD2($0.x, $0.z) }
    guard let start = points.first, points.count > 1 else { return [destination] }

    // Merge straight grid steps before rounding, so finer grids still get a visible curve.
    var corners = [start]
    for index in points.indices.dropFirst().dropLast() {
      let incoming = points[index] - points[index - 1]
      let outgoing = points[index + 1] - points[index]
      if simd_dot(incoming, outgoing) < 0.99 * simd_length(incoming) * simd_length(outgoing) {
        corners.append(points[index])
      }
    }
    corners.append(SIMD2(end.x, end.z))

    let markerSize = max(cellSize, 0.18)
    let minimumGap = markerSize * 1.12
    var path = [start]
    for index in corners.indices.dropFirst().dropLast() {
      let point = corners[index]
      let incoming = point - corners[index - 1]
      let outgoing = corners[index + 1] - point
      // Limit the curve to the turn cell and its two route neighbors.
      let trim = min(0.20, cellSize * 1.4, simd_length(incoming) * 0.45, simd_length(outgoing) * 0.45)
      guard trim > 0 else { continue }
      let entry = point - simd_normalize(incoming) * trim
      let exit = point + simd_normalize(outgoing) * trim
      for step in 0...8 {
        let t = Float(step) / 8
        let s = 1 - t
        path.append(entry * (s * s) + point * (2 * s * t) + exit * (t * t))
      }
    }
    path.append(SIMD2(end.x, end.z))

    let segments = zip(path, path.dropFirst()).compactMap { start, end -> (start: SIMD2<Float>, delta: SIMD2<Float>, length: Float)? in
      let delta = end - start
      let length = simd_length(delta)
      return length > 0 ? (start, delta, length) : nil
    }
    let ribbon = segments.map { segment in
      let center = segment.start + segment.delta / 2
      return SIMD4(center.x, center.y, atan2(segment.delta.y, segment.delta.x), segment.length / cellSize)
    }
    let totalLength = segments.reduce(Float(0)) { $0 + $1.length }
    var count = Int(totalLength / max(0.24, minimumGap))
    while count > 0 {
      let spacing = totalLength / Float(count)
      var arrows: [SIMD4<Float>] = []
      var segmentIndex = 0
      var traveled: Float = 0
      for index in 0..<count {
        let distance = Float(index) * spacing
        while segmentIndex + 1 < segments.count, distance >= traveled + segments[segmentIndex].length {
          traveled += segments[segmentIndex].length
          segmentIndex += 1
        }
        let segment = segments[segmentIndex]
        let center = segment.start + segment.delta * ((distance - traveled) / segment.length)
        arrows.append(SIMD4(center.x, center.y, atan2(segment.delta.y, segment.delta.x), 0))
      }
      let symbols = arrows + [destination]
      let overlaps = symbols.indices.contains { index in
        let a = symbols[index]
        return symbols.dropFirst(index + 1).contains { b in
          simd_distance(SIMD2(a.x, a.y), SIMD2(b.x, b.y)) < minimumGap
        }
      }
      if !overlaps { return ribbon + symbols }
      // Give every arrow more space when any pair is too close.
      count -= 1
    }
    return ribbon + [destination]
  }

  private func sort(viewProjection: simd_float4x4, screen: SIMD2<Float>, into buffer: MTLBuffer) -> Int {
    let rows = viewProjection.transpose.columns
    // Match the shader's largest projected footprint when culling before sorting.
    let maxSigma = max(screen.x, screen.y) * 0.06
    let frustum = 1 + 6 * maxSigma / screen
    let x = rows.3 * frustum.x, y = rows.3 * frustum.y
    let planes = [rows.3 - SIMD4(0, 0, 0, 0.04), x + rows.0, x - rows.0, y + rows.1, y - rows.1]
      .map { (normal: $0, absolute: abs($0)) }
    let destination = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
    for i in bins.indices { bins[i] = 0 }
    var groupCount = 0
    for index in groups.indices {
      let (center, extent) = groups[index]
      // Keep file order for stable depth-bin ties. The margin leaves boundary
      // points to the per-splat test when float arithmetic differs slightly.
      if planes.contains(where: {
        simd_dot($0.normal, center) + simd_dot($0.absolute, extent) < -0.0001
      }) { continue }
      let start = index * Self.groupSize
      visibleGroups[groupCount] = start
      groupCount += 1
      for i in start..<min(start + Self.groupSize, count) {
        let point = positions[i]
        let depth = simd_dot(rows.3, point)
        if depth <= 0.04 ||
           abs(simd_dot(rows.0, point)) > depth * frustum.x ||
           abs(simd_dot(rows.1, point)) > depth * frustum.y {
          bucket[i] = -1
        } else {
          let bin = min(Self.binCount - 1, Int(depth * 128))
          bucket[i] = Int16(bin)
          bins[bin] += 1
        }
      }
    }
    var offset = 0
    for i in bins.indices.reversed() {
      let end = offset + bins[i]
      bins[i] = offset
      offset = end
    }
    for start in visibleGroups.prefix(groupCount) {
      for i in start..<min(start + Self.groupSize, count) where bucket[i] >= 0 {
        let bin = Int(bucket[i])
        destination[bins[bin]] = UInt32(i)
        bins[bin] += 1
      }
    }
    return offset
  }

  static let shader = """
  #include <metal_stdlib>
  using namespace metal;

  struct Splat { float4 centerAlpha, color, covA, covB; half sh[48]; };
  static_assert(sizeof(Splat) == 160, "Unexpected splat layout");
  struct Uniforms { float4x4 viewProjection; float2 screen, roomSize; float4 camera; float3x3 sourceRotation; };
  struct FloorPixel { float4 position [[position]]; float2 world; };

  vertex FloorPixel floorVertex(uint corner [[vertex_id]], constant Uniforms &u [[buffer(2)]]) {
    // Carry the backing surface slightly under the walls to avoid a seam.
    float2 ground = float2(corner & 1, (corner >> 1) & 1) * (u.roomSize + 4.0) - 2.0;
    FloorPixel out;
    out.position = u.viewProjection * float4(ground.x, -.16, ground.y, 1);
    out.world = ground;
    return out;
  }

  float floorHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
  }

  float floorNoise(float2 p) {
    float2 i = floor(p), f = smoothstep(0.0, 1.0, fract(p));
    return mix(mix(floorHash(i), floorHash(i + float2(1,0)), f.x),
               mix(floorHash(i + float2(0,1)), floorHash(i + 1), f.x), f.y);
  }

  fragment float4 floorFragment(FloorPixel in [[stage_in]]) {
    float2 p = in.world;
    float tone = .80 + .16 * floorNoise(p * 1.3) + .10 * floorNoise(p * 12) + .04 * floorNoise(p * 43);
    return float4(float3(.56, .49, .39) * tone, 1);
  }
  struct CratePixel {
    float4 position [[position]];
    float2 uv;
    uint face [[flat]];
  };

  vertex CratePixel crateVertex(uint index [[vertex_id]],
                                constant float4 &placement [[buffer(0)]],
                                constant Uniforms &u [[buffer(2)]]) {
    const float2 corners[] = {
      float2(0, 0), float2(0, 1), float2(1, 0),
      float2(1, 0), float2(0, 1), float2(1, 1)
    };
    const float2 right[] = { float2(1, 0), float2(0, -1), float2(-1, 0), float2(0, 1) };
    float2 uv = corners[index % 6];
    uint face = index / 6;
    float2 p = uv * 2.0 - 1.0;
    float y = placement.w;
    if (face < 4) {
      float2 side = right[face];
      p = float2(-side.y, side.x) + side * p.x;
      y *= 1.0 - uv.y;
    }
    p = placement.xy + p * placement.z * .5;
    return { u.viewProjection * float4(p.x, y, p.y, 1), uv, face };
  }

  fragment float4 crateFragment(CratePixel in [[stage_in]],
                                texture2d<float> tag [[texture(0)]]) {
    if (in.face == 4) {
      constexpr sampler modules(coord::normalized, filter::nearest, address::clamp_to_edge);
      // The white inset provides a quiet zone around the QR modules.
      const float2 qr = (in.uv - .12) / .76;
      float value = all(qr >= 0.0) && all(qr <= 1.0) ? tag.sample(modules, qr).r : 1.0;
      return float4(float3(value), 1);
    }
    float2 edge = min(in.uv, 1.0 - in.uv);
    float shade = in.face % 2 == 0 ? .90 : .73;
    float seam = 1.0 - smoothstep(.009, .014, abs(in.uv.y - .52));
    float frame = 1.0 - smoothstep(.035, .043, min(edge.x, edge.y));
    float3 oak = float3(.66, .45, .25) * shade;
    return float4(mix(oak, float3(.26, .16, .09), max(frame, seam * .45)), 1);
  }

  struct GuidePixel {
    float4 position [[position]];
    float2 local;
    float ribbonLength [[flat]];
    float brightness [[flat]];
  };

  vertex GuidePixel guideVertex(uint corner [[vertex_id]], uint index [[instance_id]],
                                const device float4 *markers [[buffer(0)]],
                                constant float &cellSize [[buffer(1)]],
                                constant Uniforms &u [[buffer(2)]],
                                constant float &wavePhase [[buffer(3)]]) {
    float4 marker = markers[index];
    float2 forward = float2(cos(marker.z), sin(marker.z));
    float2 right = float2(-forward.y, forward.x);
    float2 local = float2(corner & 1, (corner >> 1) & 1) * 2.0 - 1.0;
    float2 extent = marker.w > 0 ? float2(.11, marker.w * .5 + .11) : float2(.43);
    float2 offset = local * extent;
    const bool arrow = marker.w == 0.0;
    if (arrow) { offset.x *= 1.08; }
    float brightness = arrow && wavePhase >= 0.0 ? .5 + .5 * sin(float(index) * .85 - wavePhase) : -1.0;
    float scale = marker.w > 0 ? cellSize : max(cellSize, .18);
    float2 p = marker.xy + (right * offset.x + forward * offset.y) * scale;
    return { u.viewProjection * float4(p.x, .035, p.y, 1),
             marker.w > 0 ? offset : local, marker.w, brightness };
  }

  float guideSegment(float2 p, float2 a, float2 b) {
    float2 edge = b - a;
    return length(p - a - edge * clamp(dot(p - a, edge) / dot(edge, edge), 0.0, 1.0));
  }

  fragment float4 guideFragment(GuidePixel in [[stage_in]]) {
    float2 p = in.local;
    float distance;
    float3 ink;
    float border = .12;
    if (in.ribbonLength > 0) {
      distance = length(float2(p.x, max(abs(p.y) - in.ribbonLength * .5, 0.0))) - .036;
      ink = float3(.27, .78, .64);
      float aa = clamp(fwidth(distance), .005, .018);
      float alpha = 1.0 - smoothstep(-aa, aa, distance);
      return float4(ink * alpha, alpha);
    } else if (in.ribbonLength < 0) {
      float radius = length(p);
      distance = min(abs(radius - .64) - .12, radius - .23);
      ink = float3(1.0, .80, .31);
    } else {
      float2 tip = float2(0, .62);
      distance = guideSegment(float2(abs(p.x), p.y), tip, float2(.59, -.30)) - .17;
      ink = in.brightness < 0.0 ? float3(.37, .955, .765) :
        mix(float3(.20, .68, .54), float3(.68, 1.0, .94), in.brightness);
      border = .08;
    }
    float aa = clamp(fwidth(distance), .005, border);
    float fill = 1.0 - smoothstep(-aa, aa, distance);
    float alpha = 1.0 - smoothstep(-aa, aa, distance - border);
    float3 outline = float3(.025, .12, .10);
    return float4(mix(outline * alpha, ink, fill), alpha);
  }

  struct Pixel {
    float4 position [[position]];
    float2 local;
    float4 color;
  };

  vertex Pixel splatVertex(uint corner [[vertex_id]], uint instance [[instance_id]],
                           const device Splat *splats [[buffer(0)]],
                           const device uint *order [[buffer(1)]],
                           constant Uniforms &u [[buffer(2)]]) {
    const device Splat &s = splats[order[instance]];
    float4 clip = u.viewProjection * float4(s.centerAlpha.xyz, 1);
    float2 uv = float2((corner & 1) ? 1 : -1, (corner & 2) ? 1 : -1) * 3.0;
    Pixel out;
    out.local = uv;
    out.color = 0;
    out.position = float4(2, 2, 2, 1);
    if (clip.w <= .04) return out;
    float2 ndc = clip.xy / clip.w;
    // Reject only if even the largest allowed footprint misses the screen.
    const float maxSigma = max(u.screen.x, u.screen.y) * .06;
    if (any(abs(ndc) > 1 + 6 * maxSigma / u.screen)) return out;

    const float4x4 m = u.viewProjection;
    float3 rw = float3(m[0].w, m[1].w, m[2].w);
    float3 jx = (float3(m[0].x, m[1].x, m[2].x) - ndc.x * rw) * (.5 * u.screen.x / clip.w);
    float3 jy = (float3(m[0].y, m[1].y, m[2].y) - ndc.y * rw) * (.5 * u.screen.y / clip.w);
    float3x3 cov = float3x3(float3(s.covA.x, s.covA.y, s.covA.z),
                           float3(s.covA.y, s.covA.w, s.covB.x),
                           float3(s.covA.z, s.covB.x, s.covB.y));
    float a = dot(jx, cov * jx) + .3;
    float b = dot(jx, cov * jy);
    float c = dot(jy, cov * jy) + .3;
    float halfTrace = .5 * (a + c);
    float halfDifference = .5 * (a - c);
    float delta = length(float2(halfDifference, b));
    float l1 = halfTrace + delta, l2 = max(.25, halfTrace - delta);
    // Choose the eigenvector form that avoids subtracting nearly equal values.
    float2 axis = halfDifference >= 0 ? float2(delta + halfDifference, b)
                                     : float2(b, delta - halfDifference);
    float2 direction = delta > 0 ? normalize(axis) : float2(1, 0);
    float2 major = direction * min(sqrt(l1), maxSigma);
    float2 minor = float2(-direction.y, direction.x) * min(sqrt(l2), maxSigma);
    float2 extent = 6 * sqrt(major * major + minor * minor) / u.screen;
    if (any(abs(ndc) > 1 + extent)) return out;

    // EGS coefficients are in the original PLY frame (x, -y, -z).
    // Real spherical harmonics in the standard 3DGS degree-3 order.
    float3 dir = normalize(u.sourceRotation * ((s.centerAlpha.xyz - u.camera.xyz) * float3(1, -1, -1)));
    float x = dir.x, y = dir.y, z = dir.z;
    float xx = x*x, yy = y*y, zz = z*z;
    float shBasis[15] = {
      -.488602512*y, .488602512*z, -.488602512*x,
      1.092548431*x*y, -1.092548431*y*z, .315391565*(3*zz-1),
      -1.092548431*x*z, .546274215*(xx-yy),
      -.590043590*y*(3*xx-yy), 2.890611443*x*y*z, -.457045799*y*(5*zz-1),
      .373176333*z*(5*zz-3), -.457045799*x*(5*zz-1),
      1.445305721*z*(xx-yy), -.590043590*x*(xx-3*yy)
    };
    float3 rgb = s.color.rgb;
    for (uint i = 0; i < 15; ++i) {
      rgb += float3(s.sh[i], s.sh[15+i], s.sh[30+i]) * shBasis[i];
    }
    out.color = float4(saturate(rgb), s.centerAlpha.w);

    float2 offset = major * uv.x + minor * uv.y;
    out.position = float4(clip.xy + 2 * offset * clip.w / u.screen, clip.zw);
    return out;
  }

  fragment float4 splatFragment(Pixel in [[stage_in]]) {
    float r2 = dot(in.local, in.local);
    if (r2 > 9) discard_fragment();
    float alpha = min(.995, in.color.a * exp(-.5 * r2));
    if (alpha < .004) discard_fragment();
    return float4(in.color.rgb * alpha, alpha);
  }
  """
}
