import XCTest
import simd
@testable import Threei_Assignment

final class MeshBuilderTests: XCTestCase {

    /// 바닥 슬래브(-1.4m, 밀집) 아래에 유리 반사 허상 정점(-4m, 소수)이 있어도
    /// 추정 바닥은 슬래브를 골라야 한다 — 실기기 오측정 재현 케이스.
    func testEstimatedFloorYIgnoresSparseReflectionOutliers() {
        var positions: [SIMD3<Float>] = []
        for i in 0..<10 { positions.append(SIMD3(Float(i), -4.0, 0)) }          // 허상 (10개)
        for i in 0..<500 { positions.append(SIMD3(Float(i % 25), -1.4, Float(i / 25))) } // 바닥 슬래브
        for i in 0..<800 { positions.append(SIMD3(0, -1.3 + Float(i % 20) * 0.1, Float(i))) } // 벽
        let floorY = MeshBuilder.estimatedFloorY(of: positions)
        XCTAssertEqual(floorY, -1.4, accuracy: 0.11)   // 버킷 반 폭 오차 허용
    }

    func testEstimatedFloorYEmptyAndUniform() {
        XCTAssertEqual(MeshBuilder.estimatedFloorY(of: []), 0)
        // 전 정점이 한 평면이면 그 평면
        let flat = (0..<100).map { SIMD3(Float($0), -0.9, 0) }
        XCTAssertEqual(MeshBuilder.estimatedFloorY(of: flat), -0.9, accuracy: 0.11)
    }
}
