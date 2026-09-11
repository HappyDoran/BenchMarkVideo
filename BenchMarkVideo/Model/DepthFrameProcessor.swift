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
    static let pixelStride = 4
    /// 유효 깊이 범위(m). 근접 노이즈와 원거리 저신뢰 값 제외.
    static let depthRange: ClosedRange<Float> = 0.25...5.0

    /// depthMap 해상도에 맞게 스케일된 intrinsics의 역투영 파라미터.
    struct UnprojectionParams {
        let fx, fy, cx, cy: Float

        init(intrinsics: simd_float3x3, imageResolution: CGSize, depthWidth: Int, depthHeight: Int) {
            // RGB 기준 intrinsics를 더 작은 depthMap 좌표계로 옮길 축별 비율을 구한다.
            let sx = Float(depthWidth) / Float(imageResolution.width)
            let sy = Float(depthHeight) / Float(imageResolution.height)
            // 초점거리와 주점을 같은 비율로 줄여 깊이 픽셀 (u, v)에 직접 적용한다.
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
        // 주점으로부터의 픽셀 오프셋을 초점거리와 깊이로 스케일해 카메라 평면 위치를 구한다.
        let localX = (Float(u) - params.cx) / params.fx * depth
        let localY = (Float(v) - params.cy) / params.fy * depth
        // flipYZ 적용: 이미지 y-down → 카메라 y-up, 전방 = -z
        let cameraPoint = SIMD4<Float>(localX, -localY, -depth, 1)
        // 카메라 자세를 적용해 매 프레임 공통인 ARKit 월드 좌표로 옮긴다.
        let world = cameraTransform * cameraPoint
        return SIMD3(world.x, world.y, world.z)
    }

    /// 카메라 시선의 수평 방위각. 0 = 월드 -z 방향, 시계방향 양수 (미니맵 north-up 기준).
    static func heading(of transform: simd_float4x4) -> Float {
        // 변환 행렬의 -z축을 xz 평면에 투영해 north-up 기준 yaw를 계산한다.
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
        // CPU가 읽는 동안 depth와 RGB 버퍼의 메모리 주소가 바뀌지 않도록 잠근다.
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let capturedImage { CVPixelBufferLockBaseAddress(capturedImage, .readOnly) }
        defer { if let capturedImage { CVPixelBufferUnlockBaseAddress(capturedImage, .readOnly) } }

        // 깊이 버퍼의 크기와 행 stride를 읽어 padding을 포함한 실제 메모리 인덱스를 만든다.
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)

        var confPtr: UnsafeMutablePointer<UInt8>?
        var confStride = 0
        // confidenceMap이 있으면 depthMap과 같은 픽셀 좌표에서 신뢰도 값을 읽을 준비를 한다.
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confPtr = CVPixelBufferGetBaseAddress(confidenceMap)?
                .assumingMemoryBound(to: UInt8.self)
            confStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        // 한 프레임에서 공통인 해상도 보정 intrinsics는 픽셀 루프 밖에서 한 번만 계산한다.
        let params = UnprojectionParams(intrinsics: intrinsics,
                                        imageResolution: imageResolution,
                                        depthWidth: width, depthHeight: height)

        // stride로 예상되는 최대 점 수를 미리 확보해 반복적인 배열 재할당을 피한다.
        var points: [ScanPoint] = []
        points.reserveCapacity((width / pixelStride) * (height / pixelStride))

        for v in Swift.stride(from: 0, to: height, by: pixelStride) {
            for u in Swift.stride(from: 0, to: width, by: pixelStride) {
                // medium 미만 신뢰도와 유효 거리 밖 픽셀은 월드 점으로 만들지 않는다.
                if let confPtr, confPtr[v * confStride + u] < minConfidence { continue }
                let depth = depthPtr[v * depthStride + u]
                guard depthRange.contains(depth) else { continue }
                // 필터를 통과한 깊이 픽셀을 월드 위치와 기본 흰색을 가진 점으로 만든다.
                var point = ScanPoint(position: unproject(u: u, v: v, depth: depth,
                                                          params: params, cameraTransform: cameraTransform))
                // 카메라 영상이 있으면 같은 시선의 YCbCr 색으로 기본색을 교체한다.
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
        // 기대한 Y 평면과 CbCr 평면이 아니면 안전한 기본 흰색으로 되돌린다.
        guard CVPixelBufferGetPlaneCount(image) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return SIMD3(255, 255, 255) }
        // depthMap 픽셀 좌표를 capturedImage의 luma 해상도로 비례 변환한다.
        let iw = CVPixelBufferGetWidthOfPlane(image, 0), ih = CVPixelBufferGetHeightOfPlane(image, 0)
        let iu = min(u * iw / depthWidth, iw - 1), iv = min(v * ih / depthHeight, ih - 1)
        let y = Float(yBase.assumingMemoryBound(to: UInt8.self)[iv * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + iu])
        // 4:2:0 포맷의 CbCr는 가로·세로 두 픽셀당 한 쌍이므로 좌표를 절반으로 줄인다.
        let c = cBase.assumingMemoryBound(to: UInt8.self)
            .advanced(by: (iv / 2) * CVPixelBufferGetBytesPerRowOfPlane(image, 1) + (iu / 2) * 2)
        let cb = Float(c[0]) - 128, cr = Float(c[1]) - 128
        // BT.601 full range
        // BT.601 full-range 식으로 RGB를 만든 뒤 UInt8 범위로 잘라 overflow를 막는다.
        let rgb = SIMD3(y + 1.402 * cr, y - 0.344 * cb - 0.714 * cr, y + 1.772 * cb)
        return SIMD3<UInt8>(clamping: SIMD3<Int32>(simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 255))))
    }
}
