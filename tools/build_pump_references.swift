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
  var sourceRotation: simd_float3x3
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
let highQuality = CommandLine.arguments.contains("--detection-dataset-hq")
let width = highQuality ? 1440 : 820
let height = highQuality ? 960 : 550
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
  let originShift: SIMD3<Float>?
  let shRotation: [SIMD3<Float>]?
  let objects: [Object]
}
let site = try JSONDecoder().decode(Site.self, from: Data(contentsOf: assets.appendingPathComponent("site.json")))
let target = site.objects[0]
let evaluate = CommandLine.arguments.contains("--evaluate")
let evaluateCatalog = CommandLine.arguments.contains("--evaluate-catalog")
let origin = site.originShift ?? .zero
let sourceRotation = site.shRotation.map { simd_float3x3(rows: $0) } ?? matrix_identity_float3x3
let aim = origin + SIMD3<Float>(5.943, 1.164, 2.447)
let near: Float = 0.04, far: Float = 40, zoom: Float = 1.35
let projection = simd_float4x4(columns: (
  SIMD4(zoom * Float(height) / Float(width), 0, 0, 0), SIMD4(0, zoom, 0, 0),
  SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)
))
func vector(_ p: SIMD3<Float>, _ w: Float) -> SIMD4<Float> { SIMD4(p.x, p.y, p.z, w) }

func annotationBuffers() -> [MTLBuffer] {
  let memberships = (0..<count).map { i -> Int in
    let p = rows.load(fromByteOffset: i * stride, as: SIMD4<Float>.self)
    return site.objects.firstIndex { o in
      let lo = o.bounds[0], hi = o.bounds[1]
      return p.x >= lo[0] && p.x <= hi[0] && p.y >= lo[1] && p.y <= hi[1] &&
        p.z >= lo[2] && p.z <= hi[2]
    } ?? -1
  }
  return (0..<((site.objects.count + 2) / 3)).map { group in
    let buffer = device.makeBuffer(bytes: rows, length: data.count, options: .storageModeShared)!
    for (i, member) in memberships.enumerated() {
      let base = buffer.contents().advanced(by: i * stride)
      var color = SIMD4<Float>.zero
      if member >= 0 && member / 3 == group { color[member % 3] = 1 }
      base.storeBytes(of: color, toByteOffset: 16, as: SIMD4<Float>.self)
      memset(base.advanced(by: 64), 0, 96)
    }
    return buffer
  }
}

func render(eye legacyEye: SIMD3<Float>, aim: SIMD3<Float>, bounds: [[Float]]? = nil,
            masks: [MTLBuffer] = [], annotations: (([[String: Any]]) -> Void)? = nil) -> NSBitmapImageRep {
  let eye = legacyEye + origin
  let forward = simd_normalize(aim - eye)
  let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), -forward))
  let up = simd_cross(-forward, right)
  let pose = simd_float4x4(columns: (vector(right, 0), vector(up, 0), vector(-forward, 0), vector(eye, 1)))
  var uniforms = Uniforms(viewProjection: projection * pose.inverse,
                          screen: SIMD2(Float(width), Float(height)),
                          roomSize: SIMD2(Float(site.width), Float(site.depth)) * site.cellSize,
                          camera: vector(eye, 1), sourceRotation: sourceRotation)
  let distances = (0..<count).map { index in
    let p = rows.load(fromByteOffset: index * stride, as: SIMD4<Float>.self)
    return simd_dot(SIMD3(p.x, p.y, p.z) - eye, forward)
  }
  let indices = (0..<count).filter { distances[$0] > near }
    .sorted { distances[$0] > distances[$1] }.map(UInt32.init)
  let order = indices.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4)! }
  func draw(_ buffer: MTLBuffer, floor: Bool) {
    pass.colorAttachments[0].clearColor = floor
      ? MTLClearColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1)
      : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    if floor {
      encoder.setRenderPipelineState(floorPipeline)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    encoder.setRenderPipelineState(splatPipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.setVertexBuffer(order, offset: 0, index: 1)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: indices.count)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    precondition(command.status == .completed)
  }

  draw(splats, floor: true)
  if let annotations {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: width * 4, bitsPerPixel: 32)!
    let area = MTLRegionMake2D(0, 0, width, height)
    texture.getBytes(image.bitmapData!, bytesPerRow: width * 4, from: area, mipmapLevel: 0)
    var labels: [[String: Any]] = []
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for (group, mask) in masks.enumerated() {
      draw(mask, floor: false)
      pixels.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: area, mipmapLevel: 0)
      }
      for channel in 0..<3 where group * 3 + channel < site.objects.count {
        var minX = width, minY = height, maxX = 0, maxY = 0, support = 0
        for y in 0..<height {
          for x in 0..<width where pixels[(y * width + x) * 4 + channel] >= 80 {
            minX = min(x, minX); maxX = max(x, maxX)
            minY = min(y, minY); maxY = max(y, maxY)
            support += 1
          }
        }
        let w = maxX - minX + 1, h = maxY - minY + 1
        if support >= 75 && w >= 12 && h >= 12 {
          labels.append(["label": site.objects[group * 3 + channel].objectId,
                         "coordinates": ["x": Double(minX + maxX) / 2, "y": Double(minY + maxY) / 2,
                                         "width": Double(w), "height": Double(h)]])
        }
      }
    }
    annotations(labels)
    return image
  }
  guard let bounds else { fatalError("Expected a crop or annotation callback") }

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

