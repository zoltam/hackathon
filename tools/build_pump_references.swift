// Run from the repository root after tools/build_boiler_room.py.
import AppKit
import Metal
import Vision
import simd

struct Uniforms {
  var viewProjection: simd_float4x4
  var screen: SIMD2<Float>
  var roomSize: SIMD2<Float>
  var camera: SIMD4<Float>
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("assets/valmet")
let swift = try String(contentsOf: root.appendingPathComponent("ios/Runner/SplatRenderer.swift"), encoding: .utf8)
guard let shader = swift.components(separatedBy: "static let shader = \"\"\"").last?
  .components(separatedBy: "\"\"\"").first,
  let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
  fatalError("Metal and the iOS shader are required")
}
let library = try device.makeLibrary(source: shader, options: nil)

func pipeline(vertex: String, fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
  let descriptor = MTLRenderPipelineDescriptor()
  descriptor.vertexFunction = library.makeFunction(name: vertex)
  descriptor.fragmentFunction = library.makeFunction(name: fragment)
  let color = descriptor.colorAttachments[0]!
  color.pixelFormat = .rgba8Unorm
  color.isBlendingEnabled = blend
  color.sourceRGBBlendFactor = .one
  color.sourceAlphaBlendFactor = .one
  color.destinationRGBBlendFactor = .oneMinusSourceAlpha
  color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
  return try device.makeRenderPipelineState(descriptor: descriptor)
}

let splatPipeline = try pipeline(vertex: "splatVertex", fragment: "splatFragment", blend: true)
let floorPipeline = try pipeline(vertex: "floorVertex", fragment: "floorFragment", blend: false)
let data = try Data(contentsOf: assets.appendingPathComponent("boiler-room-sh.splats"), options: .mappedIfSafe)
let stride = 160
precondition(!data.isEmpty && data.count.isMultiple(of: stride))
let splats = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
let count = data.count / stride
let rows = splats.contents()
let width = 820, height = 550
let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
  pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
)
textureDescriptor.storageMode = .shared
textureDescriptor.usage = [.renderTarget]
let texture = device.makeTexture(descriptor: textureDescriptor)!
let pass = MTLRenderPassDescriptor()
pass.colorAttachments[0].texture = texture
pass.colorAttachments[0].loadAction = .clear
pass.colorAttachments[0].storeAction = .store
pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1)

struct Site: Decodable {
  struct Object: Decodable { let objectId: String; let bounds: [[Float]] }
  let width, depth: Int
  let cellSize: Float
  let objects: [Object]
}
let site = try JSONDecoder().decode(Site.self, from: Data(contentsOf: assets.appendingPathComponent("site.json")))
let target = site.objects[0]
let evaluate = CommandLine.arguments.contains("--evaluate")
let aim = SIMD3<Float>(5.943, 1.164, 2.447)
let near: Float = 0.04, far: Float = 40, zoom: Float = 1.35
let projection = simd_float4x4(columns: (
  SIMD4(zoom * Float(height) / Float(width), 0, 0, 0), SIMD4(0, zoom, 0, 0),
  SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)
))
func vector(_ p: SIMD3<Float>, _ w: Float) -> SIMD4<Float> { SIMD4(p.x, p.y, p.z, w) }

