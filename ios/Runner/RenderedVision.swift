import CoreVideo
import QuartzCore
import Metal
import ImageIO
import Vision
import simd

struct PumpBounds {
  private let corners: [SIMD4<Float>]

  init?(_ bounds: [[Float]]) {
    guard bounds.count == 2, bounds.allSatisfy({ $0.count == 3 }),
          (0..<3).allSatisfy({ bounds[0][$0] < bounds[1][$0] }) else { return nil }
    corners = (0..<8).map { corner in
      SIMD4(bounds[corner & 1][0], bounds[(corner >> 1) & 1][1],
            bounds[(corner >> 2) & 1][2], 1)
    }
  }

  func region(transform: simd_float4x4) -> CGRect? {
    var low = SIMD2<Float>(repeating: .infinity)
    var high = SIMD2<Float>(repeating: -.infinity)
    for corner in corners {
      let clip = transform * corner
      guard clip.w > 0.10 else { return nil }
      let point = SIMD2(clip.x, clip.y) / clip.w * 0.5 + 0.5
      low = simd_min(low, point)
      high = simd_max(high, point)
    }
    let raw = CGRect(x: CGFloat(low.x), y: CGFloat(low.y),
                     width: CGFloat(high.x - low.x), height: CGFloat(high.y - low.y))
    let visible = raw.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !visible.isNull, visible.width >= 0.04, visible.height >= 0.04,
          visible.width * visible.height >= raw.width * raw.height * 0.70 else { return nil }
    return visible
  }
}

final class RenderedVision {
  struct Frame {
    let pose: simd_float4x4
    let projection: simd_float4x4
    let timestamp: CFTimeInterval
  }

  struct Target {
    let objectID: String
    let bounds: PumpBounds
    let referenceURLs: [URL]
  }

  struct Prediction {
    let frame: Frame
    let objectID: String?
    var matched: Bool { objectID != nil }
    let distance: Float
    let redFraction: Float
    let inferenceMilliseconds: Int
  }

  var onPrediction: ((Prediction) -> Void)?
  var target: Target?
  private var references: [VNFeaturePrintObservation]?
  private let queue = DispatchQueue(label: "valmet.rendered-vision", qos: .userInitiated)
  private let available = DispatchSemaphore(value: 1)
  private var lastSample = -Double.infinity
  private var staging: MTLBuffer?

  private func feature(_ handler: VNImageRequestHandler, region: CGRect? = nil) throws -> VNFeaturePrintObservation? {
    let request = VNGenerateImageFeaturePrintRequest()
    if #available(iOS 17, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }
    request.imageCropAndScaleOption = .scaleFill
    if let region { request.regionOfInterest = region }
    try handler.perform([request])
    return request.results?.first
  }

  private func redFraction(_ staging: MTLBuffer, width: Int, height: Int, stride: Int, region: CGRect) -> Float {
    let bytes = staging.contents().assumingMemoryBound(to: UInt8.self)
    let x0 = max(0, Int(region.minX * CGFloat(width)))
    let x1 = min(width, Int(region.maxX * CGFloat(width)))
    let y0 = max(0, Int((1 - region.maxY) * CGFloat(height)))
    let y1 = min(height, Int((1 - region.minY) * CGFloat(height)))
    var red = 0, total = 0
    for y in Swift.stride(from: y0, to: y1, by: 3) {
      for x in Swift.stride(from: x0, to: x1, by: 3) {
        let offset = y * stride + x * 4
        let b = Int(bytes[offset]), g = Int(bytes[offset + 1]), r = Int(bytes[offset + 2])
        if r > 60 && r - g > 20 && r - b > 15 && r * 100 > g * 118 { red += 1 }
        total += 1
      }
    }
    return Float(red) / Float(max(1, total))
  }

  // Called only on the render thread after the scene, before presentation.
  // Skip a frame when inference is busy. No readback or inference queue builds up.
  func capture(_ texture: MTLTexture, command: MTLCommandBuffer, frame: Frame) {
    guard #available(iOS 17, *), frame.timestamp - lastSample >= 0.5,
          available.wait(timeout: .now()) == .success else { return }
    guard let target, !target.referenceURLs.isEmpty,
          let region = target.bounds.region(transform: frame.projection * frame.pose.inverse) else {
      lastSample = frame.timestamp
      available.signal()
      onPrediction?(Prediction(frame: frame, objectID: nil, distance: -1,
                               redFraction: 0, inferenceMilliseconds: 0))
      return
    }
    let width = texture.width, height = texture.height
    let stride = ((width * 4 + 255) / 256) * 256
    let length = stride * height
    if staging?.length != length {
      staging = texture.device.makeBuffer(length: length, options: .storageModeShared)
    }
    guard let staging, let blit = command.makeBlitCommandEncoder() else {
      available.signal()
      return
    }
    lastSample = frame.timestamp
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: width, height: height, depth: 1),
              to: staging, destinationOffset: 0, destinationBytesPerRow: stride,
              destinationBytesPerImage: length)
    blit.endEncoding()
    command.addCompletedHandler { [weak self] completed in
      guard let self else { return }
      guard completed.status == .completed else {
        self.available.signal()
        return
      }
      self.queue.async {
        defer { self.available.signal() }
        autoreleasepool {
          var pixelBuffer: CVPixelBuffer?
          let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            staging.contents(), stride, nil, nil, nil, &pixelBuffer
          )
          guard status == kCVReturnSuccess, let pixelBuffer else { return }
          let started = CACurrentMediaTime()
          let red = self.redFraction(staging, width: width, height: height, stride: stride, region: region)
          do {
            if self.references == nil {
              self.references = try target.referenceURLs.compactMap { url in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                return try self.feature(VNImageRequestHandler(cgImage: image, orientation: .up))
              }
            }
            var closest = Float.infinity
            if red >= 0.018, let refs = self.references, !refs.isEmpty {
              let observation = try withExtendedLifetime(staging) {
                try self.feature(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up),
                                 region: region)
              }
              if let observation {
                for reference in refs {
                  var distance: Float = 0
                  try observation.computeDistance(&distance, to: reference)
                  closest = min(closest, distance)
                }
              }
            }
            let result = Prediction(frame: frame, objectID: closest <= 0.72 ? target.objectID : nil,
                                    distance: closest.isFinite ? closest : -1, redFraction: red,
                                    inferenceMilliseconds: Int((CACurrentMediaTime() - started) * 1000))
            DispatchQueue.main.async { [weak self] in self?.onPrediction?(result) }
          } catch {
            NSLog("Rendered vision failed: %@", error.localizedDescription)
          }
        }
      }
    }
  }
}
