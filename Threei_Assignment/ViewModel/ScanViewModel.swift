import ARKit
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
    /// 복구 불가 오류 (권한 거부 등). 표시되면 스캔 UI 대신 안내 화면.
    private(set) var fatalMessage: String?
    private(set) var isPermissionDenied = false

    let isDeviceSupported = ARSessionManager.isDeviceSupported
    private let sessionManager = ARSessionManager()

    init() {
        sessionManager.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            Task { @MainActor in self.snapshot = snapshot }
        }
        sessionManager.onEvent = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
    }

    private func handle(_ event: ScanEvent) {
        switch event {
        case .trackingChanged(let message):
            trackingMessage = message
        case .sessionFailed(let message, let isPermission):
            fatalMessage = message
            isPermissionDenied = isPermission
        case .interruptionChanged(let interrupted):
            isInterrupted = interrupted
        }
    }

    /// ARView가 소유한 세션을 파이프라인에 연결. View → ViewModel → Model 경로 유지용.
    func attach(session: ARSession) {
        sessionManager.attach(to: session)
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
        snapshot = nil
        state = .ready
    }
}
