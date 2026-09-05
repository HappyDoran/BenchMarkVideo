import ARKit
import simd

/// 깊이 프레임 → 월드 좌표 3D 점 변환. 순수 함수 모음 — 단위 테스트 대상.
///
/// 좌표계 규약 (CLAUDE.md):
/// - intrinsics는 capturedImage(landscape) 해상도 기준 → depthMap 해상도로 스케일해서 사용.
/// - 이미지 좌표(y-down, z-forward) → ARKit 카메라 좌표(y-up, -z-forward)는 flipYZ로 변환.
/// - depthMap 픽셀을 버퍼 좌표 그대로 순회하므로 화면 회전은 이 경로에 영향 없음.
/// 월드 좌표 점 + 그 픽셀의 카메라 색 (capturedImage 없으면 흰색).
nonisolated struct ScanPoint: Equatable {
    var position: SIMD3<Float>
    var color: SIMD3<UInt8> = SIMD3(255, 255, 255)
}

nonisolated enum DepthFrameProcessor {

    /// 프레임당 샘플링 간격(픽셀). 256×192 기준 stride 4 → 최대 3,072점.
    static let pixelStride = 1  // perf-baseline: 전수 샘플링
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
    /// capturedImage(420 YpCbCr biplanar)가 있으면 같은 시선의 픽셀 색을 함께 담는다 — depthMap과 정렬돼 있어 해상도 비율로 좌표만 스케일.
    static func worldPoints(depthMap: CVPixelBuffer,
                            confidenceMap: CVPixelBuffer?,
                            capturedImage: CVPixelBuffer? = nil,
                            intrinsics: simd_float3x3,
                            imageResolution: CGSize,
                            cameraTransform: simd_float4x4,
                            minConfidence: UInt8 = UInt8(ARConfidenceLevel.medium.rawValue)) -> [ScanPoint] {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let capturedImage { CVPixelBufferLockBaseAddress(capturedImage, .readOnly) }
        defer { if let capturedImage { CVPixelBufferUnlockBaseAddress(capturedImage, .readOnly) } }

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

        var points: [ScanPoint] = []
        points.reserveCapacity((width / pixelStride) * (height / pixelStride))

        for v in Swift.stride(from: 0, to: height, by: pixelStride) {
            for u in Swift.stride(from: 0, to: width, by: pixelStride) {
                if let confPtr, confPtr[v * confStride + u] < minConfidence { continue }
                let depth = depthPtr[v * depthStride + u]
                guard depthRange.contains(depth) else { continue }
                var point = ScanPoint(position: unproject(u: u, v: v, depth: depth,
                                                          params: params, cameraTransform: cameraTransform))
                if let capturedImage {
                    point.color = sampleColor(capturedImage, u: u, v: v, depthWidth: width, depthHeight: height)
                }
                points.append(point)
            }
        }
        return points
    }

    /// depthMap 픽셀 (u, v)에 대응하는 capturedImage 색. 420 YpCbCr8 biplanar(full range) → RGB.
    /// 잠금은 호출자가 한다.
    static func sampleColor(_ image: CVPixelBuffer, u: Int, v: Int, depthWidth: Int, depthHeight: Int) -> SIMD3<UInt8> {
        guard CVPixelBufferGetPlaneCount(image) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return SIMD3(255, 255, 255) }
        let iw = CVPixelBufferGetWidthOfPlane(image, 0), ih = CVPixelBufferGetHeightOfPlane(image, 0)
        let iu = min(u * iw / depthWidth, iw - 1), iv = min(v * ih / depthHeight, ih - 1)
        let y = Float(yBase.assumingMemoryBound(to: UInt8.self)[iv * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + iu])
        let c = cBase.assumingMemoryBound(to: UInt8.self)
            .advanced(by: (iv / 2) * CVPixelBufferGetBytesPerRowOfPlane(image, 1) + (iu / 2) * 2)
        let cb = Float(c[0]) - 128, cr = Float(c[1]) - 128
        // BT.601 full range
        let rgb = SIMD3(y + 1.402 * cr, y - 0.344 * cb - 0.714 * cr, y + 1.772 * cb)
        return SIMD3<UInt8>(clamping: SIMD3<Int32>(simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 255))))
    }
}
