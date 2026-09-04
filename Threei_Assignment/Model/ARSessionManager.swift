import ARKit
import Foundation
import simd

nonisolated enum ScanEvent: Sendable {
    case trackingChanged(message: String?)   // nil = 정상
    case sessionFailed(message: String, isPermissionDenied: Bool)
    case interruptionChanged(isInterrupted: Bool)
}

/// ARSession 소유·제어 + 깊이 파이프라인 구동.
///
/// 스레딩: delegate 콜백과 그리드 접근은 전부 `processingQueue`(직렬).
/// 제어 메서드(start/pause/...)는 아무 스레드에서나 호출 가능 — 내부에서 큐로 hop.
/// @unchecked Sendable: 가변 상태는 processingQueue에서만 접근한다는 규약으로 보장.
nonisolated final class ARSessionManager: NSObject, ARSessionDelegate, @unchecked Sendable {

    /// 깊이 프레임 처리 최소 간격(s). 60fps 중 ~10fps만 그리드에 반영.
    private static let processInterval: TimeInterval = 0.1
    /// 궤적 기록 최소 이동 거리(m).
    private static let trajectoryStep: Float = 0.25

    private let processingQueue = DispatchQueue(label: "scan.processing")
    private weak var session: ARSession?
    private let grid = OccupancyGrid()

    // processingQueue에서만 접근
    private var isAccumulating = false
    private var lastProcessedTime: TimeInterval = 0
    private var trajectory: [SIMD2<Float>] = []
    /// 마지막 유효 yaw — 카메라가 수직(바닥/천장)을 볼 때 노이즈 회전 방지용.
    private var lastHeading: Float = 0
    /// mesh 예열 요청 여부 — 첫 프레임에 한 번만.
    private var didRequestMeshWarmUp = false

    /// processingQueue에서 호출됨 — 받는 쪽에서 MainActor로 hop할 것.
    var onSnapshot: (@Sendable (MinimapSnapshot) -> Void)?
    var onEvent: (@Sendable (ScanEvent) -> Void)?

    static var isDeviceSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    /// 메시 재구성 활성 여부 — 제어 메서드(메인 스레드)에서만 접근.
    private var meshEnabled = false

    /// ARView 생성 시 호출 — ARView 소유 세션에 연결하고 실행.
    /// 첫 구성은 mesh 없이 시작 — RealityKit 셰이더 컴파일을 줄여 카메라 표시를 앞당긴다.
    /// mesh는 첫 프레임 도착 직후(카메라 패스스루가 이미 시작된 시점) 켠다 —
    /// 스캔 시작 직후 "카메라 위에 아무 변화 없는 2초"를 없애기 위한 예열 (구성 교체는 트래킹을 유지).
    func attach(to session: ARSession) {
        self.session = session
        session.delegate = self
        session.delegateQueue = processingQueue
        runSession(reset: false, withMesh: false)
        #if DEBUG
        print("[scan] session attached & running. sceneDepth supported: \(Self.isDeviceSupported)")
        #endif
    }

    #if DEBUG
    private var debugFrameCount = 0
    #endif

    private func runSession(reset: Bool, withMesh: Bool) {
        guard let session else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .smoothedSceneDepth
        if withMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh  // 카메라 프리뷰 위 스캔 시각화용
        }
        meshEnabled = withMesh
        let options: ARSession.RunOptions = reset
            ? [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction] : []
        session.run(config, options: options)
    }

    // MARK: - 스캔 제어 (스캔 상태만 제어 — 세션은 계속 돌려 트래킹 유지)

    func startAccumulating() {
        enableMeshIfNeeded()
        processingQueue.async { self.isAccumulating = true }
    }

    /// 메인 스레드에서만 호출 (meshEnabled 접근).
    private func enableMeshIfNeeded() {
        if !meshEnabled { runSession(reset: false, withMesh: true) }
    }

    func pauseAccumulating() {
        processingQueue.async { self.isAccumulating = false }
    }

    /// 그리드·궤적·트래킹 전부 초기화.
    func reset() {
        processingQueue.async {
            self.isAccumulating = false
            self.grid.reset()
            self.trajectory = []
            self.lastHeading = 0
            // 초기화 직후 빈 스냅샷 발행 — 큐에 남아 있던 프레임의 옛 그리드 잔상을 즉시 덮음
            self.onSnapshot?(MinimapRenderer.render(grid: self.grid, cameraPosition: .zero,
                                                    cameraHeading: 0, trajectory: []))
        }
        // 카메라는 이미 떠 있으므로 mesh를 바로 켠 채 재시작 — 구성 교체 한 번을 아낀다.
        // 남는 지연은 resetSceneReconstruction 후 ARKit이 첫 mesh 앵커를 만드는 시간(약 1초).
        runSession(reset: true, withMesh: true)
    }

    // MARK: - ARSessionDelegate (processingQueue에서 호출됨)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        #if DEBUG
        debugFrameCount += 1
        if debugFrameCount == 1 || debugFrameCount % 300 == 0 {
            print("[scan] frame #\(debugFrameCount), depth: \(frame.smoothedSceneDepth != nil), tracking: \(frame.camera.trackingState)")
        }
        #endif
        // 예열: 첫 프레임 = 카메라 패스스루 시작 시점. 여기서 mesh를 켜야
        // 사용자가 "스캔 시작"을 누를 때 이미 앵커·셰이더가 준비돼 있다.
        if !didRequestMeshWarmUp {
            didRequestMeshWarmUp = true
            DispatchQueue.main.async { self.enableMeshIfNeeded() }
        }
        // 스로틀: 처리 주기 미달이면 즉시 반환 (ARFrame 잡지 않음)
        guard frame.timestamp - lastProcessedTime >= Self.processInterval else { return }
        lastProcessedTime = frame.timestamp

        let transform = frame.camera.transform
        let position = SIMD2(transform.columns.3.x, transform.columns.3.z)
        // 시선이 수직에 가까우면 yaw가 노이즈라 마지막 유효값 유지
        let look = -transform.columns.2
        if look.x * look.x + look.z * look.z > 0.01 {
            lastHeading = DepthFrameProcessor.heading(of: transform)
        }

        // 트래킹 normal일 때만 누적 — limited 상태의 포즈로 찍은 점은 유령 벽로 굳는다
        if isAccumulating, case .normal = frame.camera.trackingState {
            if let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
                let points = DepthFrameProcessor.worldPoints(
                    depthMap: depth.depthMap,
                    confidenceMap: depth.confidenceMap,
                    capturedImage: frame.capturedImage,
                    intrinsics: frame.camera.intrinsics,
                    imageResolution: frame.camera.imageResolution,
                    cameraTransform: transform)
                grid.accumulate(points: points)
            }
            if trajectory.last.map({ simd_distance($0, position) >= Self.trajectoryStep }) ?? true {
                trajectory.append(position)
            }
        }

        // 일시정지 중에도 위치 마커는 계속 갱신
        let snapshot = MinimapRenderer.render(grid: grid,
                                              cameraPosition: position,
                                              cameraHeading: lastHeading,
                                              trajectory: trajectory)
        onSnapshot?(snapshot)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let message: String?
        switch camera.trackingState {
        case .normal:
            message = nil
        case .notAvailable:
            message = "트래킹을 사용할 수 없습니다"
        case .limited(.excessiveMotion):
            message = "기기를 천천히 움직여 주세요"
        case .limited(.insufficientFeatures):
            message = "주변이 어둡거나 특징이 부족합니다"
        case .limited(.initializing):
            message = "트래킹 초기화 중…"
        case .limited(.relocalizing):
            message = "위치 재인식 중…"
        case .limited:
            message = "트래킹이 불안정합니다"
        }
        onEvent?(.trackingChanged(message: message))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        #if DEBUG
        print("[scan] session failed: \(error)")
        #endif
        let isPermission = (error as? ARError)?.code == .cameraUnauthorized
        let message = isPermission
            ? "카메라 권한이 없습니다. 설정에서 허용해 주세요."
            : "AR 세션 오류: \(error.localizedDescription)"
        onEvent?(.sessionFailed(message: message, isPermissionDenied: isPermission))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onEvent?(.interruptionChanged(isInterrupted: true))
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        onEvent?(.interruptionChanged(isInterrupted: false))
    }
}
