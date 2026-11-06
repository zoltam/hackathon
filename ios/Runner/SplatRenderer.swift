import MetalKit
import simd

final class SplatRenderer: NSObject, MTKViewDelegate {
  struct Uniforms {
    var viewProjection: simd_float4x4
    var screen: SIMD2<Float>
  }

  let view: MTKView
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let splats: MTLBuffer
  private var sortBuffers: [MTLBuffer] = []
  private var nextBuffer = 0
  private let inFlight = DispatchSemaphore(value: 3)
  private let count: Int
  private static let binCount = 2048
  private var bins: [Int]
  private var bucket: [Int16]
  private var positions: [SIMD4<Float>]
  private var pendingFrame: (pose: simd_float4x4, projection: simd_float4x4)?
  private var lastDraw: CFTimeInterval = 0

  init?(data: Data) {
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
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
          let splats = data.withUnsafeBytes({ bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
          }) else { return nil }
    let count = data.count / 64
    for _ in 0..<3 {
      guard let buffer = device.makeBuffer(length: count * 4, options: .storageModeShared) else { return nil }
      sortBuffers.append(buffer)
    }
    let source = splats.contents().bindMemory(to: SIMD4<Float>.self, capacity: count * 4)
    positions = (0..<count).map { source[$0 * 4] }
    bins = .init(repeating: 0, count: Self.binCount)
    bucket = .init(repeating: -1, count: count)
    self.count = count
    self.queue = queue
    self.pipeline = pipeline
    self.splats = splats
    view = MTKView(frame: .zero, device: device)
    super.init()
    view.delegate = self
    view.colorPixelFormat = format
    view.clearColor = MTLClearColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1)
    view.isPaused = true
    view.autoResizeDrawable = false
  }

  func render(pose: simd_float4x4, projection: simd_float4x4) {
    let now = CACurrentMediaTime()
    guard now - lastDraw >= 1.0 / 35 else { return }
    lastDraw = now
    pendingFrame = (pose, projection)
    view.draw()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard let (pose, projection) = pendingFrame else { return }
    pendingFrame = nil
    let size = view.bounds.size
    guard size.width > 0, size.height > 0,
          inFlight.wait(timeout: .now()) == .success else { return }
    let ratio = min(view.contentScaleFactor, 900 / max(size.width, size.height))
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
                            screen: SIMD2(Float(dimensions.width), Float(dimensions.height)))
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(splats, offset: 0, index: 0)
    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
    if sorted > 0 {
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: sorted)
    }
    encoder.endEncoding()
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

  struct Splat { float4 centerAlpha, color, covA, covB; };
  struct Uniforms { float4x4 viewProjection; float2 screen; };
  struct Pixel {
    float4 position [[position]];
    float2 local;
    float4 color;
  };

  vertex Pixel splatVertex(uint corner [[vertex_id]], uint instance [[instance_id]],
                           const device Splat *splats [[buffer(0)]],
                           const device uint *order [[buffer(1)]],
                           constant Uniforms &u [[buffer(2)]]) {
    Splat s = splats[order[instance]];
    float4 clip = u.viewProjection * float4(s.centerAlpha.xyz, 1);
    float2 uv = float2((corner & 1) ? 1 : -1, (corner & 2) ? 1 : -1) * 3.0;
    Pixel out;
    out.local = uv;
    out.color = float4(s.color.rgb, s.centerAlpha.w);
    out.position = float4(2, 2, 2, 1);
    if (clip.w <= .04) return out;
    float2 ndc = clip.xy / clip.w;
    if (any(abs(ndc) > 1.7)) return out;
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
    float2 offset = direction * (uv.x * min(sqrt(l1), 48.0)) +
        float2(-direction.y, direction.x) * (uv.y * min(sqrt(l2), 48.0));
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
