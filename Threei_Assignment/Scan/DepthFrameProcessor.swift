import ARKit
import simd

/// 깊이 프레임 → 월드 좌표 3D 점 변환. 순수 함수 모음 — 단위 테스트 대상.
///
/// 좌표계 규약 (CLAUDE.md):
/// - intrinsics는 capturedImage(landscape) 해상도 기준 → depthMap 해상도로 스케일해서 사용.
/// - 이미지 좌표(y-down, z-forward) → ARKit 카메라 좌표(y-up, -z-forward)는 flipYZ로 변환.
/// - depthMap 픽셀을 버퍼 좌표 그대로 순회하므로 화면 회전은 이 경로에 영향 없음.
nonisolated enum DepthFrameProcessor {

    /// 프레임당 샘플링 간격(픽셀). 256×192 기준 stride 4 → 최대 3,072점.
    static let pixelStride = 4
    /// 유효 깊이 범위(m). 근접 노이즈와 원거리 저신뢰 값 제외.
    static let depthRange: ClosedRange<Float> = 0.25...5.0

    /// depthMap 해상도에 맞게 스케일된 intrinsics의 역투영 파라미터.
    struct UnprojectionParams {
        let fx, fy, cx, cy: Float

        init(intrinsics: simd_float3x3, imageResolution: CGSize, depthWidth: Int, depthHeight: Int) {
            let sx = Float(depthWidth) / Float(imageResolution.width)
            let sy = Float(depthHeight) / Float(imageResolution.height)
            fx = intrinsics[0][0] * sx
            fy = intrinsics[1][1] * sy
            cx = intrinsics[2][0] * sx
            cy = intrinsics[2][1] * sy
        }
    }

    /// 깊이 픽셀 (u, v, depth) → 월드 좌표.
    /// world = cameraTransform × flipYZ × (K⁻¹·(u,v,1)·d)
    static func unproject(u: Int, v: Int, depth: Float,
                          params: UnprojectionParams,
                          cameraTransform: simd_float4x4) -> SIMD3<Float> {
        let localX = (Float(u) - params.cx) / params.fx * depth
        let localY = (Float(v) - params.cy) / params.fy * depth
        // flipYZ 적용: 이미지 y-down → 카메라 y-up, 전방 = -z
        let cameraPoint = SIMD4<Float>(localX, -localY, -depth, 1)
        let world = cameraTransform * cameraPoint
        return SIMD3(world.x, world.y, world.z)
    }

    /// 카메라 시선의 수평 방위각. 0 = 월드 -z 방향, 시계방향 양수 (미니맵 north-up 기준).
    static func heading(of transform: simd_float4x4) -> Float {
        let look = -transform.columns.2  // 카메라 -z축 = 시선
        return atan2(look.x, -look.z)
    }

    /// 깊이/신뢰도 버퍼를 샘플링해 월드 점 배열 생성.
    /// confidence < minConfidence 픽셀은 버림 (기본: medium 이상).
    static func worldPoints(depthMap: CVPixelBuffer,
                            confidenceMap: CVPixelBuffer?,
                            intrinsics: simd_float3x3,
                            imageResolution: CGSize,
                            cameraTransform: simd_float4x4,
                            minConfidence: UInt8 = UInt8(ARConfidenceLevel.medium.rawValue)) -> [SIMD3<Float>] {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)

        var confPtr: UnsafeMutablePointer<UInt8>?
        var confStride = 0
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confPtr = CVPixelBufferGetBaseAddress(confidenceMap)?
                .assumingMemoryBound(to: UInt8.self)
            confStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        let params = UnprojectionParams(intrinsics: intrinsics,
                                        imageResolution: imageResolution,
                                        depthWidth: width, depthHeight: height)

        var points: [SIMD3<Float>] = []
        points.reserveCapacity((width / pixelStride) * (height / pixelStride))

        for v in Swift.stride(from: 0, to: height, by: pixelStride) {
            for u in Swift.stride(from: 0, to: width, by: pixelStride) {
                if let confPtr, confPtr[v * confStride + u] < minConfidence { continue }
                let depth = depthPtr[v * depthStride + u]
                guard depthRange.contains(depth) else { continue }
                points.append(unproject(u: u, v: v, depth: depth,
                                        params: params, cameraTransform: cameraTransform))
            }
        }
        return points
    }
}
