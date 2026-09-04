import simd

/// 고정 크기 occupancy grid. 점을 무한 누적하는 대신 셀 단위 hit count로 접어
/// 메모리 상한을 고정한다 (hit 400×400×2×2byte ≈ 640KB + 색 400×400×3byte ≈ 480KB).
///
/// 스레딩: scan.processing 직렬 큐에서만 접근 (CLAUDE.md 동시성 규약).
nonisolated final class OccupancyGrid {

    /// 셀 한 변(m). 5cm — 벽 윤곽 구분에 충분하고 400셀로 20m 커버.
    static let cellSize: Float = 0.05
    /// 한 변 셀 수. 원점(스캔 시작 위치)이 중앙.
    static let dimension = 400
    // ponytail: 20m 초과 영역은 버림. 대공간 필요해지면 원점 재중심 or chunk 확장.

    /// 높이 밴드 (월드 y, 원점 = 스캔 시작 시 기기 높이 ≈ 바닥 위 1.2~1.5m).
    /// wallBand: 바닥 위 약 0.3~2.2m 구간 → 벽·가구. 그 아래 = 바닥, 위 = 천장(버림).
    // ponytail: 시작 높이 가정에 의존. 드리프트/정확도 문제 보이면 ARPlaneAnchor 바닥 추정으로 교체.
    static let wallBand: ClosedRange<Float> = -0.9...0.7
    static let floorBelow: Float = -0.9

    /// 벽으로 표시할 최소 hit 수 (노이즈 컷).
    static let wallHitThreshold: UInt16 = 3
    static let floorHitThreshold: UInt16 = 2

    private(set) var wallHits = [UInt16](repeating: 0, count: dimension * dimension)
    private(set) var floorHits = [UInt16](repeating: 0, count: dimension * dimension)
    /// 셀의 카메라 색. 첫 hit는 그대로, 이후는 EMA(3:1)로 섞어 노이즈를 누른다.
    private(set) var colors = [SIMD3<UInt8>](repeating: .zero, count: dimension * dimension)

    /// 데이터가 존재하는 셀 범위 (렌더링 crop용). nil = 아직 비어 있음.
    private(set) var usedBounds: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int)?
    private(set) var totalPoints = 0
    /// 관측된 셀 수 — 커버리지 피드백용.
    private(set) var occupiedCellCount = 0

    /// 월드 (x, z) → 셀 (col, row). row는 +z 방향으로 증가 (이미지 아래 방향 = north-up).
    static func cellIndex(x: Float, z: Float) -> (col: Int, row: Int)? {
        let col = Int((x / cellSize).rounded()) + dimension / 2
        let row = Int((z / cellSize).rounded()) + dimension / 2
        guard col >= 0, col < dimension, row >= 0, row < dimension else { return nil }
        return (col, row)
    }

    func accumulate(points: [ScanPoint]) {
        for sp in points {
            let p = sp.position
            guard let (col, row) = Self.cellIndex(x: p.x, z: p.z) else { continue }
            let idx = row * Self.dimension + col

            let isWall = Self.wallBand.contains(p.y)
            guard isWall || p.y < Self.floorBelow else { continue }  // 천장
            let isNewCell = wallHits[idx] == 0 && floorHits[idx] == 0
            if isNewCell { occupiedCellCount += 1 }
            if isWall {
                if wallHits[idx] < .max { wallHits[idx] += 1 }
            } else {
                if floorHits[idx] < .max { floorHits[idx] += 1 }
            }
            colors[idx] = isNewCell ? sp.color
                : SIMD3<UInt8>(truncatingIfNeeded: (SIMD3<UInt16>(truncatingIfNeeded: colors[idx]) &* 3 &+ SIMD3<UInt16>(truncatingIfNeeded: sp.color)) / 4)
            totalPoints += 1

            if var b = usedBounds {
                b.minCol = min(b.minCol, col); b.maxCol = max(b.maxCol, col)
                b.minRow = min(b.minRow, row); b.maxRow = max(b.maxRow, row)
                usedBounds = b
            } else {
                usedBounds = (col, col, row, row)
            }
        }
    }

    func reset() {
        wallHits = [UInt16](repeating: 0, count: Self.dimension * Self.dimension)
        floorHits = [UInt16](repeating: 0, count: Self.dimension * Self.dimension)
        colors = [SIMD3<UInt8>](repeating: .zero, count: Self.dimension * Self.dimension)
        usedBounds = nil
        totalPoints = 0
        occupiedCellCount = 0
    }
}
