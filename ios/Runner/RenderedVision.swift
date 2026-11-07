import CoreML
import CoreGraphics
import CoreVideo
import QuartzCore
import Metal
import Vision
import simd

enum ObstacleTag {
  static let payload = "VALMET-CRATE"
  static let height: Float = 0.52
  static let side: Float = 0.50

  static func center(corners: [CGPoint], frame: RenderedVision.Frame) -> SIMD2<Float>? {
    guard corners.count == 4 else { return nil }
    let camera = frame.pose.columns.3
    guard camera.y > height else { return nil }
    let clipToWorld = (frame.projection * frame.pose.inverse).inverse
    var footprint: [SIMD2<Float>] = []
    for point in corners {
      guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
      // Vision reports normalized corners with the same bottom-left origin as Metal NDC.
      let far = clipToWorld * SIMD4(Float(point.x) * 2 - 1, Float(point.y) * 2 - 1, 1, 1)
      guard abs(far.w) > 0.000001 else { return nil }
      let ray = far / far.w - camera
      guard ray.y < -0.0001 else { return nil }
      let fraction = (height - camera.y) / ray.y
      guard (0...1).contains(fraction) else { return nil }
      let hit = camera + ray * fraction
      guard hit.x.isFinite, hit.z.isFinite else { return nil }
      footprint.append(SIMD2(hit.x, hit.z))
    }

    // Barcode corners describe the printed code inside the white border, not the crate edges.
    let edges = footprint.indices.map { index in
      simd_distance(footprint[index], footprint[(index + 1) % footprint.count])
    }
    guard let shortest = edges.min(), let longest = edges.max(),
          shortest >= side * 0.55, longest <= side * 1.2, longest <= shortest * 1.35 else { return nil }
    return footprint.reduce(.zero, +) / 4
  }
}

final class RenderedVision {
  struct Frame {
    let pose: simd_float4x4
    let projection: simd_float4x4
    let timestamp: CFTimeInterval
    var sourceSize: SIMD2<Int> = .zero

    func matchesPose(_ other: simd_float4x4) -> Bool {
      simd_distance(pose.columns.3, other.columns.3) <= 0.16 &&
        simd_dot(pose.columns.2, other.columns.2) >= 0.99 &&
        simd_dot(pose.columns.0, other.columns.0) >= 0.99
    }

    func follows(_ previous: Frame, within interval: CFTimeInterval) -> Bool {
      let gap = timestamp - previous.timestamp
      return gap > 0 && gap < interval && previous.matchesPose(pose)
    }
  }

  struct Detection {
    let objectID: String
    let confidence: Float
    let bounds: CGRect
  }

  struct Prediction {
    let frame: Frame
    let detections: [Detection]
    let obstacleCenter: SIMD2<Float>?
    let inferenceMilliseconds: Int
  }

  static func strongestDetections(_ detections: [Detection], supplemental: Bool) -> [String: Detection] {
    // Each catalog ID names one object. Keep its strongest projected observation.
    var strongest = Dictionary(detections.map { ($0.objectID, $0) }, uniquingKeysWith: {
      $0.confidence >= $1.confidence ? $0 : $1
    })
    let chairID = "boiler-room:rolling-chair"
    guard supplemental, let chair = strongest[chairID] else { return strongest }
    for id in ["red-wheel-hand-truck", "yellow-wheel-hand-truck", "black-hand-truck"] {
      guard let truck = strongest["boiler-room:" + id],
            truck.confidence >= chair.confidence + 0.20 else { continue }
      let overlap = chair.bounds.intersection(truck.bounds)
      guard !overlap.isEmpty else { continue }
      let intersection = overlap.width * overlap.height
      let union = chair.bounds.width * chair.bounds.height +
        truck.bounds.width * truck.bounds.height - intersection
      if intersection >= 0.60 * union {
        strongest.removeValue(forKey: chairID)
        break
      }
    }
    return strongest
  }

