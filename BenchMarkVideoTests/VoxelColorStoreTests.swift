import XCTest
import simd
@testable import BenchMarkVideo

final class VoxelColorStoreTests: XCTestCase {

    func testFirstHitSetsThenEMABlends() {
        let store = VoxelColorStore()
        let p = SIMD3<Float>(1.02, 0.5, -0.33)
        store.accumulate(points: [ScanPoint(position: p, color: SIMD3(255, 0, 100))])
        XCTAssertEqual(store.color(at: p), SIMD3(255, 0, 100))
        store.accumulate(points: [ScanPoint(position: p, color: SIMD3(0, 0, 0))])
        XCTAssertEqual(store.color(at: p), SIMD3(191, 0, 75))   // (old×3 + new) / 4
    }

    func testCoarseFallbackCoversNearbyUnobservedPoint() {
        let store = VoxelColorStore()
        // 조밀 복셀(0.1m)은 다르지만 성긴 복셀(0.4m)은 같은 이웃 점
        store.accumulate(points: [ScanPoint(position: SIMD3(0.05, 0.05, 0.05), color: SIMD3(10, 20, 30))])
        let neighbor = SIMD3<Float>(0.35, 0.05, 0.05)
        XCTAssertEqual(store.color(at: neighbor), SIMD3(10, 20, 30))
        // 성긴 복셀 밖(다른 0.4m 칸)은 미관측
        XCTAssertNil(store.color(at: SIMD3(5, 5, 5)))
    }

    func testResetClears() {
        let store = VoxelColorStore()
        store.accumulate(points: [ScanPoint(position: .zero, color: SIMD3(1, 2, 3))])
        store.reset()
        XCTAssertNil(store.color(at: .zero))
    }
}
