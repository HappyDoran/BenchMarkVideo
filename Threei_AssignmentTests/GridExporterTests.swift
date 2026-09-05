import XCTest
import simd
@testable import Threei_Assignment

final class GridExporterTests: XCTestCase {

    func testPointCloudMatchesPlySource() {
        let grid = OccupancyGrid()
        let wall = ScanPoint(position: .zero, color: SIMD3(10, 20, 30))
        grid.accumulate(points: [wall, wall, wall])
        let cloud = GridExporter.pointCloud(grid: grid)
        XCTAssertEqual(cloud.positions.count, 1)
        XCTAssertEqual(cloud.positions[0], SIMD3(0, GridExporter.wallExportHeight, 0))
        XCTAssertEqual(cloud.colors[0], SIMD3(10, 20, 30))
        // .ply vertex 수 = 점군 수 (같은 소스에서 파생)
        XCTAssertTrue(GridExporter.ply(grid: grid).contains("element vertex \(cloud.positions.count)"))
    }

    func testEmptyGridExportsHeaderWithZeroVertices() {
        let text = GridExporter.ply(grid: OccupancyGrid())
        XCTAssertTrue(text.hasPrefix("ply\nformat ascii 1.0"))
        XCTAssertTrue(text.contains("element vertex 0"))
        XCTAssertTrue(text.contains("end_header"))
    }

    func testWallAndFloorCellsExportWithHeightAndColor() {
        let grid = OccupancyGrid()
        // 벽 임계값(3) 충족: 같은 셀에 벽 점 3회
        let wall = ScanPoint(position: SIMD3(0, 0, 0), color: SIMD3(200, 10, 20))
        grid.accumulate(points: [wall, wall, wall])
        // 바닥 임계값(2) 충족: 한 셀 옆(x + 1셀)에 바닥 점 2회
        let floor = ScanPoint(position: SIMD3(OccupancyGrid.cellSize, OccupancyGrid.floorBelow - 0.1, 0),
                              color: SIMD3(0, 0, 0))
        grid.accumulate(points: [floor, floor])

        let text = GridExporter.ply(grid: grid)
        XCTAssertTrue(text.contains("element vertex 2"))
        // 벽 셀: 원점 셀 중심 (0, wallExportHeight, 0) + EMA 전 첫 색 유지
        XCTAssertTrue(text.contains(String(format: "0.000 %.3f 0.000 200 10 20", GridExporter.wallExportHeight)))
        // 바닥 셀: x = cellSize, y = 0
        XCTAssertTrue(text.contains(String(format: "%.3f 0.000 0.000 0 0 0", OccupancyGrid.cellSize)))
    }
}
