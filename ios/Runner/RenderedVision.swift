import CoreML
import CoreVideo
import QuartzCore
import Metal
import Vision
import simd

final class RenderedVision {
  struct Frame {
    let pose: simd_float4x4
    let timestamp: CFTimeInterval
  }

  struct Detection {
    let objectID: String
    let confidence: Float
    let bounds: CGRect
  }

  struct Prediction {
    let frame: Frame
    let detections: [Detection]
    let inferenceMilliseconds: Int
  }

  var onPrediction: ((Prediction) -> Void)?
  private var detector: (request: VNCoreMLRequest, directory: URL)?
  private let queue = DispatchQueue(label: "valmet.rendered-vision", qos: .userInitiated)
  private final class Readback {
    let available = DispatchSemaphore(value: 1)
    var buffer: MTLBuffer?
  }

  private let readbacks = [Readback(), Readback()]
  private let inferenceAvailable = DispatchSemaphore(value: 1)
  private static let sampleInterval: CFTimeInterval = 1.0 / 8
  private var nextSample: CFTimeInterval?

  func loadModel(at url: URL?, completion: @escaping (Bool) -> Void) {
    guard let url else {
      completion(false)
      return
    }
    queue.async {
      var directory: URL?
      do {
        let compiled = try MLModel.compileModel(at: url)
        directory = compiled
        let model = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        DispatchQueue.main.async {
          self.detector = (request, compiled)
          completion(true)
        }
      } catch {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        NSLog("Rendered vision model failed: %@", error.localizedDescription)
        DispatchQueue.main.async { completion(false) }
      }
    }
  }

  deinit {
    if let directory = detector?.directory { try? FileManager.default.removeItem(at: directory) }
  }

  // Called on the main thread after rendering, before presentation.
  // Use two slots for GPU readbacks. Skip frames if the model is busy.
  func capture(_ texture: MTLTexture, command: MTLCommandBuffer, frame: Frame) {
    let scheduled = nextSample ?? frame.timestamp
    guard let request = detector?.request, frame.timestamp >= scheduled,
          let readback = readbacks.first(where: { $0.available.wait(timeout: .now()) == .success }) else { return }
    let width = texture.width, height = texture.height
    let stride = ((width * 4 + 255) / 256) * 256
    let length = stride * height
    if readback.buffer?.length != length {
      readback.buffer = texture.device.makeBuffer(length: length, options: .storageModeShared)
    }
    guard let staging = readback.buffer, let blit = command.makeBlitCommandEncoder() else {
      readback.available.signal()
      return
    }
    // Keep the sampling cadence across render jitter without catching up after a stall.
    nextSample = max(scheduled + Self.sampleInterval, frame.timestamp + Self.sampleInterval / 2)
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: width, height: height, depth: 1),
              to: staging, destinationOffset: 0, destinationBytesPerRow: stride,
              destinationBytesPerImage: length)
    blit.endEncoding()
    command.addCompletedHandler { [weak self] completed in
      guard let self, completed.status == .completed,
            self.inferenceAvailable.wait(timeout: .now()) == .success else {
        readback.available.signal()
        return
      }
      self.queue.async {
        defer {
          readback.available.signal()
          self.inferenceAvailable.signal()
        }
        autoreleasepool {
          var pixelBuffer: CVPixelBuffer?
          let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            staging.contents(), stride, nil, nil, nil, &pixelBuffer
          )
          guard status == kCVReturnSuccess, let pixelBuffer else { return }
          let started = CACurrentMediaTime()
          do {
            try withExtendedLifetime(staging) {
              try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
                .perform([request])
            }
            guard let observations = request.results as? [VNRecognizedObjectObservation] else {
              NSLog("Rendered vision model did not return object observations")
              return
            }
            let detections = observations.compactMap { observation -> Detection? in
              guard let label = observation.labels.first else { return nil }
              return Detection(objectID: label.identifier, confidence: label.confidence,
                               bounds: observation.boundingBox)
            }
            let result = Prediction(frame: frame, detections: detections,
                                    inferenceMilliseconds: Int((CACurrentMediaTime() - started) * 1000))
            DispatchQueue.main.async { self.onPrediction?(result) }
          } catch {
            NSLog("Rendered vision failed: %@", error.localizedDescription)
          }
        }
      }
    }
  }
}
