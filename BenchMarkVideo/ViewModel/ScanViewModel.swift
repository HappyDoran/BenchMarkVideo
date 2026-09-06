import ARKit
import Foundation
import Observation
import simd

enum ScanState {
    case ready      // 세션은 돌지만 누적 전
    case scanning
    case paused
}

/// 전체화면 뷰어 모드 — 2D 미니맵 / 3D 점군. 측정 상태(measurePoints)는 두 모드가 공유.
enum MapViewMode: String, CaseIterable {
    case map2D = "2D"
    case cloud3D = "3D"
}

/// UI 상태 허브 (MainActor). Model의 단일 출력 스트림(`ScanOutput`)을 받아 상태로 바꾸고,
/// View의 의도(시작·일시정지·전체화면·측정)를 Model 명령으로 내린다. View는 여기만 읽는다.
@Observable
final class ScanViewModel {

    private(set) var state: ScanState = .ready
    private(set) var snapshot: MinimapSnapshot?
    /// 트래킹 불안정 안내 (nil = 정상).
    private(set) var trackingMessage: String?
    private(set) var isInterrupted = false
    /// 첫 mesh 앵커 도착 여부 — false인 채 스캔 중이면 "주변 인식 중…" 배지.
    private(set) var isMeshReady = false
    /// 내보내기용 .ply 임시 파일 — 전체화면 진입 시 생성, ShareLink가 소비.
    private(set) var exportURL: URL?
    /// 3D 뷰어용 점군 — 뷰어 열 때 생성. mesh가 비었을 때의 fallback.
    private(set) var pointCloud: GridPointCloud?
    /// 미니맵 배경·3D 뷰어 공용 실시간 mesh — 파이프라인이 1.5초 주기, 입력 변경 시에만 발행.
    private(set) var liveMesh: ColoredMesh?
    /// 복구 불가 오류 (권한 거부 등). 표시되면 스캔 UI 대신 안내 화면.
    private(set) var fatalMessage: String?
    private(set) var isPermissionDenied = false

    // MARK: - 전체화면 지도 (열면 자동 일시정지 — 보는 동안 데이터·mesh가 흐르지 않게)

    private(set) var isMapExpanded = false
    /// 거리 측정 점(월드 xz, 최대 2개) — 탭으로 지정, 세 번째 탭은 새 측정 시작. 3D 뷰어가 직접 쓴다.
    var measurePoints: [SIMD2<Float>] = []
    /// 세계 창 — 중심(월드 xz)과 반경(m). 팬 = 중심 이동, 줌 = 반경 축소.
    /// nil이면 첫 스냅샷의 관측 영역으로 auto-fit 초기화.
    private(set) var viewCenter: SIMD2<Float>?
    private(set) var viewRadius: Float = 5
    static let viewRadiusRange: ClosedRange<Float> = 0.5...20
    var mapViewMode: MapViewMode = .map2D {
        didSet {
            guard mapViewMode == .cloud3D, oldValue != .cloud3D else { return }
            sessionManager.exportPointCloud()   // 최신 격자 반영
            frozenMesh = liveMesh               // 진입 시점 고정 — 재진입하면 새로 고정
        }
    }
    /// 3D 진입 시점의 mesh 고정 — 보는 중 재빌드로 카메라 리셋·기하 교체(공간 뒤틀림)가 없게.
    private(set) var frozenMesh: ColoredMesh?
    /// 전체화면을 열며 자동 일시정지했는가 — 닫을 때 이전 상태(스캔 중)로만 복귀.
    private var resumeAfterExpand = false

    /// 3D 뷰어에 넘길 mesh — 고정본 우선.
    var expandedMesh: ColoredMesh? { frozenMesh ?? liveMesh }
    /// 오버레이 미니맵 배경. 진단 빌드의 "격자만 보기"면 nil.
    var minimapBackgroundMesh: ColoredMesh? {
        #if SCAN_DIAGNOSTICS
        if diagnosticGridOnly { return nil }
        #endif
        return liveMesh
    }

