import XCTest
import simd
@testable import Threei_Assignment

final class MinimapRendererTests: XCTestCase {

    func testEmptyGridCropsAroundCameraWithMargin() {
        let snap = MinimapRenderer.render(grid: OccupancyGrid(), cameraPosition: .zero, cameraHeading: 0, trajectory: [])
        XCTAssertNotNil(snap.image)
        XCTAssertEqual(snap.cropDimension, 1 + 2 * 10)   // 카메라 셀 1 + margin 10 × 2
        XCTAssertEqual(snap.image?.width, snap.cropDimension)
        XCTAssertEqual(snap.totalPoints, 0)
    }

    func testCropCoversObservedCellsAndCamera() {
        let grid = OccupancyGrid()
        grid.accumulate(points: [SIMD3(1, 0, 0)])   // 카메라(0,0)에서 x로 20셀
        let snap = MinimapRenderer.render(grid: grid, cameraPosition: .zero, cameraHeading: 0, trajectory: [])
        XCTAssertEqual(snap.cropDimension, 21 + 20)
        // 카메라(월드 원점)는 crop 안 정규화 좌표 0...1 안에 있어야 한다.
        let n = snap.normalizedPoint(.zero)
        XCTAssertTrue((0...1).contains(n.x) && (0...1).contains(n.y))
        // 관측 셀도 안에 있어야 한다.
        let m = snap.normalizedPoint(SIMD2(1, 0))
        XCTAssertTrue((0...1).contains(m.x) && m.x > n.x)
    }
}
