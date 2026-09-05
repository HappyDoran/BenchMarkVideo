import SceneKit
import simd
import SwiftUI

/// 정점 색 mesh를 직교 카메라로 수직 하향 촬영한 실시간 top-down 레이어 — 게임 미니맵 배경용.
/// 격자 비트맵(5cm 셀)보다 mesh 삼각형 보간이 조밀해 최종결과물 영상의 매끈한 미니맵 질감을 낸다.
/// 방위는 격자 미니맵과 동일한 north-up: 화면 위 = 월드 -z, 오른쪽 = +x. 카메라는 사용자 위치 추적.
struct MeshTopDownView: UIViewRepresentable {
    let mesh: ColoredMesh?
    let cameraXZ: SIMD2<Float>
    var visibleRadius: Float = 3

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false     // 탭은 상위(전체화면 전환)로
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling2X

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(visibleRadius)   // 반높이(m) — 정사각 뷰라 한 변 2r
        camera.zNear = 0.1
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        context.coordinator.cameraNode = cameraNode

        let meshNode = SCNNode()
        scene.rootNode.addChildNode(meshNode)
        context.coordinator.meshNode = meshNode

        apply(to: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        apply(to: context.coordinator)
    }

    private func apply(to coordinator: Coordinator) {
        // 카메라: 지정 위치 상공 20m에서 수직 하향, 화면 위 = 월드 -z (north-up).
        // orthographicScale도 매번 갱신 — 전체화면 핀치 줌이 반경으로 들어온다.
        if let cam = coordinator.cameraNode {
            cam.simdPosition = SIMD3(cameraXZ.x, 20, cameraXZ.y)
            cam.simdLook(at: SIMD3(cameraXZ.x, 0, cameraXZ.y),
                         up: SIMD3(0, 0, -1), localFront: SIMD3(0, 0, -1))
            cam.camera?.orthographicScale = Double(visibleRadius)
        }
        // mesh: 정점 수가 바뀌었을 때만 재구성 (1~2초 주기 갱신)
        let count = mesh?.positions.count ?? 0
        if coordinator.meshSignature != count, let mesh {
            coordinator.meshSignature = count
            coordinator.meshNode?.geometry = PointCloudViewerView.makeMeshGeometry(mesh)
        }
    }

    @MainActor
    final class Coordinator {
        var cameraNode: SCNNode?
        var meshNode: SCNNode?
        var meshSignature = -1
    }
}