  static func matches(_ detection: Detection, to bounds: [[Float]],
                      viewProjection: simd_float4x4) -> Bool {
    guard bounds.count == 2, bounds.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
          zip(bounds[0], bounds[1]).allSatisfy({ $0.0 < $0.1 }) else { return false }

    let corners = (0..<8).map { corner in
      viewProjection * SIMD4(bounds[corner & 1][0], bounds[(corner >> 1) & 1][1],
                             bounds[(corner >> 2) & 1][2], 1)
    }
    var lower = SIMD2<Float>(repeating: .infinity)
    var upper = SIMD2<Float>(repeating: -.infinity)
    func include(_ point: SIMD4<Float>) {
      guard point.w > 0, point.z <= point.w else { return }
      // Vision and Metal NDC both measure y from the bottom.
      let projected = (SIMD2(point.x, point.y) / point.w + 1) / 2
      guard projected.x.isFinite, projected.y.isFinite else { return }
      lower = simd_min(lower, projected)
      upper = simd_max(upper, projected)
    }

    for (index, corner) in corners.enumerated() {
      if corner.z >= 0 { include(corner) }
      // Include edges that cross the near plane so close-up views stay matchable.
      for axis in [1, 2, 4] where index & axis == 0 {
        let neighbor = corners[index | axis]
        if (corner.z >= 0) != (neighbor.z >= 0) {
          let fraction = corner.z / (corner.z - neighbor.z)
          include(corner + (neighbor - corner) * fraction)
        }
      }
    }
    guard lower.x < upper.x, lower.y < upper.y else { return false }

    let viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
    let size = upper - lower
    let mapped = CGRect(x: CGFloat(lower.x), y: CGFloat(lower.y),
                        width: CGFloat(size.x), height: CGFloat(size.y))
      .intersection(viewport)
    let observed = detection.bounds.intersection(viewport)
    guard !mapped.isEmpty, !observed.isEmpty else { return false }
    // A visible fragment may be much smaller than the projected box. Require
    // overlap with the detection and allow a small registration margin.
    let overlap = mapped.insetBy(dx: -0.025, dy: -0.025).intersection(observed)
    return !overlap.isEmpty && overlap.width * overlap.height >= observed.width * observed.height * 0.25
  }

  var onPrediction: ((Prediction) -> Void)?
  var onSupplementalStopped: (() -> Void)?
  var onSupplementalPrediction: ((Prediction, Set<String>) -> Void)?
  var detectsObstacleTag = false
  private var detector: (request: VNCoreMLRequest, directory: URL)?
  private let queue = DispatchQueue(label: "valmet.rendered-vision", qos: .userInitiated)
  private lazy var barcodeRequest: VNDetectBarcodesRequest = {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    return request
  }()
  private final class Readback {
    let available = DispatchSemaphore(value: 1)
    var buffer: MTLBuffer?
  }

  private struct SupplementalContract: Decodable {
    let classes: [String]
    let thresholds: [Float]
    let topK: Int
    let approvedObjectIDs: Set<String>
    let replacesPrimaryObjectIDs: [String]?
    let input, outputBoxes, outputLogits: String

    var primaryReplacements: Set<String> { Set(replacesPrimaryObjectIDs ?? []) }

    var isValid: Bool {
      let primaryIDs = Set([
        "red-circulation-pump", "middle-circulation-pump", "wall-circulation-pump",
        "far-circulation-pump", "black-circulation-pump", "blue-inline-valve",
        "left-control-cabinet", "right-control-cabinet", "left-blue-actuator",
        "middle-blue-actuator", "right-blue-actuator",
      ].map { "boiler-room:" + $0 })
      let labels = Set(classes)
      return labels.count == classes.count && !labels.isEmpty &&
        thresholds.count == classes.count && thresholds.allSatisfy { (0...1).contains($0) } &&
        topK > 0 && !approvedObjectIDs.isEmpty &&
        approvedObjectIDs.isSubset(of: labels) &&
        primaryReplacements.count == (replacesPrimaryObjectIDs?.count ?? 0) &&
        primaryReplacements.isSubset(of: ["boiler-room:middle-blue-actuator"]) &&
        approvedObjectIDs.intersection(primaryIDs) == primaryReplacements
    }

