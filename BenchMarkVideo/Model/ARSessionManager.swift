@preconcurrency import ARKit
import Foundation
import simd

nonisolated enum ScanEvent: Sendable {
    case trackingChanged(message: String?)   // nil = 정상
    case sessionFailed(message: String, isPermissionDenied: Bool)
    case interruptionChanged(isInterrupted: Bool)
    /// 첫 mesh 앵커 생성됨 — 초기화 후 "주변 인식 중…" 배지 해제 신호.
    case meshReady
}

/// 프레임 게이트 판정 결과 — 진단 패널 표시용 이름.
nonisolated enum GateReason: String {
    case beforeStart = "시작 전"
    case paused = "일시정지"
    case trackingHold = "트래킹 보류"
    case settling = "재인식 안정화"
    case noDepth = "깊이 없음"
    case allowed = "누적 허용"
}

/// ARSession 소유·제어 + 프레임 게이트. 누적·출력은 `ScanPipeline`.
///
/// 스레딩: delegate 콜백과 게이트 상태는 전부 `processingQueue`(직렬).
/// 제어 메서드(start/pause/reset/attach)는 **메인 스레드에서만** 호출한다 —
/// meshEnabled와 session.run이 메인 전용이라 큐 hop은 누적 상태(isAccumulating 등)에만 적용된다 (TECH_RULES §3).
/// 출력은 `outputs` 스트림 하나 — 스냅샷·이벤트·mesh가 한 줄로 흘러 순서가 보존된다.
/// @unchecked Sendable: 가변 상태는 processingQueue에서만 접근한다는 규약으로 보장.
nonisolated final class ARSessionManager: NSObject, ARSessionDelegate, @unchecked Sendable {

    /// 깊이 프레임 처리 최소 간격(s). 60fps 중 ~10fps만 그리드에 반영.
    private static let processInterval: TimeInterval = 0.1
    /// 재로컬라이즈 복귀 후 안정화 시간(s) — 정합 보정 시도 (선택 요구사항: 드리프트 보정).
    /// 복귀 직후 ARKit이 월드·앵커를 미세 조정하며 수렴하는 구간의 포즈로 찍은 점이
    /// 격자에 굳으면 기존 관측과 어긋난다(정합 오염). 실측(#21) 복귀 시퀀스 약 4초의
    /// 마지막 정렬 단계를 덮는 값. 궤적도 같은 이유로 보류.
    static let relocalizationSettleTime: TimeInterval = 1.0

    /// Model → ViewModel 단일 출력. 받는 쪽은 MainActor Task에서 `for await`.
    let outputs: AsyncStream<ScanOutput>
    private let continuation: AsyncStream<ScanOutput>.Continuation
    private let processingQueue = DispatchQueue(label: "scan.processing")
    private let pipeline: ScanPipeline
    private weak var session: ARSession?

    // processingQueue에서만 접근
    private var isAccumulating = false
    /// 한 번이라도 스캔을 시작했는가 — 궤적 기록 조건. reset에서 해제.
    private var hasStarted = false
    private var lastProcessedTime: TimeInterval = 0
    /// mesh 예열 요청 여부 — 첫 프레임에 한 번만.
    private var didRequestMeshWarmUp = false
    /// meshReady 발행 여부 — 세션 시작·초기화마다 첫 앵커에 한 번만.
    private var didReportMeshReady = false
    /// 재로컬라이즈 → normal 전이 감지 플래그 (트래킹 콜백에서 set, 프레임에서 소비).
    private var pendingRelocalizationSettle = false
    /// reset 직후 구 세션 프레임(옛 mesh 앵커 보유)이 meshReady를 오발하지 않게 —
    /// mesh 앵커가 0인 프레임(= 교체 완료)을 한 번 본 뒤에만 감지를 재무장한다.
    private var awaitingMeshClear = false
    /// 이 시각 전까지 누적·궤적 보류 (재로컬라이즈 안정화 구간).
    private var settleUntil: TimeInterval = 0
    #if SCAN_DIAGNOSTICS
    private let diagnostics = ScanDiagnosticsCollector()
    #endif

    static var isDeviceSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    /// 메시 재구성 활성 여부 — 제어 메서드(메인 스레드)에서만 접근.
    private var meshEnabled = false
    /// attach 후 첫 스캔 시작인가 — 예열이 쌓아 둔 스캔 전 mesh를 리셋할 시점 판정 (메인 전용).
    private var isFirstStartSinceAttach = true

    override init() {
        // 무제한 버퍼 — 이벤트 하나라도 버리면 배지 상태가 어긋난다. 생산은 10Hz 스냅샷 + 드문 이벤트라 적체 없음.
        let (stream, continuation) = AsyncStream.makeStream(of: ScanOutput.self, bufferingPolicy: .unbounded)
        outputs = stream
        self.continuation = continuation
        pipeline = ScanPipeline(queue: processingQueue) { continuation.yield($0) }
        super.init()
    }

    private func emit(_ output: ScanOutput) { continuation.yield(output) }

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
            self.awaitingMeshClear = false
        }
        isFirstStartSinceAttach = true
        runSession(reset: false, withMesh: false)
    }

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
        // 첫 시작: 예열이 스캔 전에 쌓아 둔 mesh를 비우고 재구성을 새로 시작 —
        // "체크무늬 = 이번 스캔에서 훑은 곳"으로 사용자 멘탈 모델과 정렬 (초기화 후 시작과 같은 UX,
        // 재생성 ~1초 공백은 '주변 인식 중…' 배지가 커버). 셰이더 예열 효과는 유지된다.
        if isFirstStartSinceAttach {
            isFirstStartSinceAttach = false
            processingQueue.async { self.awaitingMeshClear = true; self.didReportMeshReady = false }
            if let session {
                let config = ARWorldTrackingConfiguration()
                config.frameSemantics = .smoothedSceneDepth
                if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                    config.sceneReconstruction = .mesh
                }
                meshEnabled = true
                session.run(config, options: [.resetSceneReconstruction])  // 트래킹·앵커는 유지, mesh만 리셋
            }
        } else {
            enableMeshIfNeeded()
        }
        processingQueue.async {
            self.isAccumulating = true
            self.hasStarted = true
            self.pipeline.markStarted()
        }
    }

    /// 메인 스레드에서만 호출 (meshEnabled 접근).
    private func enableMeshIfNeeded() {
        if !meshEnabled { runSession(reset: false, withMesh: true) }
    }

    func pauseAccumulating() {
        processingQueue.async { self.isAccumulating = false }
    }

    /// 현재 격자를 .ply 파일로 — 결과는 `outputs`의 `.plyFile`.
    func exportPly() {
        processingQueue.async { self.pipeline.exportPly() }
    }

    /// 현재 격자를 점군 값으로 — 결과는 `outputs`의 `.pointCloud`.
    func exportPointCloud() {
        processingQueue.async { self.pipeline.exportPointCloud() }
    }

    /// 그리드·궤적·트래킹 전부 초기화.
    func reset() {
        processingQueue.async {
            self.isAccumulating = false
            self.hasStarted = false
            self.pendingRelocalizationSettle = false
            self.settleUntil = 0
            self.didReportMeshReady = false  // resetSceneReconstruction으로 앵커가 지워짐 — 재생성 감지 재무장
            self.awaitingMeshClear = true    // 구 세션 프레임의 옛 앵커로 오발하지 않게 — 앵커 0 프레임 후 재무장
            #if SCAN_DIAGNOSTICS
            self.diagnostics.reset()
            #endif
            self.pipeline.reset()            // 빈 스냅샷 발행 포함
        }
        // 카메라는 이미 떠 있으므로 mesh를 바로 켠 채 재시작 — 구성 교체 한 번을 아낀다.
        // 남는 지연은 resetSceneReconstruction 후 ARKit이 첫 mesh 앵커를 만드는 시간(약 1초).
        isFirstStartSinceAttach = false   // 여기서 이미 mesh를 리셋 — 다음 시작에서 중복 리셋 방지
        runSession(reset: true, withMesh: true)
    }

    // MARK: - ARSessionDelegate (processingQueue에서 호출됨)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        #if SCAN_DIAGNOSTICS
        diagnostics.frameReceived()
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
        #if SCAN_DIAGNOSTICS
        let probe = diagnostics.begin()
        #endif

        // meshReady: 프레임 앵커 스냅샷의 없음→있음 전이로 감지. didAdd 콜백 대신 프레임 기준인 이유 —
        // 프레임은 세션 상태와 일관되고 이 큐(직렬)에서만 읽으므로, reset 직후 구 세션 앵커의
        // didAdd가 플래그 클리어 뒤에 끼어들어 가짜 이벤트를 쏘고 가드를 재무장하는 경합이 없다.
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if awaitingMeshClear {
            // reset 직후: 옛 앵커를 아직 든 구 프레임은 무시, 앵커가 지워진 프레임을 보고서야 재무장
            if meshAnchors.isEmpty { awaitingMeshClear = false }
        } else if !didReportMeshReady, !meshAnchors.isEmpty {
            didReportMeshReady = true
            emit(.event(.meshReady))
        }

        // 재로컬라이즈 복귀 첫 프레임: 안정화 창 시작 (정합 보정 시도 — 상수 주석 참고)
        let isNormal: Bool
        if case .normal = frame.camera.trackingState { isNormal = true } else { isNormal = false }
        if pendingRelocalizationSettle, isNormal {
            pendingRelocalizationSettle = false
            settleUntil = frame.timestamp + Self.relocalizationSettleTime
        }
        let isSettling = frame.timestamp < settleUntil

        // 트래킹 normal일 때만 누적 — limited 상태의 포즈로 찍은 점은 유령 벽로 굳는다.
        // 재로컬라이즈 안정화 구간(isSettling)에도 보류 — 수렴 중 포즈가 정합을 오염시킨다.
        // 궤적은 일시정지 중에도, 단 normal일 때만 — limited 포즈는 튀어서 스파이크가 남는다.
        let gate = FrameGate(started: hasStarted,
                             accumulate: isAccumulating && !isSettling && isNormal,
                             track: hasStarted && !isSettling && isNormal)
        let depth = gate.accumulate ? (frame.smoothedSceneDepth ?? frame.sceneDepth) : nil
        var input = FrameInput(timestamp: frame.timestamp, cameraTransform: frame.camera.transform,
                               intrinsics: frame.camera.intrinsics,
                               imageResolution: frame.camera.imageResolution,
                               meshAnchors: meshAnchors)
        if let depth {
            input.depthMap = depth.depthMap
            input.confidenceMap = depth.confidenceMap
            input.capturedImage = frame.capturedImage
            input.depthSource = frame.smoothedSceneDepth != nil ? "smoothed" : "raw"
        }
        let result = pipeline.process(input, gate: gate)

        #if SCAN_DIAGNOSTICS
        let reason: GateReason = !hasStarted ? .beforeStart
            : !isAccumulating ? .paused
            : isSettling ? .settling
            : !isNormal ? .trackingHold
            : result.missingDepth ? .noDepth : .allowed
        let t = frame.camera.transform.columns.3
        let context = ScanDiagnosticsCollector.FrameContext(
            timestamp: frame.timestamp, position: SIMD3(t.x, t.y, t.z), anchorCount: meshAnchors.count,
            gate: reason.rawValue, allowed: reason == .allowed,
            depthSource: depth == nil ? "없음" : input.depthSource, result: result,
            totalPoints: pipeline.totalPoints, originY: pipeline.scanOriginY,
            voxelEntries: pipeline.voxelEntryCount, generation: pipeline.generation)
        if let value = diagnostics.end(probe, context: context) { emit(.diagnostics(value)) }
        #endif
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
        emit(.event(.trackingChanged(message: message)))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let isPermission = (error as? ARError)?.code == .cameraUnauthorized
        let message = isPermission
            ? "카메라 권한이 없습니다. 설정에서 허용해 주세요."
            : "AR 세션 오류: \(error.localizedDescription)"
        emit(.event(.sessionFailed(message: message, isPermissionDenied: isPermission)))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        emit(.event(.interruptionChanged(isInterrupted: true)))
    }

    /// 중단(백그라운드 등) 후 기존 월드 원점으로 재로컬라이즈를 시도한다.
    /// false면 ARKit이 트래킹을 새로 시작해 원점이 바뀌고, 그때까지 쌓은 격자가 전부 어긋난다.
    /// 재로컬라이즈가 끝나지 않으면 "위치 재인식 중…" 배지가 유지되고 사용자는 초기화로 탈출한다.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func sessionInterruptionEnded(_ session: ARSession) {
        emit(.event(.interruptionChanged(isInterrupted: false)))
    }
}
