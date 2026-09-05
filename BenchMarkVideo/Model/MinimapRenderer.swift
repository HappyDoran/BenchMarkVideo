import CoreGraphics
import Foundation
import simd

/// 미니맵 한 프레임의 불변 스냅샷. 처리 큐에서 생성해 MainActor로 전달.
/// CGImage는 불변이므로 안전 — @unchecked는 CGImage가 Sendable 미표기라서.
nonisolated struct MinimapSnapshot: @unchecked Sendable {
    let image: CGImage?
    /// crop 영역의 시작 셀 (월드→이미지 좌표 매핑용).
    let cropOriginCol: Int
    let cropOriginRow: Int
    /// crop 한 변의 셀 수 (정사각형).
    let cropDimension: Int

    let cameraPosition: SIMD2<Float>   // 월드 (x, z)
    let cameraHeading: Float           // 0 = -z(north-up 기준 위), 시계방향
    let trajectory: [SIMD2<Float>]     // 월드 (x, z) 궤적
    let totalPoints: Int
    let occupiedCellCount: Int
    /// 이미지를 만든 시점의 격자 버전(totalPoints) — 격자 미변경 시 이미지 재사용 판정용.
    let gridVersion: Int

    /// crop 한 변의 실제 길이(m). View가 "카메라 중심 반경 r" 창을 만들 때 스케일 계산용.
    var cropSideMeters: Float { Float(cropDimension) * OccupancyGrid.cellSize }

    /// 관측 면적(m²) = 관측 셀 수 × 셀 면적. 커버리지 피드백·면적 측정 표시용.
    var observedAreaM2: Float {
        Float(occupiedCellCount) * OccupancyGrid.cellSize * OccupancyGrid.cellSize
    }

    /// 정규화 좌표(0...1, 전체화면 항등 변환 기준) → 월드 (x, z). normalizedPoint의 역변환 — 거리 측정 탭 입력용.
    func worldPoint(normalized p: CGPoint) -> SIMD2<Float> {
        let c = SIMD2(Float(p.x) * Float(cropDimension) - 0.5 + Float(cropOriginCol),
                      Float(p.y) * Float(cropDimension) - 0.5 + Float(cropOriginRow))
        return OccupancyGrid.worldXZ(continuousCell: c)
    }

    /// 월드 (x, z) → 이미지 정규화 좌표 (0...1). 이미지 밖이면 범위를 벗어난 값 반환.
    /// +0.5: cellIndex는 최근접 반올림이라 셀 중심이 픽셀 중심 — 픽셀 좌상단이 아닌 중심에 맞춘다.
    func normalizedPoint(_ world: SIMD2<Float>) -> CGPoint {
        let c = OccupancyGrid.continuousCell(x: world.x, z: world.y)
        return CGPoint(x: CGFloat((c.x - Float(cropOriginCol) + 0.5) / Float(cropDimension)),
                       y: CGFloat((c.y - Float(cropOriginRow) + 0.5) / Float(cropDimension)))
    }
}

