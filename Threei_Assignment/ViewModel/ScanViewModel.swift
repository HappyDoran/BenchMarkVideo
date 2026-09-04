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
    /// 복구 불가 오류 (권한 거부 등). 표시되면 스캔 UI 대신 안내 화면.
    private(set) var fatalMessage: String?
    private(set) var isPermissionDenied = false

    let isDeviceSupported = ARSessionManager.isDeviceSupported
    private let sessionManager = ARSessionManager()

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

    private func handle(_ event: ScanEvent) {
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
        isMeshReady = false  // resetSceneReconstruction — 다음 meshReady까지 배지 대상
        state = .ready
    }

    /// 일시 오류(트래킹 실패, 카메라 점유 등) 후 재시도. 권한 거부는 설정 변경 없이는 복구 불가.
    func retry() {
        fatalMessage = nil
        isPermissionDenied = false
        reset()
    }
}
