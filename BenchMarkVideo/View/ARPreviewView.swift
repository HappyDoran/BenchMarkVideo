import ARKit
import RealityKit
import SwiftUI
#if SCAN_DIAGNOSTICS
import Observation
import os
import QuartzCore
#endif

/// 카메라 프리뷰 + 스캔 메시 시각화.
/// 직접 Metal 포인트 렌더러 대신 RealityKit sceneReconstruction 와이어프레임 사용
/// (요구사항 무게중심은 미니맵 — DESIGN.md 참고).
struct ARPreviewView: UIViewRepresentable {
    /// ARView가 소유한 ARSession을 넘겨 받는 콜백. View는 Model을 직접 만지지 않고 ViewModel 경유 (MVVM).
    let onSessionReady: (ARSession) -> Void
    /// mesh 와이어프레임 표시 여부. 재구성 자체는 세션 쪽이 첫 프레임부터 예열하고,
    /// 여기서는 그리기만 켜고 끈다 — 스캔 전에는 보이지 않아야 한다.
    var showMesh: Bool = false

    /// RealityKit ARView를 만들고 렌더 옵션과 Model 연결을 최초 한 번 구성한다.
    func makeUIView(context: Context) -> ARView {
        #if SCAN_DIAGNOSTICS
        FPSMonitor.shared.start()
        #endif
        // 세션 자동 구성을 끄고 ARSessionManager가 깊이·mesh 설정의 단일 소유자가 되게 한다.
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        // 스캔 판독에 필요 없는 후처리를 꺼 패스스루 지연과 GPU 부하를 줄인다.
        arView.renderOptions.insert([.disableMotionBlur, .disableDepthOfField,
                                     .disableHDR, .disablePersonOcclusion,
                                     .disableAREnvironmentLighting, .disableGroundingShadows,
                                     .disableCameraGrain])
        // ARView가 실제로 소유한 세션만 ViewModel 경유로 Model에 전달한다.
        onSessionReady(arView.session)
        return arView
    }

    // 표시 셰이더 별도 예열은 두지 않는다 — 스캔 전 표시를 잠깐 켜는 방식은 체크무늬가
    // 사용자에게 노출돼 "mesh 보임 = 기록 중" 문법을 깬다 (실기기 확인). 첫 시작이
    // 재구성을 리셋하므로 셰이더 컴파일은 앵커 재생성 창("주변 인식 중…" 배지) 안에 흡수된다.
    func updateUIView(_ uiView: ARView, context: Context) {
        // 스캔 상태와 RealityKit의 scene-understanding 디버그 표시를 동기화한다.
        if showMesh {
            uiView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            uiView.debugOptions.remove(.showSceneUnderstanding)
        }
    }
}

#if SCAN_DIAGNOSTICS
/// UI fps 계측 — Xcode FPS 게이지 대체. 3초마다 평균·최저 fps를 perf 로그(콘솔)로 남긴다.
/// R3-1 측정용, Release에는 미포함.
@Observable
@MainActor
final class FPSMonitor {
    static let shared = FPSMonitor()
    private(set) var average: Double = 0
    private(set) var maximumGapMs: Double = 0
    private(set) var measuredAt: TimeInterval = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frameCount = 0
    private var worstGap: CFTimeInterval = 0
    private let log = Logger(subsystem: "com.doran.benchmarkvideo", category: "perf")

    func start() {
        // 중복 CADisplayLink 생성을 막아 프레임 콜백과 로그가 배수로 늘지 않게 한다.
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        // 첫 tick은 간격을 계산할 이전 시각이 없으므로 창의 기준점만 저장한다.
        if windowStart == 0 {
            windowStart = link.timestamp
            lastTimestamp = link.timestamp
            return
        }
        // 평균 프레임 수와 가장 긴 표시 간격을 3초 창 안에서 누적한다.
        worstGap = max(worstGap, link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        frameCount += 1
        let elapsed = link.timestamp - windowStart
        // 3초가 모이기 전에는 UI 상태와 perf 로그를 갱신하지 않는다.
        guard elapsed >= 3 else { return }
        let avg = Double(frameCount) / elapsed
        let minFps = worstGap > 0 ? 1 / worstGap : 0
        average = avg
        maximumGapMs = worstGap * 1000
        measuredAt = ProcessInfo.processInfo.systemUptime
        log.info("ui fps avg=\(String(format: "%.1f", avg)) min=\(String(format: "%.1f", minFps))")
        // 발행이 끝난 시각부터 다음 독립 3초 창을 시작한다.
        windowStart = link.timestamp
        frameCount = 0
        worstGap = 0
    }
}
#endif
