import MetalKit
import simd

final class SplatRenderer: NSObject, MTKViewDelegate {
  struct Uniforms {
    var viewProjection: simd_float4x4
    var screen: SIMD2<Float>
    var roomSize: SIMD2<Float>
    var camera: SIMD4<Float>
  }

  let view: MTKView
  let vision = RenderedVision()
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let floorPipeline: MTLRenderPipelineState
  private let roomSize: SIMD2<Float>
  private let splats: MTLBuffer
  private var sortBuffers: [MTLBuffer] = []
  private var nextBuffer = 0
  private let inFlight = DispatchSemaphore(value: 3)
  static let bytesPerSplat = 160
  private let count: Int
  private static let binCount = 2048
  private var bins: [Int]
  private var bucket: [Int16]
  private var positions: [SIMD4<Float>]
  private var pendingFrame: RenderedVision.Frame?
  private var lastDraw: CFTimeInterval = 0

  init?(data: Data, roomSize: SIMD2<Float>) {
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
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
          let floorPipeline = try? device.makeRenderPipelineState(descriptor: floorDescriptor),
          let splats = data.withUnsafeBytes({ bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
          }) else { return nil }
    let count = data.count / Self.bytesPerSplat
    for _ in 0..<3 {
      guard let buffer = device.makeBuffer(length: count * 4, options: .storageModeShared) else { return nil }
      sortBuffers.append(buffer)
    }
    let source = splats.contents()
    positions = (0..<count).map {
      source.load(fromByteOffset: $0 * Self.bytesPerSplat, as: SIMD4<Float>.self)
    }
    bins = .init(repeating: 0, count: Self.binCount)
    bucket = .init(repeating: -1, count: count)
    self.count = count
    self.queue = queue
    self.pipeline = pipeline
    self.floorPipeline = floorPipeline
    self.roomSize = roomSize
    self.splats = splats
    view = MTKView(frame: .zero, device: device)
    super.init()
    view.delegate = self
    view.colorPixelFormat = format
    view.clearColor = MTLClearColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1)
    view.framebufferOnly = false
    view.isPaused = true
    view.autoResizeDrawable = false
  }

  func render(pose: simd_float4x4, projection: simd_float4x4) {
    let now = CACurrentMediaTime()
    guard now - lastDraw >= 1.0 / 35 else { return }
    lastDraw = now
    pendingFrame = RenderedVision.Frame(pose: pose, projection: projection, timestamp: now)
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
    let ratio = min(view.contentScaleFactor, 1200 / max(size.width, size.height))
    let dimensions = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
    if view.drawableSize != dimensions { view.drawableSize = dimensions }
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
          let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      inFlight.signal()
      return
    }
    let buffer = sortBuffers[nextBuffer]
    nextBuffer = (nextBuffer + 1) % sortBuffers.count
    let sorted = sort(pose: pose, into: buffer)
    var uniforms = Uniforms(viewProjection: projection * pose.inverse,
                            screen: SIMD2(Float(dimensions.width), Float(dimensions.height)),
                            roomSize: roomSize, camera: pose.columns.3)
    // Put an approximate floor behind the captured detail. This pass has no
    // effect on the walkability grid.
    encoder.setRenderPipelineState(floorPipeline)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(splats, offset: 0, index: 0)
    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
    if sorted > 0 {
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: sorted)
    }
    encoder.endEncoding()
    vision.capture(drawable.texture, command: command, frame: frame)
    command.present(drawable)
    command.addCompletedHandler { [inFlight] _ in inFlight.signal() }
    command.commit()
  }

  private func sort(pose: simd_float4x4, into buffer: MTLBuffer) -> Int {
    let back = pose.columns.2, origin = pose.columns.3
    let eye = SIMD3(origin.x, origin.y, origin.z)
    let forward = -SIMD3(back.x, back.y, back.z)
    let shift = simd_dot(eye, forward)
    let destination = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
    for i in bins.indices { bins[i] = 0 }
    for i in positions.indices {
      let p = positions[i]
      let depth = simd_dot(SIMD3(p.x, p.y, p.z), forward) - shift
      if depth <= 0.04 {
        bucket[i] = -1
      } else {
        let bin = min(Self.binCount - 1, Int(depth * 128))
        bucket[i] = Int16(bin)
        bins[bin] += 1
      }
    }
    var offset = 0
    for i in bins.indices.reversed() {
      let end = offset + bins[i]
      bins[i] = offset
      offset = end
    }
    for i in bucket.indices where bucket[i] >= 0 {
      let bin = Int(bucket[i])
      destination[bins[bin]] = UInt32(i)
      bins[bin] += 1
    }
    return offset
  }

  static let shader = """
  #include <metal_stdlib>
  using namespace metal;

  struct Splat { float4 centerAlpha, color, covA, covB; half sh[48]; };
  static_assert(sizeof(Splat) == 160, "Unexpected splat layout");
  struct Uniforms { float4x4 viewProjection; float2 screen, roomSize; float4 camera; };
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
    float delta = length(float2(.5 * (a - c), b));
    float l1 = halfTrace + delta, l2 = max(.25, halfTrace - delta);
    float angle = .5 * atan2(2 * b, a - c);
    float2 direction = float2(cos(angle), sin(angle));
    float2 major = direction * min(sqrt(l1), maxSigma);
    float2 minor = float2(-direction.y, direction.x) * min(sqrt(l2), maxSigma);
    float2 extent = 6 * sqrt(major * major + minor * minor) / u.screen;
    if (any(abs(ndc) > 1 + extent)) return out;

    // EGS coefficients are in the original PLY frame (x, -y, -z).
    // Real spherical harmonics in the standard 3DGS degree-3 order.
    float3 dir = normalize((s.centerAlpha.xyz - u.camera.xyz) * float3(1, -1, -1));
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