/// OccupancyGrid → CGImage. 데이터가 있는 영역만 정사각형으로 crop (auto-fit).
/// scan.processing 큐에서 호출.
nonisolated enum MinimapRenderer {

    /// crop 여백(셀). 맵 가장자리가 화면에 붙지 않게.
    private static let margin = 10
    /// 매 호출 생성 비용 제거 — 불변 객체.
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// previous: 직전 스냅샷 — 격자(totalPoints)와 crop이 그대로면 픽셀 재생성·CGImage 생성을 건너뛰고
    /// 이미지를 재사용한다 (일시정지·정지 상태에서 10Hz 전량 재렌더 방지, SwiftUI 텍스처 재업로드 방지).
    static func render(grid: OccupancyGrid,
                       cameraPosition: SIMD2<Float>,
                       cameraHeading: Float,
                       trajectory: [SIMD2<Float>],
                       previous: MinimapSnapshot? = nil) -> MinimapSnapshot {
        // crop 영역: 관측 셀 + 현재 카메라 위치를 포함하는 정사각형
        var minC = OccupancyGrid.dimension, maxC = 0, minR = OccupancyGrid.dimension, maxR = 0
        if let b = grid.usedBounds {
            (minC, maxC, minR, maxR) = b
        }
        if let cam = OccupancyGrid.cellIndex(x: cameraPosition.x, z: cameraPosition.y) {
            minC = min(minC, cam.col); maxC = max(maxC, cam.col)
            minR = min(minR, cam.row); maxR = max(maxR, cam.row)
        }
        guard minC <= maxC else {
            return MinimapSnapshot(image: nil, cropOriginCol: 0, cropOriginRow: 0,
                                   cropDimension: OccupancyGrid.dimension,
                                   cameraPosition: cameraPosition, cameraHeading: cameraHeading,
                                   trajectory: trajectory,
                                   totalPoints: 0, occupiedCellCount: 0, gridVersion: 0)
        }

        // 정사각형화 + 여백, 그리드 경계로 클램프
        let side = max(maxC - minC, maxR - minR) + 1 + margin * 2
        let dim = min(side, OccupancyGrid.dimension)
        var originC = (minC + maxC) / 2 - dim / 2
        var originR = (minR + maxR) / 2 - dim / 2
        originC = max(0, min(originC, OccupancyGrid.dimension - dim))
        originR = max(0, min(originR, OccupancyGrid.dimension - dim))

        // 격자·crop이 직전과 같으면 이미지 재사용 — 픽셀값이 (hits, colors, crop)의 순수 함수라 동일 보장.
        if let previous, previous.gridVersion == grid.totalPoints,
           previous.cropOriginCol == originC, previous.cropOriginRow == originR,
           previous.cropDimension == dim {
            return MinimapSnapshot(image: previous.image,
                                   cropOriginCol: originC, cropOriginRow: originR, cropDimension: dim,
                                   cameraPosition: cameraPosition, cameraHeading: cameraHeading,
                                   trajectory: trajectory,
                                   totalPoints: grid.totalPoints,
                                   occupiedCellCount: grid.occupiedCellCount,
                                   gridVersion: grid.totalPoints)
        }

        // RGBA 비트맵: 벽 = 카메라 색 그대로, 관측된 바닥 = 카메라 색을 절반 어둡게, 미관측 = 투명
        // ponytail: 벽/바닥 구분을 밝기 차로만 둠. 실기기에서 벽 라인이 안 읽히면 벽 테두리(이웃 셀 검사) 추가.
        var pixels = [UInt8](repeating: 0, count: dim * dim * 4)
        grid.wallHits.withUnsafeBufferPointer { walls in
            grid.floorHits.withUnsafeBufferPointer { floors in
                grid.colors.withUnsafeBufferPointer { colors in
                    for r in 0..<dim {
                        let gridRowBase = (originR + r) * OccupancyGrid.dimension + originC
                        let pixRowBase = r * dim * 4
                        for c in 0..<dim {
                            let w = walls[gridRowBase + c]
                            let f = floors[gridRowBase + c]
                            let rgb = colors[gridRowBase + c]
                            let o = pixRowBase + c * 4
                            if w >= OccupancyGrid.wallHitThreshold {
                                pixels[o] = rgb.x; pixels[o+1] = rgb.y; pixels[o+2] = rgb.z; pixels[o+3] = 255
                            } else if f >= OccupancyGrid.floorHitThreshold {
                                pixels[o] = rgb.x / 2; pixels[o+1] = rgb.y / 2; pixels[o+2] = rgb.z / 2; pixels[o+3] = 230
                            }
                            // 미관측 셀은 alpha 0 그대로 — View 배경이 그대로 비쳐
                            // 이미지 영역과 그 바깥이 같은 색으로 보인다 (오버레이 창 균일).
                        }
                    }
                }
            }
        }

        let image = pixels.withUnsafeBytes { buf -> CGImage? in
            guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
            return CGImage(width: dim, height: dim,
                           bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: dim * 4,
                           space: colorSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),  // straight alpha — 픽셀값이 비승산
                           provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)
        }

        return MinimapSnapshot(image: image,
                               cropOriginCol: originC, cropOriginRow: originR, cropDimension: dim,
                               cameraPosition: cameraPosition, cameraHeading: cameraHeading,
                               trajectory: trajectory,
                               totalPoints: grid.totalPoints,
                               occupiedCellCount: grid.occupiedCellCount,
                               gridVersion: grid.totalPoints)
    }
}