func render(eye: SIMD3<Float>, aim: SIMD3<Float>, bounds: [[Float]]) -> NSBitmapImageRep {
  let forward = simd_normalize(aim - eye)
  let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), -forward))
  let up = simd_cross(-forward, right)
  let pose = simd_float4x4(columns: (vector(right, 0), vector(up, 0), vector(-forward, 0), vector(eye, 1)))
  var uniforms = Uniforms(viewProjection: projection * pose.inverse,
                          screen: SIMD2(Float(width), Float(height)),
                          roomSize: SIMD2(Float(site.width), Float(site.depth)) * site.cellSize,
                          camera: vector(eye, 1))
  let distances = (0..<count).map { index in
    let p = rows.load(fromByteOffset: index * stride, as: SIMD4<Float>.self)
    return simd_dot(SIMD3(p.x, p.y, p.z) - eye, forward)
  }
  let indices = (0..<count).filter { distances[$0] > near }
    .sorted { distances[$0] > distances[$1] }.map(UInt32.init)
  let order = indices.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4)! }
  let command = queue.makeCommandBuffer()!
  let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
  encoder.setRenderPipelineState(floorPipeline)
  encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
  encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
  encoder.setRenderPipelineState(splatPipeline)
  encoder.setVertexBuffer(splats, offset: 0, index: 0)
  encoder.setVertexBuffer(order, offset: 0, index: 1)
  encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: indices.count)
  encoder.endEncoding()
  command.commit()
  command.waitUntilCompleted()
  precondition(command.status == .completed)

  let corners = (0..<8).map { corner -> SIMD2<Float> in
    let clip = uniforms.viewProjection * SIMD4(bounds[corner & 1][0], bounds[(corner >> 1) & 1][1],
                                               bounds[(corner >> 2) & 1][2], 1)
    return SIMD2((1 + clip.x / clip.w) * Float(width) / 2, (1 - clip.y / clip.w) * Float(height) / 2)
  }
  let minX = max(0, Int(floor(corners.map(\.x).min()!)))
  let maxX = min(width, Int(ceil(corners.map(\.x).max()!)))
  let minY = max(0, Int(floor(corners.map(\.y).min()!)))
  let maxY = min(height, Int(ceil(corners.map(\.y).max()!)))
  let w = maxX - minX, h = maxY - minY
  let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: w * 4, bitsPerPixel: 32)!
  texture.getBytes(image.bitmapData!, bytesPerRow: w * 4,
                   from: MTLRegionMake2D(minX, minY, w, h), mipmapLevel: 0)
  return image
}

let trainingEyes: [(String, SIMD3<Float>)] = [
  ("a", SIMD3(5.375, 1.50, 1.875)), ("b", SIMD3(5.125, 1.50, 1.875)),
  ("e", SIMD3(5.420, 1.53, 1.960)),
]
let references = try trainingEyes.map { name, eye in
  let image = render(eye: eye, aim: aim, bounds: target.bounds)
  try image.representation(using: .png, properties: [:])!
    .write(to: assets.appendingPathComponent("pump-reference-\(name).png"), options: .atomic)
  return image
}

if evaluate {
  func feature(_ image: NSBitmapImageRep) throws -> VNFeaturePrintObservation {
    let request = VNGenerateImageFeaturePrintRequest()
    if #available(macOS 14, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }
    request.imageCropAndScaleOption = .scaleFill
    try VNImageRequestHandler(cgImage: image.cgImage!, orientation: .up).perform([request])
    return request.results!.first!
  }
  let prints = try references.map(feature)
  let checks: [(String, SIMD3<Float>, Site.Object, Bool)] = [
    ("held-out nearby", SIMD3(5.31, 1.50, 1.96), target, true),
    ("held-out partially occluded", SIMD3(4.625, 1.50, 1.625), target, true),
    ("different red pump", SIMD3(5.375, 1.50, 1.875), site.objects[1], false),
    ("different wall pump", SIMD3(6.50, 1.50, 1.25), site.objects[2], false),
    ("blue inline valve", SIMD3(6.50, 1.50, 1.25), site.objects[5], false),
  ]
  var errors = 0
  for (name, eye, object, expected) in checks {
    let box = object.bounds
    let center = (0..<3).map { (box[0][$0] + box[1][$0]) / 2 }
    let look = SIMD3(center[0], center[1], center[2])
    let observation = try feature(render(eye: eye, aim: look, bounds: box))
    let distances = try prints.map { reference in
      var distance: Float = 0
      try observation.computeDistance(&distance, to: reference)
      return distance
    }
    let distance = distances.min()!
    let matched = distance <= 0.72
    if matched != expected { errors += 1 }
    print("\(name): distance \(String(format: "%.3f", distance)) · expected \(expected), matched \(matched)")
  }
  if errors != 0 { exit(1) }
}
