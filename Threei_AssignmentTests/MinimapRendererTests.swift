import XCTest
import simd
@testable import Threei_Assignment

final class MinimapRendererTests: XCTestCase {

    func testEmptyGridCropsAroundCameraWithMargin() {
        let snap = MinimapRenderer.render(grid: OccupancyGrid(), cameraPosition: .zero, cameraHeading: 0, trajectory: [])
        XCTAssertNotNil(snap.image)
        XCTAssertEqual(snap.cropDimension, 1 + 2 * 10)   // 카메라 셀 1 + margin 10 × 2
        XCTAssertEqual(snap.image?.width, snap.cropDimension)
        XCTAssertEqual(snap.cropSideMeters, 21 * OccupancyGrid.cellSize)
        XCTAssertEqual(snap.totalPoints, 0)
    }

    func testWorldPointIsInverseOfNormalizedPoint() {
        let grid = OccupancyGrid()
        grid.accumulate(points: [ScanPoint(position: SIMD3(1, 0, -0.5))])
        let snap = MinimapRenderer.render(grid: grid, cameraPosition: .zero, cameraHeading: 0, trajectory: [])
        // 관측 면적 = 셀 수 × 셀 면적
        XCTAssertEqual(snap.observedAreaM2,
                       Float(snap.occupiedCellCount) * OccupancyGrid.cellSize * OccupancyGrid.cellSize,
                       accuracy: 1e-6)
        // 왕복: 월드 → 정규화 → 월드가 원래 점으로 돌아와야 거리 측정 탭 변환이 성립
        for world in [SIMD2<Float>(1, -0.5), SIMD2(0, 0), SIMD2(-0.3, 0.7)] {
            let back = snap.worldPoint(normalized: snap.normalizedPoint(world))
            XCTAssertEqual(back.x, world.x, accuracy: 0.001)
            XCTAssertEqual(back.y, world.y, accuracy: 0.001)
        }
    }

    func testUnchangedGridReusesImageAndChangeRerenders() {
        let grid = OccupancyGrid()
        grid.accumulate(points: [ScanPoint(position: .zero)])
        let first = MinimapRenderer.render(grid: grid, cameraPosition: .zero, cameraHeading: 0, trajectory: [])
        // 격자·crop 불변(제자리 회전, 일시정지) → 이미지 인스턴스 재사용
        let second = MinimapRenderer.render(grid: grid, cameraPosition: .zero, cameraHeading: 1,
                                            trajectory: [], previous: first)
        XCTAssertTrue(first.image === second.image)
        // 격자 변경 → 재렌더 (다른 인스턴스)
        grid.accumulate(points: [ScanPoint(position: SIMD3(0.2, 0, 0))])
        let third = MinimapRenderer.render(grid: grid, cameraPosition: .zero, cameraHeading: 0,
                                           trajectory: [], previous: second)
        XCTAssertFalse(second.image === third.image)
        // 격자 불변이라도 카메라가 crop 밖으로 나가면 crop이 바뀌므로 재렌더
        let moved = MinimapRenderer.render(grid: grid, cameraPosition: SIMD2(3, 0), cameraHeading: 0,
                                           trajectory: [], previous: third)
        XCTAssertFalse(third.image === moved.image)
    }

    func testCropCoversObservedCellsAndCamera() {
        let grid = OccupancyGrid()
        grid.accumulate(points: [ScanPoint(position: SIMD3(1, 0, 0))])   // 카메라(0,0)에서 x로 20셀
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