    #if SCAN_DIAGNOSTICS
    private(set) var diagnostics = ScanDiagnostics()
    private(set) var diagnosticSnapshotTime: TimeInterval = 0
    private(set) var diagnosticMeshTime: TimeInterval = 0
    private(set) var diagnosticEvents: [String] = []
    private(set) var diagnosticMarker = 0
    let diagnosticStarted = ProcessInfo.processInfo.systemUptime
    var diagnosticGridOnly = false

    func markDiagnosticEvent(_ text: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - diagnosticStarted
        diagnosticEvents.append(String(format: "%06.1fs %@", elapsed, text))
        if diagnosticEvents.count > 6 { diagnosticEvents.removeFirst(diagnosticEvents.count - 6) }
    }

    func markDiagnosticSection() {
        diagnosticMarker += 1
        markDiagnosticEvent("구간 #\(diagnosticMarker)")
    }
    #endif

    let isDeviceSupported = ARSessionManager.isDeviceSupported
    private let sessionManager = ARSessionManager()

    /// MainActor 격리 deinit은 iOS 17 back-deploy 경로(swift_task_deinitOnExecutor)에서
    /// 크래시한다 (시뮬레이터 테스트에서 재현). 정리할 격리 상태가 없으므로 nonisolated로 해제.
    /// 출력 루프 Task는 [weak self]라 VM이 해제되면 매니저·스트림이 닫히며 스스로 끝난다.
    nonisolated deinit {}

    init() {
        // 단일 스트림 for await — 큐 → MainActor hop이 한 곳이고 순서가 스트림에서 보장된다.
        Task { [weak self, outputs = sessionManager.outputs] in
            for await output in outputs {
                guard let self else { return }
                self.apply(output)
            }
        }
    }

    /// 출력 하나를 상태로 반영. internal: `ScanViewModelTests`가 직접 호출.
    func apply(_ output: ScanOutput) {
        switch output {
        case .snapshot(let value):
            snapshot = value
            #if SCAN_DIAGNOSTICS
            diagnosticSnapshotTime = ProcessInfo.processInfo.systemUptime
            #endif
            if isMapExpanded { autoFitWorldWindowIfNeeded() }   // 첫 스냅샷 전에 열렸으면 도착 시 재시도
        case .event(let event):
            handle(event)
        case .mesh(let mesh):
            liveMesh = mesh
            #if SCAN_DIAGNOSTICS
            diagnosticMeshTime = ProcessInfo.processInfo.systemUptime
            #endif
        case .pointCloud(let cloud):
            pointCloud = cloud
        case .plyFile(let url):
            exportURL = url
        #if SCAN_DIAGNOSTICS
        case .diagnostics(let value):
            diagnostics = value
        #endif
        }
    }

    /// 이벤트 → 배지 상태. internal: `ScanViewModelTests`가 직접 호출.
    func handle(_ event: ScanEvent) {
        #if SCAN_DIAGNOSTICS
        switch event {
        case .trackingChanged(let message): markDiagnosticEvent(message ?? "트래킹 정상")
        case .sessionFailed(let message, _): markDiagnosticEvent(message)
        case .interruptionChanged(let interrupted): markDiagnosticEvent(interrupted ? "세션 중단" : "세션 복귀")
        case .meshReady: markDiagnosticEvent("mesh 준비")
        }
        #endif
        switch event {
        case .trackingChanged(let message):
            trackingMessage = message
        case .sessionFailed(let message, let isPermission):
            fatalMessage = message
            isPermissionDenied = isPermission
        case .interruptionChanged(let interrupted):
            isInterrupted = interrupted
        case .meshReady:
            isMeshReady = true
        }
    }

    /// ARView가 소유한 세션을 파이프라인에 연결. View → ViewModel → Model 경로 유지용.
    func attach(session: ARSession) {
        sessionManager.attach(to: session)
    }

    // MARK: - 스캔 제어

    func start() {
        #if SCAN_DIAGNOSTICS
        markDiagnosticEvent("시작/재개 요청")
        #endif
        sessionManager.startAccumulating()
        state = .scanning
    }

