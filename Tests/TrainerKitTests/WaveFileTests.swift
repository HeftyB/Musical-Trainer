import XCTest
@testable import TrainerKit

/// The renderer exists so a backing can be judged by ear without booking a live run.
///
/// A file that will not open is worse than no file: the groove would be blamed for a bug in the
/// writer. So the header is checked field by field rather than by whether it happens to play.
final class WaveFileTests: XCTestCase {
    private var url = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        try super.setUpWithError()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-\(UUID().uuidString).wav")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
        try super.tearDownWithError()
    }

    private func read(_ data: Data, _ offset: Int, _ bytes: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in (0..<bytes).reversed() { value = value << 8 | UInt32(data[offset + i]) }
        return value
    }

    private func text(_ data: Data, _ offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    func testTheHeaderSaysWhatTheFileActuallyIs() throws {
        let samples = [Float](repeating: 0.5, count: 1_000)
        _ = try WaveFile.write(samples, sampleRate: 44_100, to: url)
        let data = try Data(contentsOf: url)

        XCTAssertEqual(text(data, 0), "RIFF")
        XCTAssertEqual(text(data, 8), "WAVE")
        XCTAssertEqual(text(data, 12), "fmt ")
        XCTAssertEqual(read(data, 16, 4), 16, "PCM fmt chunk is 16 bytes")
        XCTAssertEqual(read(data, 20, 2), 1, "format 1 is uncompressed PCM")
        XCTAssertEqual(read(data, 22, 2), 1, "mono")
        XCTAssertEqual(read(data, 24, 4), 44_100)
        XCTAssertEqual(read(data, 28, 4), 88_200, "byte rate is rate × channels × bytes")
        XCTAssertEqual(read(data, 32, 2), 2, "block align")
        XCTAssertEqual(read(data, 34, 2), 16, "bits per sample")
        XCTAssertEqual(text(data, 36), "data")

        XCTAssertEqual(read(data, 40, 4), UInt32(samples.count * 2))
        XCTAssertEqual(data.count, 44 + samples.count * 2, "44-byte header plus the samples")
        XCTAssertEqual(read(data, 4, 4), UInt32(36 + samples.count * 2),
                       "the RIFF size counts everything after itself")
    }

    func testSamplesSurviveTheRoundTrip() throws {
        _ = try WaveFile.write([0, 1, -1, 0.5], sampleRate: 44_100, to: url)
        let data = try Data(contentsOf: url)

        func sample(_ index: Int) -> Int16 {
            Int16(bitPattern: UInt16(read(data, 44 + index * 2, 2)))
        }
        XCTAssertEqual(sample(0), 0)
        XCTAssertEqual(sample(1), 32_767)
        XCTAssertEqual(sample(2), -32_767)
        XCTAssertEqual(sample(3), 16_383, accuracy: 1)
    }

    /// Clipping has to be counted, not silently limited. A groove rendered too hot would be
    /// judged as a bad groove rather than a bad gain — and the whole point is judging by ear.
    func testClippingIsReportedRatherThanHidden() throws {
        let clipped = try WaveFile.write([0.5, 1.5, -2.0, 0.1], sampleRate: 44_100, to: url)
        XCTAssertEqual(clipped, 2)

        let clean = try WaveFile.write([0.5, -0.5], sampleRate: 44_100, to: url)
        XCTAssertEqual(clean, 0)
    }

    func testAnEmptyRenderIsStillAValidFile() throws {
        _ = try WaveFile.write([], sampleRate: 44_100, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(read(data, 40, 4), 0)
    }
}
