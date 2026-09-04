import CoreGraphics
import CoreVideo
import XCTest
import simd
@testable import Threei_Assignment

/// 좌표 규약(TECH_RULES.md 2절)을 고정하는 테스트. 실기기 없이 시뮬레이터에서 실행.
final class DepthFrameProcessorTests: XCTestCase {

    /// intrinsics: fx=fy=100, cx=8, cy=6 — 16×12 이미지 기준. depthMap은 8×6 (스케일 0.5).
    private let intrinsics = simd_float3x3(columns: (SIMD3(100, 0, 0), SIMD3(0, 100, 0), SIMD3(8, 6, 1)))
    private let imageResolution = CGSize(width: 16, height: 12)

    private var params: DepthFrameProcessor.UnprojectionParams {
        .init(intrinsics: intrinsics, imageResolution: imageResolution, depthWidth: 8, depthHeight: 6)
    }

    func testIntrinsicsScaledToDepthResolution() {
        XCTAssertEqual(params.fx, 50); XCTAssertEqual(params.fy, 50)
        XCTAssertEqual(params.cx, 4);  XCTAssertEqual(params.cy, 3)
    }

    func testPrincipalPointUnprojectsToForwardMinusZ() {
        let p = DepthFrameProcessor.unproject(u: 4, v: 3, depth: 2, params: params, cameraTransform: matrix_identity_float4x4)
        XCTAssertEqual(p, SIMD3(0, 0, -2))
    }

    func testImageRightIsPlusXAndImageDownIsMinusY() {
        // u > cx → 카메라 +x. v > cy(이미지 아래) → flipYZ로 카메라 -y.
        let p = DepthFrameProcessor.unproject(u: 6, v: 4, depth: 1, params: params, cameraTransform: matrix_identity_float4x4)
        XCTAssertEqual(p.x, 2.0 / 50, accuracy: 1e-6)
        XCTAssertEqual(p.y, -1.0 / 50, accuracy: 1e-6)
        XCTAssertEqual(p.z, -1)
    }

    func testCameraTranslationAppliedColumnMajor() {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(1, 2, 3, 1)
        let p = DepthFrameProcessor.unproject(u: 4, v: 3, depth: 1, params: params, cameraTransform: t)
        XCTAssertEqual(p, SIMD3(1, 2, 2))
    }

    func testHeadingIdentityIsZeroAndLookingPlusXIsHalfPi() {
        XCTAssertEqual(DepthFrameProcessor.heading(of: matrix_identity_float4x4), 0, accuracy: 1e-6)
        // 시선 = -columns.2. +x를 보려면 columns.2 = -x. 오른손 좌표계: x = y × z = (0,0,1).
        let lookPlusX = simd_float4x4(columns: (SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 0, 0, 1)))
        XCTAssertEqual(DepthFrameProcessor.heading(of: lookPlusX), .pi / 2, accuracy: 1e-6)
    }

    // MARK: - worldPoints (CVPixelBuffer 경계)

    private func makeBuffer(width: Int, height: Int, format: OSType, fill: (UnsafeMutableRawPointer, Int) -> Void) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &buffer)
        let b = buffer!
        CVPixelBufferLockBaseAddress(b, [])
        fill(CVPixelBufferGetBaseAddress(b)!, CVPixelBufferGetBytesPerRow(b))
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    private func depthBuffer(_ depth: Float) -> CVPixelBuffer {
        makeBuffer(width: 8, height: 6, format: kCVPixelFormatType_DepthFloat32) { base, bpr in
            for v in 0..<6 {
                let row = base.advanced(by: v * bpr).assumingMemoryBound(to: Float32.self)
                for u in 0..<8 { row[u] = depth }
            }
        }
    }

    private func confidenceBuffer(_ level: UInt8) -> CVPixelBuffer {
        makeBuffer(width: 8, height: 6, format: kCVPixelFormatType_OneComponent8) { base, bpr in
            for v in 0..<6 { memset(base.advanced(by: v * bpr), Int32(level), 8) }
        }
    }

    func testWorldPointsSamplesByStrideAndUsesDepth() {
        let points = DepthFrameProcessor.worldPoints(depthMap: depthBuffer(2), confidenceMap: confidenceBuffer(2),
                                                     intrinsics: intrinsics, imageResolution: imageResolution,
                                                     cameraTransform: matrix_identity_float4x4)
        // stride 4: u ∈ {0,4}, v ∈ {0,4} → 4점. 전부 z = -2.
        XCTAssertEqual(points.count, 4)
        XCTAssertTrue(points.allSatisfy { $0.position.z == -2 })
        XCTAssertTrue(points.allSatisfy { $0.color == SIMD3(255, 255, 255) }, "capturedImage 없으면 흰색")
    }

    func testWorldPointsSamplesColorFromCapturedImage() {
        // 16×12 420f biplanar: Y=200, Cb=128, Cr=128 → 회색 (200,200,200). 색차 0이라 변환 계수와 무관.
        let image = makeBuffer(width: 16, height: 12, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { _, _ in }
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(image, 0), 200, CVPixelBufferGetBytesPerRowOfPlane(image, 0) * 12)
        memset(CVPixelBufferGetBaseAddressOfPlane(image, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * 6)
        CVPixelBufferUnlockBaseAddress(image, [])
        let points = DepthFrameProcessor.worldPoints(depthMap: depthBuffer(2), confidenceMap: nil, capturedImage: image,
                                                     intrinsics: intrinsics, imageResolution: imageResolution,
                                                     cameraTransform: matrix_identity_float4x4)
        XCTAssertEqual(points.count, 4)
        XCTAssertTrue(points.allSatisfy { $0.color == SIMD3(200, 200, 200) })
    }

    func testWorldPointsDropsLowConfidence() {
        let points = DepthFrameProcessor.worldPoints(depthMap: depthBuffer(2), confidenceMap: confidenceBuffer(0),
                                                     intrinsics: intrinsics, imageResolution: imageResolution,
                                                     cameraTransform: matrix_identity_float4x4)
        XCTAssertTrue(points.isEmpty)
    }

    func testWorldPointsDropsDepthOutOfRange() {
        for depth: Float in [0.1, 6.0] {
            let points = DepthFrameProcessor.worldPoints(depthMap: depthBuffer(depth), confidenceMap: nil,
                                                         intrinsics: intrinsics, imageResolution: imageResolution,
                                                         cameraTransform: matrix_identity_float4x4)
            XCTAssertTrue(points.isEmpty, "depth \(depth) should be filtered")
        }
    }
}
