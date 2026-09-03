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
            SIMD3(0, 0, 0),                              // wallBand 안 → 벽
            SIMD3(0, OccupancyGrid.floorBelow - 0.1, 0), // 그 아래 → 바닥
            SIMD3(0, OccupancyGrid.wallBand.upperBound + 0.5, 0), // 천장 → 버림
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
        grid.accumulate(points: [SIMD3(0, 0, 0), SIMD3(1, 0, -1)])
        XCTAssertEqual(grid.usedBounds?.maxCol, half + 20)
        XCTAssertEqual(grid.usedBounds?.minRow, half - 20)
        XCTAssertEqual(grid.occupiedCellCount, 2)
        grid.reset()
        XCTAssertNil(grid.usedBounds)
        XCTAssertEqual(grid.totalPoints, 0)
        XCTAssertEqual(grid.wallHits.reduce(0, +), 0)
    }
}
