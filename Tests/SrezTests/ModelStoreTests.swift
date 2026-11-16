import XCTest
@testable import Srez

final class ModelStoreTests: XCTestCase {
    func testRecognizerIsReusedUntilQueueUnloadsIt() async throws {
        let directory = try modelFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = PreparationCalls()
        let store = ModelStore { _ in await calls.prepare(directory) }
        let first = try await store.load(update: { _ in })
        let second = try await store.load(update: { _ in })
        XCTAssertTrue(first === second)
        let initialCalls = await calls.count
        XCTAssertEqual(initialCalls, 1)
        await store.unload()
        let third = try await store.load(update: { _ in })
        XCTAssertFalse(first === third)
        let totalCalls = await calls.count
        XCTAssertEqual(totalCalls, 2)
    }

    private actor PreparationCalls {
        var count = 0
        func prepare(_ directory: URL) -> URL { count += 1; return directory }
    }

    // Initialization needs tensor names and ranks, but no inference-sized weights.
    private func modelFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": "test", "bundle_id": "test", "source_model": "test", "source_revision": "test",
            "architecture": "test", "precision": "F32", "runtime": "MLX", "sample_rate": 16_000,
            "channels": 1, "weights_file": "weights.safetensors", "tokenizer_file": "tokenizer.model",
            "target_platforms": ["macOS"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try Data().write(to: directory.appendingPathComponent("tokenizer.model"))
        try JSONSerialization.data(withJSONObject: ["pieces": ["<unk>"], "unk_id": 0])
            .write(to: directory.appendingPathComponent("tokenizer_vocab.json"))
        for (name, count) in [("hann_window.f32.bin", 320), ("mel_filterbank_mel_freq.f32.bin", 64 * 161)] {
            try [Float](repeating: 1, count: count).withUnsafeBytes {
                try Data($0).write(to: directory.appendingPathComponent(name))
            }
        }
        var names = ["model.encoder.pre_encode.conv.0", "model.encoder.pre_encode.conv.2"]
            .flatMap { [$0 + ".weight", $0 + ".bias"] }
        for layer in 0..<16 {
            let modules = ["norm_feed_forward1", "norm_self_att", "norm_conv", "norm_feed_forward2", "norm_out",
                           "feed_forward1.linear1", "feed_forward1.linear2", "feed_forward2.linear1", "feed_forward2.linear2",
                           "self_attn.linear_q", "self_attn.linear_k", "self_attn.linear_v", "self_attn.linear_out",
                           "conv.pointwise_conv1", "conv.depthwise_conv", "conv.batch_norm", "conv.pointwise_conv2"]
            names += modules.flatMap { ["model.encoder.layers.\(layer).\($0).weight", "model.encoder.layers.\(layer).\($0).bias"] }
        }
        names += ["embed.weight", "lstm.weight_ih_l0", "lstm.weight_hh_l0", "lstm.bias_ih_l0", "lstm.bias_hh_l0"]
            .map { "model.head.decoder." + $0 }
        names += ["enc", "pred", "joint_net.1"].flatMap { ["model.head.joint.\($0).weight", "model.head.joint.\($0).bias"] }
        let header = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            (name, ["dtype": "F32", "shape": [1, 1, 1], "data_offsets": [index * 4, (index + 1) * 4]] as [String: Any])
        })
        let json = try JSONSerialization.data(withJSONObject: header)
        var length = UInt64(json.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(json)
        data.append(Data(repeating: 0, count: names.count * 4))
        try data.write(to: directory.appendingPathComponent("weights.safetensors"))
        return directory
    }

    private let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testDownloadReuseAndRepairRejectIncompleteFiles() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let cached = directory.appendingPathComponent("model.bin")
        let temporary = directory.appendingPathComponent("download.tmp")

        func install(body: String, status: Int = 200) async throws {
            try await ModelStore.installFile(named: "model.bin", checksum: checksum, in: directory) { url in
                try Data(body.utf8).write(to: temporary)
                return (temporary, try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil
                )))
            }
        }

        try await install(body: "abc")
        XCTAssertEqual(try String(contentsOf: cached), "abc")
        XCTAssertFalse(fm.fileExists(atPath: temporary.path))
        try await ModelStore.installFile(named: "model.bin", checksum: checksum, in: directory) { _ in
            XCTFail("A verified model must be usable offline")
            throw URLError(.notConnectedToInternet)
        }

        // A damaged cache must be repaired, and a failed download must never replace it.
        try Data("damaged".utf8).write(to: cached)
        for (body, status) in [("ab", 200), ("abc", 404)] {
            do {
                try await install(body: body, status: status)
                XCTFail("Invalid download was accepted")
            } catch { XCTAssertTrue(error is MeetingError) }
            XCTAssertEqual(try String(contentsOf: cached), "damaged")
            XCTAssertFalse(fm.fileExists(atPath: temporary.path))
        }
        try await install(body: "abc")
        XCTAssertEqual(try String(contentsOf: cached), "abc")
    }

    func testCancelledDownloadDoesNotInstallFile() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let task = Task {
            try await ModelStore.installFile(named: "model.bin", checksum: checksum, in: directory) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
