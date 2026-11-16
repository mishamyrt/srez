import XCTest
import MLX
@testable import GigaAMKit

final class TensorStoreTests: XCTestCase {
    func testStoreReusesParsedHeaderForUncachedTensors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).safetensors")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = try JSONSerialization.data(withJSONObject: [
            "first": ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]],
            "second": ["dtype": "F32", "shape": [1], "data_offsets": [4, 8]]
        ])
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header)
        [Float(1.25), Float(2.5)].withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
        let store = try GigaAMTensorStore(weightsURL: url)
        // Keep payload offsets intact, but make any further header parse fail.
        data.replaceSubrange(8..<(8 + header.count), with: repeatElement(UInt8(32), count: header.count))
        try data.write(to: url)
        XCTAssertThrowsError(try SafetensorsIndex.loadHeader(url: url))
        XCTAssertEqual(try store.load("first").asArray(Float.self), [1.25])
        XCTAssertEqual(try store.load("second").asArray(Float.self), [2.5])
        store.clearCache()
        XCTAssertEqual(try store.load("first").asArray(Float.self), [1.25])
        XCTAssertThrowsError(try store.load("missing"))
        try data.dropLast().write(to: url)
        XCTAssertThrowsError(try store.load("second", cache: false))
    }
}