    func pause() {
        #if SCAN_DIAGNOSTICS
        markDiagnosticEvent("일시정지 요청")
        #endif
        sessionManager.pauseAccumulating()
        state = .paused
    }

    func reset() {
        #if SCAN_DIAGNOSTICS
        markDiagnosticEvent("초기화 요청")
        diagnosticMeshTime = 0
        #endif
        sessionManager.reset()
        liveMesh = nil       // 옛 방 mesh 잔상 즉시 제거 — 다음 빌드까지 격자 fallback
        pointCloud = nil
        exportURL = nil
        // snapshot은 여기서 nil로 만들지 않는다 — 처리 큐(직렬)가 곧 빈 스냅샷을 발행하고,
        // nil로 만들면 "카메라 준비 중…" 오버레이가 라이브 카메라 위에 오발되고
        // 그 사이 도착하는 옛 그리드 스냅샷이 한 프레임 되살아난다.
        isMeshReady = false  // resetSceneReconstruction — 다음 meshReady까지 배지 대상
        state = .ready
    }

    /// 일시 오류(트래킹 실패, 카메라 점유 등) 후 재시도. 권한 거부는 설정 변경 없이는 복구 불가.
    func retry() {
        fatalMessage = nil
        isPermissionDenied = false
        // 재생성된 새 세션은 중단된 적이 없어 interruptionEnded가 오지 않는다 — 여기서 지워야 배지가 안 남는다.
        isInterrupted = false
        trackingMessage = nil
        reset()
    }

    // MARK: - 전체화면 지도 제어

    /// 열 때 스캔 중이면 자동 일시정지 — 결과를 보는 동안 데이터·mesh가 흐르지 않게 (뒤틀림·라벨 유동 방지).
    func openExpandedMap() {
        #if SCAN_DIAGNOSTICS
        markDiagnosticEvent("전체화면 열기")
        #endif
        resumeAfterExpand = (state == .scanning)
        if resumeAfterExpand { pause() }
        isMapExpanded = true
        exportURL = nil
        pointCloud = nil
        sessionManager.exportPly()          // ShareLink용 — 결과는 .plyFile
        sessionManager.exportPointCloud()   // 3D 전환 시 바로 보이게 미리 준비
        autoFitWorldWindowIfNeeded()
    }

    func closeExpandedMap() {
        #if SCAN_DIAGNOSTICS
        markDiagnosticEvent("전체화면 닫기")
        #endif
        isMapExpanded = false
        measurePoints = []
        viewCenter = nil; viewRadius = 5
        mapViewMode = .map2D
        frozenMesh = nil
        // 열기 전이 스캔 중이었을 때만 복귀 — 수동 일시정지 상태는 존중
        if resumeAfterExpand { start() }
        resumeAfterExpand = false
    }

    /// 팬 — 세계 창 중심 이동.
    func panWorldWindow(to center: SIMD2<Float>) { viewCenter = center }

    /// 줌 — 반경을 범위 안으로.
    func zoomWorldWindow(radius: Float) {
        viewRadius = min(max(radius, Self.viewRadiusRange.lowerBound), Self.viewRadiusRange.upperBound)
    }

    /// 2D 전체화면 탭 → 측정점. mesh 배경(세계 창 매핑)에서만 유효 —
    /// 격자 fallback은 다른 매핑이라 측정을 받지 않는다.
    func addMeasurePoint(world: SIMD2<Float>) {
        guard liveMesh?.positions.isEmpty == false else { return }
        measurePoints = measurePoints.count >= 2 ? [world] : measurePoints + [world]
    }

    /// 세계 창 auto-fit 초기화: 관측 영역 중심 + 반경 (스냅샷 crop 기반). 이미 설정돼 있으면 유지.
    private func autoFitWorldWindowIfNeeded() {
        guard viewCenter == nil, let snapshot else { return }
        viewCenter = snapshot.worldPoint(normalized: CGPoint(x: 0.5, y: 0.5))
        viewRadius = max(snapshot.cropSideMeters / 2, 2)
    }
}
