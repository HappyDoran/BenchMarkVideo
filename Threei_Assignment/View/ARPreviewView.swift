import ARKit
import RealityKit
import SwiftUI

/// 카메라 프리뷰 + 스캔 메시 시각화.
/// 직접 Metal 포인트 렌더러 대신 RealityKit sceneReconstruction 와이어프레임 사용
/// (요구사항 무게중심은 미니맵 — DESIGN.md 참고).
struct ARPreviewView: UIViewRepresentable {
    /// ARView가 소유한 ARSession을 넘겨 받는 콜백. View는 Model을 직접 만지지 않고 ViewModel 경유 (MVVM).
    let onSessionReady: (ARSession) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.renderOptions.insert([.disableMotionBlur, .disableDepthOfField,
                                     .disableHDR, .disablePersonOcclusion])
        onSessionReady(arView.session)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
