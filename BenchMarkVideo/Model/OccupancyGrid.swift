import simd

/// 고정 크기 occupancy grid. 점을 무한 누적하는 대신 셀 단위 hit count로 접어
/// 메모리 상한을 고정한다 (hit 400×400×2×2byte ≈ 640KB +
/// 색 SIMD3<UInt8> stride 4byte × 400×400 ≈ 640KB, 원시 배열 합계 약 1.28MB).
///
/// 스레딩: scan.processing 직렬 큐에서만 접근 (CLAUDE.md 동시성 규약).
nonisolated final class OccupancyGrid {

    /// 셀 한 변(m). 5cm — 벽 윤곽 구분에 충분하고 400셀로 20m 커버.
    static let cellSize: Float = 0.05
    /// 한 변 셀 수. ARKit 월드 x=0, z=0이 중앙 — start()는 x/z를 재중심하지 않는다.
    static let dimension = 400
    // ponytail: 월드 원점 중심 각 축 약 ±10m 밖은 버림. 대공간 필요해지면 원점 재중심 or chunk 확장.

    /// 높이 밴드 (스캔 시작 시 기기 높이 기준 상대 y ≈ 바닥 위 1.2~1.5m 가정).
    /// wallBand: 바닥 위 약 0.3~2.2m 구간 → 벽·가구. 그 아래 = 바닥, 위 = 천장(버림).
    /// 월드 y 원점은 앱 실행 시점이라 스캔 시작 높이와 다를 수 있음 — accumulate의 originY로 재기준.
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
    /// 관측된 셀 수 — 커버리지 피드백용. 렌더 임계값(wall 3/floor 2)을 넘은 셀만 집계.
    private(set) var occupiedCellCount = 0

    /// 월드 (x, z) → 연속 셀 좌표 (반올림·경계 처리 전).
    /// 월드→격자 매핑의 단일 정의 — cellIndex와 MinimapSnapshot.normalizedPoint가 여기서 파생된다.
    static func continuousCell(x: Float, z: Float) -> SIMD2<Float> {
        // 미터를 셀 단위로 바꾸고 월드 원점이 격자 중앙에 오도록 절반 크기를 더한다.
        SIMD2(x / cellSize + Float(dimension / 2), z / cellSize + Float(dimension / 2))
    }

    /// 연속 셀 좌표 → 월드 (x, z). continuousCell의 역변환 — 미니맵 탭 위치를 월드로 되돌릴 때 사용.
    static func worldXZ(continuousCell c: SIMD2<Float>) -> SIMD2<Float> {
        // 중앙 오프셋을 제거한 뒤 셀 크기를 곱해 다시 미터 단위로 돌린다.
        (c - Float(dimension / 2)) * cellSize
    }

    /// 월드 (x, z) → 셀 (col, row). row는 +z 방향으로 증가 (이미지 아래 방향 = north-up).
    static func cellIndex(x: Float, z: Float) -> (col: Int, row: Int)? {
        // 최근접 셀 중심으로 반올림해 정수 col·row를 만든다.
        let c = continuousCell(x: x, z: z)
        let col = Int(c.x.rounded()), row = Int(c.y.rounded())
        // 고정 20m 격자 밖 점은 배열에 접근하지 않고 버린다.
        guard col >= 0, col < dimension, row >= 0, row < dimension else { return nil }
        return (col, row)
    }

    /// originY: 스캔 시작 시 카메라 월드 y — 높이 밴드를 실행 시점이 아닌 스캔 시작 높이 기준으로 만든다.
    func accumulate(points: [ScanPoint], originY: Float = 0) {
        // 각 월드 점을 하나의 xz 셀과 상대 높이 분류로 접어 고정 크기 배열에 누적한다.
        for sp in points {
            let p = sp.position
            guard let (col, row) = Self.cellIndex(x: p.x, z: p.z) else { continue }
            let idx = row * Self.dimension + col

            // 스캔 시작 카메라 높이를 빼 벽·바닥 밴드가 실행 자세에 종속되지 않게 한다.
            let relY = p.y - originY
            let isWall = Self.wallBand.contains(relY)
            guard isWall || relY < Self.floorBelow else { continue }  // 천장
            // 첫 관측 여부는 색 EMA를 적용할지 원색을 저장할지 결정한다.
            let isNewCell = wallHits[idx] == 0 && floorHits[idx] == 0
            // 관측 면적은 렌더 임계값과 같은 기준으로 집계 — 1회 히트 노이즈 셀이 라벨을 부풀리지 않게
            let wasVisible = wallHits[idx] >= Self.wallHitThreshold || floorHits[idx] >= Self.floorHitThreshold
            if isWall {
                // UInt16 최대값에서 포화시켜 장시간 스캔의 overflow를 막는다.
                if wallHits[idx] < .max { wallHits[idx] += 1 }
            } else {
                if floorHits[idx] < .max { floorHits[idx] += 1 }
            }
            // 이번 hit로 처음 표시 임계값을 넘은 셀만 관측 셀 수에 한 번 더한다.
            let nowVisible = wallHits[idx] >= Self.wallHitThreshold || floorHits[idx] >= Self.floorHitThreshold
            if !wasVisible && nowVisible { occupiedCellCount += 1 }
            // 반복 관측 색은 이전 75%, 새 색 25%로 섞어 깜빡임과 센서 노이즈를 줄인다.
            colors[idx] = isNewCell ? sp.color
                : SIMD3<UInt8>(truncatingIfNeeded: (SIMD3<UInt16>(truncatingIfNeeded: colors[idx]) &* 3 &+ SIMD3<UInt16>(truncatingIfNeeded: sp.color)) / 4)
            totalPoints += 1

            // 실제 데이터가 존재하는 최소 사각형을 넓혀 렌더러가 작은 crop만 순회하게 한다.
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
        // 이전 공간의 hit·색·통계를 모두 초기값으로 되돌린다.
        wallHits = [UInt16](repeating: 0, count: Self.dimension * Self.dimension)
        floorHits = [UInt16](repeating: 0, count: Self.dimension * Self.dimension)
        colors = [SIMD3<UInt8>](repeating: .zero, count: Self.dimension * Self.dimension)
        usedBounds = nil
        totalPoints = 0
        occupiedCellCount = 0
    }
}
