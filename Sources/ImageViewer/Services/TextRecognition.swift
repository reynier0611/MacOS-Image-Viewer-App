import CoreGraphics
import Vision

/// One line of text found in an image, with its outline in normalized image coordinates
/// (0–1, origin at the bottom-left, as Vision reports them).
struct RecognizedLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let confidence: Float
    /// Corners: top-left, top-right, bottom-right, bottom-left. A quadrilateral, so slanted text is outlined tightly.
    let corners: [CGPoint]

    var bounds: CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

enum TextRecognizer {
    /// macOS's on-device OCR (the engine behind Live Text). Runs on the full-resolution image so small print is found.
    static func recognize(_ image: CGImage) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        let observations = request.results ?? []
        return observations.enumerated().compactMap { index, observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return RecognizedLine(
                id: index,
                text: candidate.string,
                confidence: candidate.confidence,
                corners: [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            )
        }
    }
}
