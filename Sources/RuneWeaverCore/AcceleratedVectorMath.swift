// Rune Weaver Core — Hardware-accelerated vector operations via Apple Accelerate.
// Modeled directly after DigUp's battle-tested Math+Apple.swift and Vectors.swift.

import Foundation
#if canImport(Accelerate)
    import Accelerate
#endif

public enum VectorModality: String, CaseIterable, Sendable {
    case text
    case image
    case audio
}

public enum AcceleratedVectorMath {
    /// Canonical embedding width; all vector legs must reference this.
    public static let dimension = 768
    /// Floor keeping Z-scores finite on uniform inputs.
    public static let zScoreFloor = 0.02
    /// Default Z-gate applied when callers omit a threshold.
    public static let defaultZGate = 2.0
    /// Minimum samples required for a modality to establish its own independent baseline.
    public static let minModalitySamples = 20

    /// Converts `count` float16s into float32s using vImage.
    public static func floats(fromHalf source: UnsafePointer<Float16>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        guard count > 0 else { return }
        #if canImport(Accelerate)
            var from = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: source),
                height: 1,
                width: vImagePixelCount(count),
                rowBytes: count * MemoryLayout<Float16>.stride
            )
            var to = vImage_Buffer(
                data: destination,
                height: 1,
                width: vImagePixelCount(count),
                rowBytes: count * MemoryLayout<Float>.stride
            )
            vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
        #else
            for index in 0 ..< count {
                destination[index] = Float(source[index])
            }
        #endif
    }

    /// Returns a unit-length copy, or nil when the norm is zero/non-finite.
    /// Normalizing both sides makes the dot product equal cosine similarity.
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == dimension else { return nil }
        var sum: Double = 0
        for value in vector {
            let dbl = Double(value)
            sum += dbl * dbl
        }
        let norm = sum.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }

    /// Computes the dot product of `count` rows (each of `dimension` floats) with `query`.
    /// Callers pass unit-normalized rows and query so the dot equals cosine.
    /// Row-major A(count×dim) times B(dim×1) gives C(count×1).
    public static func scores(
        of rows: UnsafePointer<Float>,
        count: Int,
        query: UnsafePointer<Float>,
        into scores: UnsafeMutablePointer<Float>
    ) {
        guard count > 0 else { return }
        #if canImport(Accelerate)
            vDSP_mmul(rows, 1, query, 1, scores, 1, vDSP_Length(count), 1, vDSP_Length(dimension))
        #else
            for rowIndex in 0 ..< count {
                var sum: Float = 0
                let rowOffset = rowIndex * dimension
                for colIndex in 0 ..< dimension {
                    sum += rows[rowOffset + colIndex] * query[colIndex]
                }
                scores[rowIndex] = sum
            }
        #endif
    }

    /// Computes the average score of each modality for this query. Modalities with fewer
    /// than `minModalitySamples` take the corpus-wide average.
    public static func modalityMeans(_ scores: [Float], _ modalities: [VectorModality]) -> [VectorModality: Double] {
        var sumByModality: [VectorModality: Double] = [:]
        var countByModality: [VectorModality: Int] = [:]
        for index in scores.indices {
            let modality = index < modalities.count ? modalities[index] : .text
            sumByModality[modality, default: 0] += Double(scores[index])
            countByModality[modality, default: 0] += 1
        }
        let totalCount = countByModality.values.reduce(0, +)
        let totalSum = sumByModality.values.reduce(0, +)
        let overallMean = totalSum / Double(max(totalCount, 1))
        var means: [VectorModality: Double] = [:]
        for modality in VectorModality.allCases {
            if let count = countByModality[modality], count >= minModalitySamples {
                means[modality] = (sumByModality[modality] ?? 0) / Double(count)
            } else {
                means[modality] = overallMean
            }
        }
        return means
    }

    /// Modality-centered meaning scores directly from DigUp: each vector's cosine similarity minus
    /// the average of its modality (text, image, audio), in standard deviations of all centered scores together.
    public static func modalityCenteredMeaningScores(_ scores: [Float], modalities: [VectorModality]) -> [Double] {
        guard !scores.isEmpty else { return [] }
        let means = modalityMeans(scores, modalities)
        var centered = [Double](repeating: 0, count: scores.count)
        var sumCentered: Double = 0
        for index in scores.indices {
            let modality = index < modalities.count ? modalities[index] : .text
            let diff = Double(scores[index]) - (means[modality] ?? 0)
            centered[index] = diff
            sumCentered += diff
        }
        let count = Double(scores.count)
        let mean = sumCentered / max(count, 1)
        var sqDiffSum: Double = 0
        for diff in centered {
            let delta = diff - mean
            sqDiffSum += delta * delta
        }
        let deviation = max((sqDiffSum / max(count, 1)).squareRoot(), zScoreFloor)
        return centered.map { ($0 - mean) / deviation }
    }

    /// Computes per-corpus Z-scores: (score - mean) / deviation.
    /// Floor on deviation keeps uniform inputs finite; callers gate the result.
    public static func meaningScores(_ scores: [Float]) -> [Double] {
        guard !scores.isEmpty else { return [] }
        var sum: Double = 0
        for score in scores {
            sum += Double(score)
        }
        let mean = sum / Double(scores.count)
        var sqDiffSum: Double = 0
        for score in scores {
            let diff = Double(score) - mean
            sqDiffSum += diff * diff
        }
        let deviation = max((sqDiffSum / Double(scores.count)).squareRoot(), zScoreFloor)
        return scores.map { (Double($0) - mean) / deviation }
    }
}
