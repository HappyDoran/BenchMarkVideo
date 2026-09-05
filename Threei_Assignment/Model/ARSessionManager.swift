import ARKit
import Foundation
import simd
#if DEBUG
import os
#endif

nonisolated enum ScanEvent: Sendable {
    case trackingChanged(message: String?)   // nil = 정상
    case sessionFailed(message: String, isPermissionDenied: Bool)
    case interruptionChanged(isInterrupted: Bool)
    /// 첫 mesh 앵커 생성됨 — 초기화 후 "주변 인식 중…" 배지 해제 신호.
    case meshReady
}

/// ARSession 소유·제어 + 깊이 파이프라인 구동.
///
/// 스레딩: delegate 콜백과 그리드 접근은 전부 `processingQueue`(직렬).
/// 제어 메서드(start/pause/reset/attach)는 **메인 스레드에서만** 호출한다 —
/// meshEnabled와 session.run이 메인 전용이라 큐 hop은 누적 상태(isAccumulating 등)에만 적용된다 (TECH_RULES §3).
/// @unchecked Sendable: 가변 상태는 processingQueue에서만 접근한다는 규약으로 보장.
nonisolated final class ARSessionManager: NSObject, ARSessionDelegate, @unchecked Sendable {

    /// 깊이 프레임 처리 최소 간격(s). 60fps 중 ~10fps만 그리드에 반영.
    private static let processInterval: TimeInterval = 0.1
    /// 궤적 기록 최소 이동 거리(m). 시작값 — 상한 도달 시 데시메이션과 함께 배가.
    private static let trajectoryStep: Float = 0.25
    /// 궤적 점 수 상한 — 격자처럼 메모리·스냅샷 복사 비용을 고정 (2048점 × 8B = 16KB).
    /// 도달하면 점을 절반 솎고 기록 간격을 배가 — 경로 형태는 유지, 해상도만 낮아진다.
    private static let trajectoryMaxPoints = 2048
    /// 재로컬라이즈 복귀 후 안정화 시간(s) — 정합 보정 시도 (드리프트 가산점).
    /// 복귀 직후 ARKit이 월드·앵커를 미세 조정하며 수렴하는 구간의 포즈로 찍은 점이
    /// 격자에 굳으면 기존 관측과 어긋난다(정합 오염). 실측(#21) 복귀 시퀀스 약 4초의
    /// 마지막 정렬 단계를 덮는 값. 궤적도 같은 이유로 보류.
    static let relocalizationSettleTime: TimeInterval = 1.0

    private let processingQueue = DispatchQueue(label: "scan.processing")
    private weak var session: ARSession?
    private let grid = OccupancyGrid()
    /// 3D 뷰어 정점 색용 월드 복셀 색 (processingQueue 전용).
    private let voxelColors = VoxelColorStore()

    // processingQueue에서만 접근
    private var isAccumulating = false
    /// 한 번이라도 스캔을 시작했는가 — 궤적 기록 조건. reset에서 해제.
    private var hasStarted = false
    /// 스캔 시작 시 카메라 월드 y — 높이 밴드 기준. 월드 원점은 앱 실행 시점에 고정되므로
    /// (책상에 둔 채 실행 후 들고 스캔 등) 실행 높이와 스캔 높이의 차를 여기로 보정한다.
    private var scanOriginY: Float?
    private var lastProcessedTime: TimeInterval = 0
    private var trajectory: [SIMD2<Float>] = []
    /// 현재 궤적 기록 간격(m) — 데시메이션마다 배가, reset에서 초기값 복원.
    private var trajectoryStride: Float = ARSessionManager.trajectoryStep
    /// 직전 스냅샷 — 격자 미변경 시 렌더러가 이미지를 재사용.
    private var lastSnapshot: MinimapSnapshot?
    /// 마지막 유효 yaw — 카메라가 수직(바닥/천장)을 볼 때 노이즈 회전 방지용.
    private var lastHeading: Float = 0
    /// mesh 예열 요청 여부 — 첫 프레임에 한 번만.
    private var didRequestMeshWarmUp = false
    /// meshReady 발행 여부 — 세션 시작·초기화마다 첫 앵커에 한 번만.
    private var didReportMeshReady = false
    /// 재로컬라이즈 → normal 전이 감지 플래그 (트래킹 콜백에서 set, 프레임에서 소비).
    private var pendingRelocalizationSettle = false
    /// 이 시각 전까지 누적·궤적 보류 (재로컬라이즈 안정화 구간).
    private var settleUntil: TimeInterval = 0

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
        processingQueue.async {
            self.didRequestMeshWarmUp = false  // retry로 ARView가 재생성될 때도 예열
            self.didReportMeshReady = false    // 새 세션 = 앵커 없음
        }
        runSession(reset: false, withMesh: false)
        #if DEBUG
        print("[scan] session attached & running. sceneDepth supported: \(Self.isDeviceSupported)")
        #endif
    }

    #if DEBUG
    private var debugFrameCount = 0
    /// 스로틀 통과 프레임 수 — perf 로그 주기용.
    private var debugProcessedCount = 0
    /// 처리 프레임별 콜백 소요(ms) — 3분에 약 1,800개, 주기 로그에서 백분위 계산.
    private var debugCallbackMs: [Double] = []
    /// DESIGN.md 10절: 콜백 처리 시간을 Instruments Points of Interest로 측정.
    private let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "io.tenkm.doran.lidarscan", category: .pointsOfInterest))
    /// perf 지표 — Logger라서 Xcode 미부착이어도 `log collect --device`로 사후 수집 가능.
    private let perfLog = Logger(subsystem: "io.tenkm.doran.lidarscan", category: "perf")

    /// 현재 프로세스 물리 메모리 사용량(MB). 실패 시 -1.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
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
        processingQueue.async { self.isAccumulating = true; self.hasStarted = true }
    }

    /// 메인 스레드에서만 호출 (meshEnabled 접근).
    private func enableMeshIfNeeded() {
        if !meshEnabled { runSession(reset: false, withMesh: true) }
    }

    func pauseAccumulating() {
        processingQueue.async { self.isAccumulating = false }
    }

    /// 현재 격자를 .ply 점군 텍스트로. grid는 큐 전용이라 큐에서 직렬화하고,
    /// 완성 문자열만 콜백으로 넘긴다 (받는 쪽에서 MainActor로 hop).
    func exportPly(_ completion: @escaping @Sendable (String) -> Void) {
        processingQueue.async { completion(GridExporter.ply(grid: self.grid)) }
    }

    /// 현재 격자를 점군 값으로 — 3D 뷰어용. 스레드 규약은 exportPly와 동일.
    func exportPointCloud(_ completion: @escaping @Sendable (GridPointCloud) -> Void) {
        processingQueue.async { completion(GridExporter.pointCloud(grid: self.grid)) }
    }

    /// 현재 ARKit mesh 앵커 + 복셀 색 → 정점 색 mesh (3D 뷰어). 앵커 스냅샷·색 조회 전부 큐에서.
    func exportColoredMesh(_ completion: @escaping @Sendable (ColoredMesh) -> Void) {
        processingQueue.async {
            let anchors = self.session?.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
            completion(MeshBuilder.coloredMesh(anchors: anchors, colors: self.voxelColors))
        }
    }

    /// 그리드·궤적·트래킹 전부 초기화.
    func reset() {
        processingQueue.async {
            self.isAccumulating = false
            self.hasStarted = false
            self.scanOriginY = nil
            self.grid.reset()
            self.voxelColors.reset()
            self.trajectory = []
            self.trajectoryStride = Self.trajectoryStep
            self.lastHeading = 0
            self.lastSnapshot = nil
            self.pendingRelocalizationSettle = false
            self.settleUntil = 0
            self.didReportMeshReady = false  // resetSceneReconstruction으로 앵커가 지워짐 — 재생성 감지 재무장
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
        #if DEBUG
        let signpostState = signposter.beginInterval("frameCallback")
        let callbackStart = CFAbsoluteTimeGetCurrent()
        defer {
            signposter.endInterval("frameCallback", signpostState)
            debugCallbackMs.append((CFAbsoluteTimeGetCurrent() - callbackStart) * 1000)
        }
        #endif

        let transform = frame.camera.transform
        let position = SIMD2(transform.columns.3.x, transform.columns.3.z)
        // 스캔 첫 프레임의 카메라 높이를 밴드 기준으로 고정 (reset에서 해제)
        if hasStarted, scanOriginY == nil { scanOriginY = transform.columns.3.y }
        // meshReady: 프레임 앵커 스냅샷의 없음→있음 전이로 감지. didAdd 콜백 대신 프레임 기준인 이유 —
        // 프레임은 세션 상태와 일관되고 이 큐(직렬)에서만 읽으므로, reset 직후 구 세션 앵커의
        // didAdd가 플래그 클리어 뒤에 끼어들어 가짜 이벤트를 쏘고 가드를 재무장하는 경합이 없다.
        if !didReportMeshReady, frame.anchors.contains(where: { $0 is ARMeshAnchor }) {
            didReportMeshReady = true
            onEvent?(.meshReady)
        }
        // 시선이 수직에 가까우면 yaw가 노이즈라 마지막 유효값 유지
        let look = -transform.columns.2
        if look.x * look.x + look.z * look.z > 0.01 {
            lastHeading = DepthFrameProcessor.heading(of: transform)
        }

        // 재로컬라이즈 복귀 첫 프레임: 안정화 창 시작 (정합 보정 시도 — 상수 주석 참고)
        if pendingRelocalizationSettle, case .normal = frame.camera.trackingState {
            pendingRelocalizationSettle = false
            settleUntil = frame.timestamp + Self.relocalizationSettleTime
        }
        let isSettling = frame.timestamp < settleUntil

        // 트래킹 normal일 때만 누적 — limited 상태의 포즈로 찍은 점은 유령 벽로 굳는다.
        // 재로컬라이즈 안정화 구간(isSettling)에도 보류 — 수렴 중 포즈가 정합을 오염시킨다.
        if isAccumulating, !isSettling, case .normal = frame.camera.trackingState {
            if let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
                let points = DepthFrameProcessor.worldPoints(
                    depthMap: depth.depthMap,
                    confidenceMap: depth.confidenceMap,
                    capturedImage: frame.capturedImage,
                    intrinsics: frame.camera.intrinsics,
                    imageResolution: frame.camera.imageResolution,
                    cameraTransform: transform)
                grid.accumulate(points: points, originY: scanOriginY ?? 0)
                voxelColors.accumulate(points: points)   // 3D 뷰어 정점 색
                #if DEBUG
                debugProcessedCount += 1
                if debugProcessedCount % 30 == 0, !debugCallbackMs.isEmpty {
                    // 약 3초 창 단위 백분위 — 누적하면 초반 샘플이 지배해 후반 저하를 가리고,
                    // 무제한 배열 재정렬이 측정 대상 자체를 느리게 한다. 로그 후 창을 비운다.
                    let sorted = debugCallbackMs.sorted()
                    let p50 = sorted[sorted.count / 2]
                    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                    let maxMs = sorted.last ?? 0
                    perfLog.info("""
                        n=\(self.debugProcessedCount) points/frame=\(points.count) \
                        cb(3s) p50=\(String(format: "%.2f", p50))ms \
                        p95=\(String(format: "%.2f", p95))ms \
                        max=\(String(format: "%.2f", maxMs))ms \
                        mem=\(String(format: "%.1f", Self.footprintMB()))MB
                        """)
                    debugCallbackMs.removeAll(keepingCapacity: true)
                }
                #endif
            }
        }
        // 궤적은 일시정지 중에도 기록 — 어디로 걸어갔는지는 누적 여부와 무관하게 보여야 한다.
        // 단 tracking normal일 때만 — limited 포즈는 튀어서 궤적에 스파이크가 남는다.
        // 스캔 시작 전(ready)에도 세션은 돌지만 hasStarted가 false라 시작 전 이동은 남지 않는다.
        if hasStarted, !isSettling, case .normal = frame.camera.trackingState,
           trajectory.last.map({ simd_distance($0, position) >= trajectoryStride }) ?? true {
            trajectory.append(position)
            // 상한 도달 시 절반 솎고 간격 배가 — 격자처럼 메모리·복사 비용을 고정
            if trajectory.count >= Self.trajectoryMaxPoints {
                trajectory = Swift.stride(from: 0, to: trajectory.count, by: 2).map { trajectory[$0] }
                trajectoryStride *= 2
            }
        }

        // 일시정지 중에도 위치 마커는 계속 갱신. 격자 미변경 시 이미지는 재사용(lastSnapshot).
        let snapshot = MinimapRenderer.render(grid: grid,
                                              cameraPosition: position,
                                              cameraHeading: lastHeading,
                                              trajectory: trajectory,
                                              previous: lastSnapshot)
        lastSnapshot = snapshot
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
            pendingRelocalizationSettle = true  // normal 복귀 후 첫 프레임에서 안정화 창 시작
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

    /// 중단(백그라운드 등) 후 기존 월드 원점으로 재로컬라이즈를 시도한다.
    /// false면 ARKit이 트래킹을 새로 시작해 원점이 바뀌고, 그때까지 쌓은 격자가 전부 어긋난다.
    /// 재로컬라이즈가 끝나지 않으면 "위치 재인식 중…" 배지가 유지되고 사용자는 초기화로 탈출한다.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func sessionInterruptionEnded(_ session: ARSession) {
        onEvent?(.interruptionChanged(isInterrupted: false))
    }
}
