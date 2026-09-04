import ARKit
import RealityKit
import SwiftUI

/// 카메라 프리뷰 + 스캔 메시 시각화.
/// 직접 Metal 포인트 렌더러 대신 RealityKit sceneReconstruction 와이어프레임 사용
/// (요구사항 무게중심은 미니맵 — DESIGN.md 참고).
struct ARPreviewView: UIViewRepresentable {
    /// ARView가 소유한 ARSession을 넘겨 받는 콜백. View는 Model을 직접 만지지 않고 ViewModel 경유 (MVVM).
    let onSessionReady: (ARSession) -> Void
    /// mesh 와이어프레임 표시 여부. 재구성 자체는 세션 쪽이 첫 프레임부터 예열하고,
    /// 여기서는 그리기만 켜고 끈다 — 스캔 전에는 보이지 않아야 한다.
    var showMesh: Bool = false

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        arView.renderOptions.insert([.disableMotionBlur, .disableDepthOfField,
                                     .disableHDR, .disablePersonOcclusion,
                                     .disableAREnvironmentLighting, .disableGroundingShadows,
                                     .disableCameraGrain])
        onSessionReady(arView.session)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        if showMesh {
            uiView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            uiView.debugOptions.remove(.showSceneUnderstanding)
        }
    }
}
