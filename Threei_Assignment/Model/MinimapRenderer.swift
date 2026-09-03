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

    /// 월드 (x, z) → 이미지 정규화 좌표 (0...1). 이미지 밖이면 범위를 벗어난 값 반환.
    /// +0.5: cellIndex는 최근접 반올림이라 셀 중심이 픽셀 중심 — 픽셀 좌상단이 아닌 중심에 맞춘다.
    func normalizedPoint(_ world: SIMD2<Float>) -> CGPoint {
        let col = world.x / OccupancyGrid.cellSize + Float(OccupancyGrid.dimension / 2)
        let row = world.y / OccupancyGrid.cellSize + Float(OccupancyGrid.dimension / 2)
        return CGPoint(x: CGFloat((col - Float(cropOriginCol) + 0.5) / Float(cropDimension)),
                       y: CGFloat((row - Float(cropOriginRow) + 0.5) / Float(cropDimension)))
    }
}

/// OccupancyGrid → CGImage. 데이터가 있는 영역만 정사각형으로 crop (auto-fit).
/// scan.processing 큐에서 호출.
nonisolated enum MinimapRenderer {

    /// crop 여백(셀). 맵 가장자리가 화면에 붙지 않게.
    private static let margin = 10

    static func render(grid: OccupancyGrid,
                       cameraPosition: SIMD2<Float>,
                       cameraHeading: Float,
                       trajectory: [SIMD2<Float>]) -> MinimapSnapshot {
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
                                   totalPoints: 0, occupiedCellCount: 0)
        }

        // 정사각형화 + 여백, 그리드 경계로 클램프
        let side = max(maxC - minC, maxR - minR) + 1 + margin * 2
        let dim = min(side, OccupancyGrid.dimension)
        var originC = (minC + maxC) / 2 - dim / 2
        var originR = (minR + maxR) / 2 - dim / 2
        originC = max(0, min(originC, OccupancyGrid.dimension - dim))
        originR = max(0, min(originR, OccupancyGrid.dimension - dim))

        // RGBA 비트맵: 벽 = 밝은 흰색, 관측된 바닥 = 어두운 회색, 미관측 = 반투명 검정
        var pixels = [UInt8](repeating: 0, count: dim * dim * 4)
        grid.wallHits.withUnsafeBufferPointer { walls in
            grid.floorHits.withUnsafeBufferPointer { floors in
                for r in 0..<dim {
                    let gridRowBase = (originR + r) * OccupancyGrid.dimension + originC
                    let pixRowBase = r * dim * 4
                    for c in 0..<dim {
                        let w = walls[gridRowBase + c]
                        let f = floors[gridRowBase + c]
                        let o = pixRowBase + c * 4
                        if w >= OccupancyGrid.wallHitThreshold {
                            pixels[o] = 235; pixels[o+1] = 235; pixels[o+2] = 240; pixels[o+3] = 255
                        } else if f >= OccupancyGrid.floorHitThreshold {
                            pixels[o] = 70; pixels[o+1] = 75; pixels[o+2] = 85; pixels[o+3] = 210
                        } else {
                            pixels[o+3] = 150  // 미관측: 반투명 검정
                        }
                    }
                }
            }
        }

        let image = pixels.withUnsafeBytes { buf -> CGImage? in
            guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
            return CGImage(width: dim, height: dim,
                           bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: dim * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),  // straight alpha — 픽셀값이 비승산
                           provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)
        }

        return MinimapSnapshot(image: image,
                               cropOriginCol: originC, cropOriginRow: originR, cropDimension: dim,
                               cameraPosition: cameraPosition, cameraHeading: cameraHeading,
                               trajectory: trajectory,
                               totalPoints: grid.totalPoints,
                               occupiedCellCount: grid.occupiedCellCount)
    }
}
