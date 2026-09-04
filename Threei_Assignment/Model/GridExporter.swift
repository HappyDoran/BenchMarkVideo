import Foundation
import simd

/// OccupancyGrid → ASCII .ply 점군 텍스트. 순수 함수 — 단위 테스트 대상.
/// 호출 스레드 규약: grid 가변 상태를 읽으므로 scan.processing 큐에서 호출한다 (ARSessionManager.exportPly).
nonisolated enum GridExporter {

    /// 벽 셀 대표 높이(m). top-down 격자라 셀에 높이 정보가 없어 시각화용 고정값 — 바닥(0)과 구분만 되면 된다.
    static let wallExportHeight: Float = 0.5

    /// 관측 셀(임계값 이상)을 셀 중심 좌표의 색 점으로 내보낸다. 뷰어에서 벽은 y=0.5, 바닥은 y=0.
    static func ply(grid: OccupancyGrid) -> String {
        var vertices: [String] = []
        if let b = grid.usedBounds {
            for row in b.minRow...b.maxRow {
                for col in b.minCol...b.maxCol {
                    let idx = row * OccupancyGrid.dimension + col
                    let isWall = grid.wallHits[idx] >= OccupancyGrid.wallHitThreshold
                    let isFloor = grid.floorHits[idx] >= OccupancyGrid.floorHitThreshold
                    guard isWall || isFloor else { continue }
                    let w = OccupancyGrid.worldXZ(continuousCell: SIMD2(Float(col), Float(row)))
                    let y: Float = isWall ? wallExportHeight : 0
                    let c = grid.colors[idx]
                    vertices.append(String(format: "%.3f %.3f %.3f %d %d %d",
                                           w.x, y, w.y, c.x, c.y, c.z))
                }
            }
        }
        return """
        ply
        format ascii 1.0
        comment Threei_Assignment occupancy grid export (cell \(OccupancyGrid.cellSize)m, y: wall=\(wallExportHeight) floor=0)
        element vertex \(vertices.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header
        \(vertices.joined(separator: "\n"))
        """ + "\n"
    }
}
