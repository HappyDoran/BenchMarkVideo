import ARKit
import Foundation
import Observation

enum ScanState {
    case ready      // 세션은 돌지만 누적 전
    case scanning
    case paused
}

/// UI 상태 허브 (MainActor). 스캔 파이프라인의 스냅샷/이벤트를 받아 발행.
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
    /// 3D 뷰어용 정점 색 mesh — 있으면 점군 대신 표시.
    private(set) var coloredMesh: ColoredMesh?
    /// 오버레이 미니맵 배경용 실시간 mesh — 1.5초 주기 갱신.
    private(set) var liveMesh: ColoredMesh?
    private var meshRefreshTimer: Timer?
    /// 복구 불가 오류 (권한 거부 등). 표시되면 스캔 UI 대신 안내 화면.
    private(set) var fatalMessage: String?
    private(set) var isPermissionDenied = false

    let isDeviceSupported = ARSessionManager.isDeviceSupported
    private let sessionManager = ARSessionManager()

    /// MainActor 격리 deinit은 iOS 17 back-deploy 경로(swift_task_deinitOnExecutor)에서
    /// 크래시한다 (시뮬레이터 테스트에서 재현). 정리할 격리 상태가 없으므로 nonisolated로 해제.
    nonisolated deinit {}

    init() {
        // Task는 실행 순서를 보장하지 않아 이벤트/스냅샷이 뒤집힐 수 있다 — main 큐(FIFO)로 hop.
        sessionManager.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.snapshot = snapshot }
            }
        }
        sessionManager.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
    }

    /// internal: handle 분기가 넷을 넘어 test-policy 전환 조건 충족 — `ScanViewModelTests`가 직접 호출.
    func handle(_ event: ScanEvent) {
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
        startMeshRefresh()
    }

    /// 미니맵 배경 mesh를 1.5초마다 재생성 — 스캔 화면이 살아 있는 동안 계속.
    /// VM은 앱 수명과 같아 타이머 해제는 두지 않는다.
    private func startMeshRefresh() {
        meshRefreshTimer?.invalidate()
        meshRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionManager.exportColoredMesh { mesh in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.liveMesh = mesh }
                    }
                }
            }
        }
    }

    // MARK: - 스캔 제어

    func start() {
        sessionManager.startAccumulating()
        state = .scanning
    }

    func pause() {
        sessionManager.pauseAccumulating()
        state = .paused
    }

    func reset() {
        sessionManager.reset()
        // snapshot은 여기서 nil로 만들지 않는다 — 처리 큐(직렬)가 곧 빈 스냅샷을 발행하고,
        // nil로 만들면 "카메라 준비 중…" 오버레이가 라이브 카메라 위에 오발되고
        // 그 사이 도착하는 옛 그리드 스냅샷이 한 프레임 되살아난다.
        isMeshReady = false  // resetSceneReconstruction — 다음 meshReady까지 배지 대상
        state = .ready
    }

    /// 현재 격자를 .ply로 임시 파일에 써서 exportURL 발행 — 전체화면 미니맵의 공유 버튼용 (가산점: 내보내기).
    func prepareExport() {
        exportURL = nil
        sessionManager.exportPly { [weak self] text in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan.ply")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exportURL = url }
            }
        }
    }

    /// 3D 뷰어 데이터 준비 — 정점 색 mesh(우선)와 점군(fallback)을 발행.
    func preparePointCloud() {
        pointCloud = nil
        coloredMesh = nil
        sessionManager.exportPointCloud { [weak self] cloud in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pointCloud = cloud }
            }
        }
        sessionManager.exportColoredMesh { [weak self] mesh in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.coloredMesh = mesh }
            }
        }
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
}
