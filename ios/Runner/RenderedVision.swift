import CoreVideo
import QuartzCore
import Metal
import Vision
import simd

final class RenderedVision {
  struct Frame {
    let pose: simd_float4x4
    let projection: simd_float4x4
    let timestamp: CFTimeInterval
  }

  struct Prediction {
    let frame: Frame
    let label: String
    let confidence: Float
    let inferenceMilliseconds: Int
  }

  var onPrediction: ((Prediction) -> Void)?
  private let queue = DispatchQueue(label: "valmet.rendered-vision", qos: .userInitiated)
  private let available = DispatchSemaphore(value: 1)
  private var lastSample = -Double.infinity
  private var staging: MTLBuffer?

  // Called only on the render thread after the scene, before presentation.
  // Skip a frame when inference is busy. No readback or inference queue builds up.
  func capture(_ texture: MTLTexture, command: MTLCommandBuffer, frame: Frame) {
    guard frame.timestamp - lastSample >= 0.5,
          available.wait(timeout: .now()) == .success else { return }
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
          let request = VNClassifyImageRequest()
          let started = CACurrentMediaTime()
          do {
            try withExtendedLifetime(staging) {
              try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
            }
            guard let best = request.results?.first else { return }
            let result = Prediction(frame: frame, label: best.identifier, confidence: best.confidence,
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