    func accepts(_ description: MLModelDescription) -> Bool {
      guard isValid, input == "image", outputBoxes == "boxes", outputLogits == "logits",
            let image = description.inputDescriptionsByName[input]?.imageConstraint,
            image.pixelsWide == 384, image.pixelsHigh == 384,
            image.pixelFormatType == kCVPixelFormatType_32BGRA,
            let boxes = description.outputDescriptionsByName[outputBoxes]?.multiArrayConstraint,
            let logits = description.outputDescriptionsByName[outputLogits]?.multiArrayConstraint else { return false }
      return boxes.shape.map(\.intValue) == [1, 300, 4] &&
        logits.shape.map(\.intValue) == [1, 300, classes.count + 1] &&
        boxes.dataType == .float32 && logits.dataType == .float32 &&
        topK <= 300 * (classes.count + 1)
    }
  }

  private var supplemental: (request: VNCoreMLRequest, contract: SupplementalContract, generation: Int)?
  private var supplementalGeneration = 0
  private let supplementalQueue = DispatchQueue(label: "valmet.rendered-vision.supplemental", qos: .utility)
  private let supplementalReadback = Readback()

  #if targetEnvironment(simulator)
  var simulatorJourneyTarget: String?
  #endif

  func loadSupplementalModel(at compiledURL: URL, completion: ((Bool) -> Void)? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    stopSupplementalModel()
    let generation = supplementalGeneration
    #if targetEnvironment(simulator)
    let simulatorTarget = simulatorJourneyTarget
    #endif
    func reportFailure() {
      guard let completion else { return }
      DispatchQueue.main.async {
        if self.supplementalGeneration == generation { completion(false) }
      }
    }
    supplementalQueue.async {
      do {
        let configuration = MLModelConfiguration()
        if #available(iOS 16, *) {
          configuration.computeUnits = .cpuAndNeuralEngine
        } else {
          configuration.computeUnits = .cpuOnly
        }
        let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        guard let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
              let contractJSON = metadata["valmet_rf_detr_contract"],
              let contract = try? JSONDecoder().decode(SupplementalContract.self, from: Data(contractJSON.utf8)),
              contract.accepts(model.modelDescription) else {
          NSLog("Supplemental detector has an invalid contract")
          reportFailure()
          return
        }
        #if targetEnvironment(simulator)
        if let simulatorTarget, !contract.classes.contains(simulatorTarget) {
          reportFailure()
          return
        }
        #endif
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        DispatchQueue.main.async {
          guard self.supplementalGeneration == generation else { return }
          self.supplemental = (request, contract, generation)
          print("VALMET_SUPPLEMENTAL loaded=\(contract.approvedObjectIDs.count)")
          fflush(stdout)
          completion?(true)
        }
      } catch {
        NSLog("Supplemental detector failed to load: %@", error.localizedDescription)
        reportFailure()
      }
    }
  }

  func stopSupplementalModel() {
    dispatchPrecondition(condition: .onQueue(.main))
    supplementalGeneration += 1
    supplemental = nil
    onSupplementalStopped?()
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
    guard frame.timestamp >= scheduled else { return }
    let stride = ((texture.width * 4 + 255) / 256) * 256
    #if targetEnvironment(simulator)
    if simulatorJourneyTarget != nil {
      guard supplemental != nil, let blit = command.makeBlitCommandEncoder() else { return }
      nextSample = max(scheduled + Self.sampleInterval, frame.timestamp + Self.sampleInterval / 2)
      captureSupplemental(texture, command: command, blit: blit, frame: frame, stride: stride)
      blit.endEncoding()
      return
    }
    #endif
    guard let request = detector?.request,
          let readback = readbacks.first(where: { $0.available.wait(timeout: .now()) == .success }) else { return }
    let width = texture.width, height = texture.height
    let readsObstacleTag = detectsObstacleTag
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
    captureSupplemental(texture, command: command, blit: blit, frame: frame, stride: stride)
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
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            let obstacleCenter = try withExtendedLifetime(staging) {
              try handler.perform([request])
              return readsObstacleTag ? self.locateObstacle(using: handler, frame: frame) : nil
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
            let result = Prediction(frame: frame, detections: detections, obstacleCenter: obstacleCenter,
                                    inferenceMilliseconds: Int((CACurrentMediaTime() - started) * 1000))
            DispatchQueue.main.async { self.onPrediction?(result) }
          } catch {
            NSLog("Rendered vision failed: %@", error.localizedDescription)
          }
        }
      }
    }
  }

  private func captureSupplemental(_ texture: MTLTexture, command: MTLCommandBuffer,
                                   blit: MTLBlitCommandEncoder, frame: Frame, stride: Int) {
    let readback = supplementalReadback
    guard let (request, contract, generation) = supplemental,
          readback.available.wait(timeout: .now()) == .success else { return }
    let width = texture.width, height = texture.height, length = stride * texture.height
    #if targetEnvironment(simulator)
    let approved = simulatorJourneyTarget.map { Set([$0]) } ?? contract.approvedObjectIDs
    #else
    let approved = contract.approvedObjectIDs
    #endif
    if readback.buffer?.length != length {
      readback.buffer = texture.device.makeBuffer(length: length, options: .storageModeShared)
    }
    guard let staging = readback.buffer else {
      readback.available.signal()
      return
    }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: width, height: height, depth: 1),
              to: staging, destinationOffset: 0, destinationBytesPerRow: stride,
              destinationBytesPerImage: length)
    command.addCompletedHandler { [weak self] completed in
      guard let self, completed.status == .completed else {
        readback.available.signal()
        return
      }
      self.supplementalQueue.async {
        defer { readback.available.signal() }
        autoreleasepool {
          var pixelBuffer: CVPixelBuffer?
          let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            staging.contents(), stride, nil, nil, nil, &pixelBuffer
          )
          guard status == kCVReturnSuccess, let pixelBuffer else { return }
          let started = CACurrentMediaTime()
          do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            try withExtendedLifetime(staging) { try handler.perform([request]) }
            guard let features = request.results as? [VNCoreMLFeatureValueObservation] else {
              throw RFDETRDecoder.Failure.invalidOutputs
            }
            let detections = try RFDETRDecoder.decode(features, classes: contract.classes,
                                                      thresholds: contract.thresholds, topK: contract.topK)
              .filter { approved.contains($0.objectID) }
              .map { Detection(objectID: $0.objectID, confidence: $0.confidence, bounds: $0.bounds) }
            let prediction = Prediction(frame: frame, detections: detections, obstacleCenter: nil,
                                        inferenceMilliseconds: Int((CACurrentMediaTime() - started) * 1000))
            DispatchQueue.main.async {
              guard self.supplemental?.generation == generation else { return }
              self.onSupplementalPrediction?(prediction, contract.primaryReplacements)
            }
          } catch {
            NSLog("Supplemental detector disabled: %@", error.localizedDescription)
            DispatchQueue.main.async {
              if self.supplemental?.generation == generation { self.stopSupplementalModel() }
            }
          }
        }
      }
    }
  }

  private func locateObstacle(using handler: VNImageRequestHandler, frame: Frame) -> SIMD2<Float>? {
    do {
      try handler.perform([barcodeRequest])
      guard let tag = barcodeRequest.results?.first(where: { $0.payloadStringValue == ObstacleTag.payload })
      else { return nil }
      return ObstacleTag.center(corners: [tag.topLeft, tag.topRight, tag.bottomRight, tag.bottomLeft], frame: frame)
    } catch {
      NSLog("Rendered obstacle tag detection failed: %@", error.localizedDescription)
      return nil
    }
  }
}
