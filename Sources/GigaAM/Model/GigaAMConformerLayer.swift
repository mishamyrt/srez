import Foundation
@preconcurrency import MLX

public final class GigaAMConformerLayer: @unchecked Sendable {
    public let fcFactor: Float

    private let normFeedForward1: GigaAMLayerNorm
    private let feedForward1: GigaAMConformerFeedForward

    private let normSelfAttention: GigaAMLayerNorm
    private let selfAttention: GigaAMRotarySelfAttention

    private let normConv: GigaAMLayerNorm
    private let conv: GigaAMConformerConvolution

    private let normFeedForward2: GigaAMLayerNorm
    private let feedForward2: GigaAMConformerFeedForward

    private let normOut: GigaAMLayerNorm

    public init(
        store: GigaAMTensorStore,
        layerIndex: Int,
        fcFactor: Float = 0.5
    ) throws {
        self.fcFactor = fcFactor

        let prefix = "model.encoder.layers.\(layerIndex)"

        normFeedForward1 = try GigaAMLayerNorm(
            store: store,
            prefix: "\(prefix).norm_feed_forward1"
        )
        feedForward1 = try GigaAMConformerFeedForward(
            store: store,
            prefix: "\(prefix).feed_forward1"
        )

        normSelfAttention = try GigaAMLayerNorm(
            store: store,
            prefix: "\(prefix).norm_self_att"
        )
        selfAttention = try GigaAMRotarySelfAttention(
            store: store,
            prefix: "\(prefix).self_attn"
        )

        normConv = try GigaAMLayerNorm(
            store: store,
            prefix: "\(prefix).norm_conv"
        )
        conv = try GigaAMConformerConvolution(
            store: store,
            prefix: "\(prefix).conv"
        )

        normFeedForward2 = try GigaAMLayerNorm(
            store: store,
            prefix: "\(prefix).norm_feed_forward2"
        )
        feedForward2 = try GigaAMConformerFeedForward(
            store: store,
            prefix: "\(prefix).feed_forward2"
        )

        normOut = try GigaAMLayerNorm(
            store: store,
            prefix: "\(prefix).norm_out"
        )
    }

    public func forward(_ input: MLXArray) -> MLXArray {
        var residual = input

        var x = normFeedForward1.forward(residual)
        x = feedForward1.forward(x)
        // MLX += mutates aliases of input; keep residual additions out of place.
        residual = add(residual, x * fcFactor)

        x = normSelfAttention.forward(residual)
        x = selfAttention.forward(x)
        residual = add(residual, x)

        x = normConv.forward(residual)
        x = conv.forward(x)
        residual = add(residual, x)

        x = normFeedForward2.forward(residual)
        x = feedForward2.forward(x)
        residual = add(residual, x * fcFactor)

        x = normOut.forward(residual)
        eval(x)

        return x
    }
}
