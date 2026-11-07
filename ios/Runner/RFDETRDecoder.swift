import CoreGraphics
import CoreML
import Foundation
import Vision

struct RFDETRDetection {
  let objectID: String
  let confidence: Float
  let bounds: CGRect
}

enum RFDETRDecoder {
  enum Failure: Error { case invalidContract, invalidOutputs }

  private static func supported(_ type: MLMultiArrayDataType) -> Bool {
    if type == .float32 { return true }
    if #available(iOS 16.0, macOS 12.0, *) { return type == .float16 }
    return false
  }

  static func decode(_ features: [VNCoreMLFeatureValueObservation],
                     classes: [String], thresholds: [Float], topK: Int) throws -> [RFDETRDetection] {
    guard let boxes = features.first(where: { $0.featureName == "boxes" })?.featureValue.multiArrayValue,
          let logits = features.first(where: { $0.featureName == "logits" })?.featureValue.multiArrayValue else {
      throw Failure.invalidOutputs
    }
    return try decode(boxes: boxes, logits: logits, classes: classes, thresholds: thresholds, topK: topK)
  }

  static func decode(boxes: MLMultiArray, logits: MLMultiArray, classes: [String],
                     thresholds: [Float], topK: Int) throws -> [RFDETRDetection] {
    guard !classes.isEmpty, thresholds.count == classes.count, topK > 0,
          thresholds.allSatisfy({ (0...1).contains($0) }) else { throw Failure.invalidContract }
    let shape = boxes.shape.map(\.intValue)
    let columns = classes.count + 1  // Last class slot is no-object.
    guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] == 4,
          logits.shape.map(\.intValue) == [1, shape[1], columns],
          supported(boxes.dataType),
          supported(logits.dataType) else { throw Failure.invalidOutputs }

    let boxes = MLShapedArray<Float>(converting: boxes).scalars
    let logits = MLShapedArray<Float>(converting: logits).scalars
    let floor = thresholds.min()!
    var ranked: [(index: Int, score: Float)] = []
    for (index, logit) in logits.enumerated() where logit.isFinite {
      let score = 1 / (1 + exp(-logit))
      if score >= floor { ranked.append((index, score)) }
    }
    ranked.sort { lhs, rhs in
      lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
    }
    func clamp(_ x: Float) -> Float { min(max(x, 0), 1) }
    return ranked.prefix(topK).compactMap { row in
      let label = row.index % columns
      guard label < classes.count, row.score >= thresholds[label] else { return nil }
      let offset = (row.index / columns) * 4
      let x = boxes[offset], y = boxes[offset + 1], w = boxes[offset + 2], h = boxes[offset + 3]
      guard x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
      let left = clamp(x - w/2), right = clamp(x + w/2)
      let top = clamp(y - h/2), bottom = clamp(y + h/2)
      guard right > left, bottom > top else { return nil }
      return RFDETRDetection(objectID: classes[label], confidence: row.score,
                             bounds: CGRect(x: CGFloat(left), y: CGFloat(1-bottom),
                                            width: CGFloat(right-left), height: CGFloat(bottom-top)))
    }
  }
}
