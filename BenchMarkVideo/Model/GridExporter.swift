import Foundation
import simd

/// 관측 셀 점군 — 3D 뷰어와 .ply 직렬화가 공유하는 데이터 (단일 소스).
nonisolated struct GridPointCloud: Sendable {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD3<UInt8>] = []

    /// 측정 평면용 바닥 높이 (밀도 기반 — MeshBuilder.estimatedFloorY).
    var estimatedFloorY: Float { MeshBuilder.estimatedFloorY(of: positions) }
}

/// OccupancyGrid → 점군 / ASCII .ply 텍스트. 순수 함수 — 단위 테스트 대상.
/// 호출 스레드 규약: grid 가변 상태를 읽으므로 scan.processing 큐에서 호출한다 (ARSessionManager 경유).
nonisolated enum GridExporter {

    /// 벽 셀 대표 높이(m). top-down 격자라 셀에 높이 정보가 없어 시각화용 고정값 — 바닥(0)과 구분만 되면 된다.
    static let wallExportHeight: Float = 0.5

    /// 관측 셀(임계값 이상)을 셀 중심 좌표의 색 점으로. 벽은 y=0.5, 바닥은 y=0.
    static func pointCloud(grid: OccupancyGrid) -> GridPointCloud {
        var cloud = GridPointCloud()
        guard let b = grid.usedBounds else { return cloud }
        for row in b.minRow...b.maxRow {
            for col in b.minCol...b.maxCol {
                let idx = row * OccupancyGrid.dimension + col
                let isWall = grid.wallHits[idx] >= OccupancyGrid.wallHitThreshold
                let isFloor = grid.floorHits[idx] >= OccupancyGrid.floorHitThreshold
                guard isWall || isFloor else { continue }
                let w = OccupancyGrid.worldXZ(continuousCell: SIMD2(Float(col), Float(row)))
                cloud.positions.append(SIMD3(w.x, isWall ? wallExportHeight : 0, w.y))
                cloud.colors.append(grid.colors[idx])
            }
        }
        return cloud
    }

    /// 점군을 ASCII .ply로 직렬화 (내보내기 공유용).
    static func ply(grid: OccupancyGrid) -> String {
        let cloud = pointCloud(grid: grid)
        let vertices = zip(cloud.positions, cloud.colors).map { p, c in
            String(format: "%.3f %.3f %.3f %d %d %d", p.x, p.y, p.z, c.x, c.y, c.z)
        }
        return """
        ply
        format ascii 1.0
        comment BenchMarkVideo occupancy grid export (cell \(OccupancyGrid.cellSize)m, y: wall=\(wallExportHeight) floor=0)
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
