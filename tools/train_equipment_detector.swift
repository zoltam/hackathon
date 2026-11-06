// From repo root: swiftc -O tools/train_equipment_detector.swift -o /tmp/train-equipment
// Run the executable after build_pump_references --detection-dataset.
import Combine
import CoreML
import CreateML
import Foundation
import ImageIO
import Vision

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let arguments = Array(CommandLine.arguments.dropFirst())
func value(for option: String) -> String? {
  arguments.first(where: { $0.hasPrefix(option + "=") }).map { String($0.dropFirst(option.count + 1)) }
}
let dataset = value(for: "--dataset").map { URL(fileURLWithPath: $0) } ??
  root.appendingPathComponent("build/valmet-detection-hq")
let output = value(for: "--model").map { URL(fileURLWithPath: $0) } ??
  root.appendingPathComponent("assets/valmet/equipment-detector.mlmodel")
let iterations = arguments.compactMap(Int.init).first ?? 600
let split = value(for: "--split") ?? "validation"
guard ["validation", "test"].contains(split) else { fatalError("Unknown evaluation split") }
let annotation: MLObjectDetector.AnnotationType = .boundingBox()
setbuf(stdout, nil)

if let path = value(for: "--checkpoint-dir") {
  let directory = URL(fileURLWithPath: path)
  let session = try MLObjectDetector.restoreTrainingSession(
    sessionParameters: MLTrainingSessionParameters(sessionDirectory: directory)
  )
  let snapshots = session.checkpoints
  let selected = value(for: "--checkpoint-iteration").flatMap(Int.init)
  guard let snapshot = snapshots.filter({ selected == nil || $0.iteration == selected })
    .max(by: { $0.iteration < $1.iteration }) else { fatalError("No matching detector checkpoint") }
  let detector = try MLObjectDetector(checkpoint: snapshot)
  try detector.write(to: output)
  print("Exported \(output.lastPathComponent)")
} else if !arguments.contains("--evaluate-only") {
  let parameters = MLObjectDetector.ModelParameters(
    validation: .dataSource(.directoryWithImagesAndJsonAnnotation(at: dataset.appendingPathComponent("validation"))),
    batchSize: 8,
    maxIterations: iterations,
    algorithm: .transferLearning(.objectPrint())
  )
  let checkpoints = value(for: "--session").map { URL(fileURLWithPath: $0) } ??
    dataset.appendingPathComponent("checkpoints-\(iterations)")
  let session = MLTrainingSessionParameters(sessionDirectory: checkpoints, reportInterval: 10,
    checkpointInterval: max(25, iterations / 4), iterations: iterations)
  let job = try MLObjectDetector.train(
    trainingData: .directoryWithImagesAndJsonAnnotation(at: dataset.appendingPathComponent("train")),
    annotationType: annotation, parameters: parameters, sessionParameters: session
  )
  let phase = job.phase.sink { print("VALMET_TRAIN phase=\($0)") }
  let checkpoint = job.checkpoints.sink {
    print("VALMET_TRAIN checkpoint=\($0.iteration) phase=\($0.phase) metrics=\($0.metrics)")
  }
  var outcome: Result<MLObjectDetector, Error>?
  let completion = job.result.receive(on: DispatchQueue.main).sink(receiveCompletion: {
    if case let .failure(error) = $0 { outcome = .failure(error) }
  }, receiveValue: { outcome = .success($0) })
  withExtendedLifetime((phase, checkpoint, completion)) {
    while outcome == nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15)) }
  }
  let detector = try outcome!.get()
  print("VALMET_TRAIN validation-map50=\(detector.validationMetrics.meanAveragePrecision.IoU50)")
  try detector.write(to: output)
  print("Exported \(output.lastPathComponent)")
}

struct Box: Decodable {
  struct Coordinates: Decodable { let x, y, width, height: CGFloat }
  let label: String
  let coordinates: Coordinates
  func normalized(width: CGFloat, height: CGFloat) -> CGRect {
    let c = coordinates
    return CGRect(x: (c.x - c.width / 2) / width, y: 1 - (c.y + c.height / 2) / height,
                  width: c.width / width, height: c.height / height)
  }
}
struct LabeledImage: Decodable { let imagefilename: String; let annotation: [Box] }
func iou(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
  let overlap = lhs.intersection(rhs)
  if overlap.isNull { return 0 }
  let area = overlap.width * overlap.height
  return area / (lhs.width * lhs.height + rhs.width * rhs.height - area)
}
let test = value(for: "--evaluation-directory").map { URL(fileURLWithPath: $0) } ??
  dataset.appendingPathComponent(split)
let partialLabels = arguments.contains("--partial-labels")
let labels = try JSONDecoder().decode([LabeledImage].self, from: Data(contentsOf: test.appendingPathComponent("annotations.json")))
let compiled = try MLModel.compileModel(at: output)
let config = MLModelConfiguration()
let model = try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: config))
let request = VNCoreMLRequest(model: model)
request.imageCropAndScaleOption = .scaleFill
var truePositive = 0, falsePositive = 0, falseNegative = 0
var support: [String: Int] = [:], correct: [String: Int] = [:]
for image in labels {
  let url = test.appendingPathComponent(image.imagefilename)
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
        let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
    fatalError("Could not read image dimensions for \(url.lastPathComponent)")
  }
  let handler = VNImageRequestHandler(url: url, orientation: .up)
  try handler.perform([request])
  let observations = (request.results as? [VNRecognizedObjectObservation] ?? [])
    .sorted { ($0.labels.first?.confidence ?? 0) > ($1.labels.first?.confidence ?? 0) }
  var used = Set<Int>()
  for box in image.annotation { support[box.label, default: 0] += 1 }
  for observation in observations {
    guard let label = observation.labels.first, label.confidence >= 0.25 else { continue }
    if partialLabels && !image.annotation.contains(where: { $0.label == label.identifier }) { continue }
    let possible = image.annotation.indices.filter { !used.contains($0) && image.annotation[$0].label == label.identifier }
    let pairs = possible.map { ($0, iou(observation.boundingBox, image.annotation[$0].normalized(width: width, height: height))) }
    if let (index, overlap) = pairs.max(by: { $0.1 < $1.1 }), overlap >= 0.5 {
      used.insert(index)
      truePositive += 1
      correct[label.identifier, default: 0] += 1
    } else {
      falsePositive += 1
    }
  }
  falseNegative += image.annotation.count - used.count
}
for label in support.keys.sorted() { print("\(label): \(correct[label, default: 0])/\(support[label]!)") }
if partialLabels { print("Partial labels: predictions for unannotated classes are ignored.") }
print("Held-out \(partialLabels ? "partial-camera" : "rendered") \(split) · \(labels.count) frames · TP \(truePositive) FP \(falsePositive) FN \(falseNegative) · IoU ≥ 0.50")
if truePositive == 0 { exit(1) }