func feature(_ image: NSBitmapImageRep) throws -> VNFeaturePrintObservation {
  let request = VNGenerateImageFeaturePrintRequest()
  if #available(macOS 14, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }
  request.imageCropAndScaleOption = .scaleFill
  try VNImageRequestHandler(cgImage: image.cgImage!, orientation: .up).perform([request])
  return request.results!.first!
}

func center(of object: Site.Object) -> SIMD3<Float> {
  let box = object.bounds
  return SIMD3((box[0][0] + box[1][0]) / 2, (box[0][1] + box[1][1]) / 2,
               (box[0][2] + box[1][2]) / 2)
}

if evaluate {
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

if evaluateCatalog {
  let catalogDir = root.appendingPathComponent("build/valmet-catalog-evaluation")
  try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
  typealias LabeledPrint = (objectID: String, observation: VNFeaturePrintObservation)
  var training: [LabeledPrint] = []
  var evaluation: [LabeledPrint] = []
  for (index, object) in site.objects.enumerated() {
    let eyeSets: [SIMD3<Float>]
    if index == 0 {
      eyeSets = trainingEyes.prefix(2).map { $0.1 } + [SIMD3(5.29, 1.49, 1.89)]
    } else if index == 1 {
      eyeSets = [SIMD3(5.375, 1.50, 1.875), SIMD3(5.46, 1.52, 1.73), SIMD3(5.18, 1.49, 1.90)]
    } else {
      eyeSets = [SIMD3(6.5, 1.50, 1.25), SIMD3(6.65, 1.48, 1.39), SIMD3(6.30, 1.55, 1.42)]
    }
    let name = object.objectId.replacingOccurrences(of: ":", with: "-")
    for (sample, eye) in eyeSets.enumerated() {
      let image = render(eye: eye, aim: center(of: object), bounds: object.bounds)
      let split = sample == 2 ? "evaluation" : "reference"
      let file = catalogDir.appendingPathComponent("\(name)-\(split)-\(sample).png")
      try image.representation(using: .png, properties: [:])!.write(to: file, options: .atomic)
      let item = (objectID: object.objectId, observation: try feature(image))
      if sample == 2 { evaluation.append(item) } else { training.append(item) }
    }
  }

  var rows: [[String: Any]] = []
  for sample in evaluation {
    var distances: [String: Float] = [:]
    for reference in training {
      var distance: Float = 0
      try sample.observation.computeDistance(&distance, to: reference.observation)
      distances[reference.objectID] = min(distance, distances[reference.objectID] ?? .infinity)
    }
    let ordered = distances.sorted { $0.value < $1.value }
    let first = ordered[0], gap = ordered[1].value - first.value
    let accepted = first.value <= 0.72 && gap >= 0.08
    print("\(sample.objectID) → \(accepted ? first.key : "unknown") · distance \(String(format: "%.3f", first.value)) · margin \(String(format: "%.3f", gap))")
    rows.append(["expectedObjectId": sample.objectID, "nearestObjectId": first.key,
                 "distance": first.value, "margin": gap, "accepted": accepted,
                 "correct": accepted && sample.objectID == first.key])
  }
  let report = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
  try report.write(to: catalogDir.appendingPathComponent("evaluation.json"), options: .atomic)
  let correct = rows.filter { $0["correct"] as? Bool == true }.count
  let wrong = rows.filter { $0["accepted"] as? Bool == true && $0["correct"] as? Bool == false }.count
  print("\(correct)/\(rows.count) correct, \(wrong) wrong accepts, \(rows.count-correct-wrong) unknown")
}

if highQuality || CommandLine.arguments.contains("--detection-dataset") {
  let output = highQuality ? "build/valmet-detection-hq" : "build/valmet-detection"
  let directory = CommandLine.arguments.first { $0.hasPrefix("--output=") }
    .map { URL(fileURLWithPath: String($0.dropFirst("--output=".count))) } ?? root.appendingPathComponent(output)
  let buffers = annotationBuffers()
  for (split, samples) in [("train", 18), ("validation", 4), ("test", 4)] {
    let folder = directory.appendingPathComponent(split)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var index: [[String: Any]] = []
    var counts: [String: Int] = [:]
    for (i, object) in site.objects.enumerated() {
      for sample in 0..<samples {
        let base: SIMD3<Float> = i < 2 ? SIMD3(5.16, 1.50, 1.73) : SIMD3(6.48, 1.50, 1.29)
        // Keep disjoint pose groups for training, validation and final test.
        let zOffset: Float = split == "train" ? 0 : split == "validation" ? 0.26 : -0.30
        let step = Float(sample)
        let eye = base + SIMD3(sin(step * 2.40) * 0.25, cos(step * 1.77) * 0.20,
                               sin(step * 1.09) * 0.16 + zOffset)
        let look = center(of: object) + SIMD3(0, sin(step * 1.6 + Float(i)) * 0.24,
                                             cos(step * 2.1 + Float(i)) * 0.26)
        let name = "\(i)-\(sample).\(highQuality ? "png" : "jpg")"
        var labels: [[String: Any]] = []
        let frame = render(eye: eye, aim: look, masks: buffers) { labels = $0 }
        guard !labels.isEmpty else { continue }
        let pixels = highQuality ? frame.representation(using: .png, properties: [:])
          : frame.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        try pixels!.write(to: folder.appendingPathComponent(name))
        index.append(["imagefilename": name, "annotation": labels])
        for label in labels.compactMap({ $0["label"] as? String }) { counts[label, default: 0] += 1 }
      }
    }
    let json = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: folder.appendingPathComponent("annotations.json"), options: .atomic)
    print("\(split): \(index.count) frames, \(counts.count) labels, \(counts.values.reduce(0,+)) boxes")
    fflush(stdout)
  }
}
