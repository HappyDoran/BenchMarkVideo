import XCTest
import simd
@testable import Threei_Assignment

final class OccupancyGridTests: XCTestCase {

    private let half = OccupancyGrid.dimension / 2

    func testCellIndexOriginIsCenterAndRoundsToNearestCell() {
        XCTAssertEqual(OccupancyGrid.cellIndex(x: 0, z: 0)?.col, half)
        XCTAssertEqual(OccupancyGrid.cellIndex(x: 0, z: 0)?.row, half)
        XCTAssertEqual(OccupancyGrid.cellIndex(x: OccupancyGrid.cellSize, z: 0)?.col, half + 1)
        XCTAssertEqual(OccupancyGrid.cellIndex(x: 0, z: -OccupancyGrid.cellSize)?.row, half - 1)
    }

    func testCellIndexOutsideGridIsNil() {
        let edge = Float(half) * OccupancyGrid.cellSize
        XCTAssertNil(OccupancyGrid.cellIndex(x: edge, z: 0))
        XCTAssertNil(OccupancyGrid.cellIndex(x: -edge - OccupancyGrid.cellSize, z: 0))
    }

    func testAccumulateSeparatesWallFloorAndDropsCeiling() {
        let grid = OccupancyGrid()
        let idx = half * OccupancyGrid.dimension + half
        grid.accumulate(points: [
            ScanPoint(position: SIMD3(0, 0, 0)),                              // wallBand 안 → 벽
            ScanPoint(position: SIMD3(0, OccupancyGrid.floorBelow - 0.1, 0)), // 그 아래 → 바닥
            ScanPoint(position: SIMD3(0, OccupancyGrid.wallBand.upperBound + 0.5, 0)), // 천장 → 버림
        ])
        XCTAssertEqual(grid.wallHits[idx], 1)
        XCTAssertEqual(grid.floorHits[idx], 1)
        XCTAssertEqual(grid.totalPoints, 2)
        XCTAssertEqual(grid.occupiedCellCount, 1)
        XCTAssertEqual(grid.usedBounds?.minCol, half)
        XCTAssertEqual(grid.usedBounds?.maxRow, half)
    }

    func testUsedBoundsGrowAndResetClears() {
        let grid = OccupancyGrid()
        grid.accumulate(points: [ScanPoint(position: SIMD3(0, 0, 0)), ScanPoint(position: SIMD3(1, 0, -1))])
        XCTAssertEqual(grid.usedBounds?.maxCol, half + 20)
        XCTAssertEqual(grid.usedBounds?.minRow, half - 20)
        XCTAssertEqual(grid.occupiedCellCount, 2)
        grid.reset()
        XCTAssertNil(grid.usedBounds)
        XCTAssertEqual(grid.totalPoints, 0)
        XCTAssertEqual(grid.wallHits.reduce(0, +), 0)
    }

    func testAccumulateOriginYRebasesHeightBands() {
        let grid = OccupancyGrid()
        let idx = half * OccupancyGrid.dimension + half
        // 책상(0.7m)에서 실행 후 1.5m로 들고 스캔 시작: originY = +0.8.
        // 바닥 점(월드 y = -0.7)은 상대 -1.5 → 벽이 아니라 바닥으로 분류돼야 한다.
        grid.accumulate(points: [ScanPoint(position: SIMD3(0, -0.7, 0))], originY: 0.8)
        XCTAssertEqual(grid.wallHits[idx], 0)
        XCTAssertEqual(grid.floorHits[idx], 1)
        // originY 없이는 같은 점이 벽 밴드에 들어간다 (기존 버그 재현 고정)
        let unrebased = OccupancyGrid()
        unrebased.accumulate(points: [ScanPoint(position: SIMD3(0, -0.7, 0))])
        XCTAssertEqual(unrebased.wallHits[idx], 1)
    }

    func testColorFirstHitSetsThenEMA() {
        let grid = OccupancyGrid()
        let idx = half * OccupancyGrid.dimension + half
        grid.accumulate(points: [ScanPoint(position: .zero, color: SIMD3(255, 0, 100))])
        XCTAssertEqual(grid.colors[idx], SIMD3(255, 0, 100))
        grid.accumulate(points: [ScanPoint(position: .zero, color: SIMD3(0, 0, 0))])
        XCTAssertEqual(grid.colors[idx], SIMD3(191, 0, 75))   // (old×3 + new) / 4
    }
}
