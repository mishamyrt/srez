import Foundation
@preconcurrency import MLX

public struct GigaAMRNNTStepResult {
    public let logProbs: MLXArray
    public let decoderOutput: MLXArray
    public let state: GigaAMRNNTDecoderState
    public let bestToken: Int
    public let bestLogProb: Float
    public let isBlank: Bool
}

public struct GigaAMRNNTStepTiming: Sendable {
    public let decoderSec: TimeInterval
    public let jointSec: TimeInterval
    public let readbackSec: TimeInterval
    public let totalSec: TimeInterval
}

public struct GigaAMRNNTTimedStepResult {
    public let result: GigaAMRNNTStepResult
    public let timing: GigaAMRNNTStepTiming
}

public final class GigaAMRNNTHead: @unchecked Sendable {
    public let decoder: GigaAMRNNTDecoder
    public let joint: GigaAMRNNTJoint
    public let blankId: Int

    public init(store: GigaAMTensorStore, blankId: Int = 1024) throws {
        self.blankId = blankId
        self.decoder = try GigaAMRNNTDecoder(store: store, blankId: blankId)
        self.joint = try GigaAMRNNTJoint(store: store)
    }

    public func step(
        encoderOut: MLXArray,
        tokenId: Int?,
        state: GigaAMRNNTDecoderState?
    ) throws -> GigaAMRNNTStepResult {
        try stepTimed(
            encoderOut: encoderOut,
            tokenId: tokenId,
            state: state
        ).result
    }

    public func stepTimed(
        encoderOut: MLXArray,
        tokenId: Int?,
        state: GigaAMRNNTDecoderState?
    ) throws -> GigaAMRNNTTimedStepResult {
        let totalStart = Self.now()

        let decoderStart = Self.now()
        let decoderResult = try decoder.predict(tokenId: tokenId, state: state)
        let decoderSec = Self.now() - decoderStart

        let jointStart = Self.now()
        let logProbs = joint.forward(
            encoderOut: encoderOut,
            decoderOut: decoderResult.dec
        )
        let jointSec = Self.now() - jointStart

        let readbackStart = Self.now()
        let flat = logProbs.asType(Float.self).asArray(Float.self)

        guard let best = flat.enumerated().max(by: { lhs, rhs in lhs.element < rhs.element }) else {
            throw GigaAMError.invalidManifest("RNNT step produced empty log_probs")
        }

        let readbackSec = Self.now() - readbackStart
        let totalSec = Self.now() - totalStart

        return GigaAMRNNTTimedStepResult(
            result: GigaAMRNNTStepResult(
                logProbs: logProbs,
                decoderOutput: decoderResult.dec,
                state: decoderResult.state,
                bestToken: best.offset,
                bestLogProb: best.element,
                isBlank: best.offset == blankId
            ),
            timing: GigaAMRNNTStepTiming(
                decoderSec: decoderSec,
                jointSec: jointSec,
                readbackSec: readbackSec,
                totalSec: totalSec
            )
        )
    }

    private static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
