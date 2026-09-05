#if DEBUG
import XCTest
@testable import BenchMarkVideo

final class ScanDiagnosticsTests: XCTestCase {
    func testWindowPublishesMeanMaxAndClearsCounters() {
        var window = ScanDiagnosticWindow()
        window.receive(); window.receive()
        window.record(now: 10, callbackMs: 2, allowed: true)
        XCTAssertNil(window.publish(now: 10.2))
        window.record(now: 10.5, callbackMs: 8, allowed: true)
        let first = window.publish(now: 10.5)
        XCTAssertEqual(first?.received, 2)
        XCTAssertEqual(first?.processed, 2)
        XCTAssertEqual(first?.mean, 5)
        XCTAssertEqual(first?.max, 8)
        window.receive()
        window.record(now: 11, callbackMs: 1, allowed: false)
        let second = window.publish(now: 11)
        XCTAssertEqual(second?.received, 1)
        XCTAssertEqual(second?.processed, 1)
        XCTAssertEqual(second?.max, 1)
    }

    func testPauseAndFrameGapBreakContinuousTimeButPreserveLongest() {
        var window = ScanDiagnosticWindow()
        for time in [10.0, 10.25, 10.5] {
            window.record(now: time, callbackMs: 1, allowed: true)
        }
        XCTAssertEqual(window.continuousSeconds, 0.5)
        window.record(now: 10.75, callbackMs: 1, allowed: false)
        XCTAssertEqual(window.continuousSeconds, 0)
        window.record(now: 11, callbackMs: 1, allowed: true)
        window.record(now: 15, callbackMs: 1, allowed: true)
        XCTAssertEqual(window.continuousSeconds, 0)
        XCTAssertEqual(window.longestSeconds, 0.5)
        window = ScanDiagnosticWindow()
        XCTAssertEqual(window.longestSeconds, 0)
        XCTAssertNil(window.publish(now: 20))
    }
}
#endif
