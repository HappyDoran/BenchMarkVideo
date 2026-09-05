import SceneKit
import simd
import SwiftUI

/// 스캔 점군 3D 뷰어 (가산점: 3D 재구성 뷰어).
/// 새 렌더러를 만들지 않는다 — .ply 내보내기와 같은 점군(`GridPointCloud`)을
/// SceneKit 점 지오메트리로 올리고, 회전·줌·팬은 `allowsCameraControl`에 맡긴다.
/// 측정: 바닥 평면(y=0) 탭 → 월드 xz — 2D 미니맵과 같은 `measurePoints`를 공유해
/// 어느 모드에서 찍든 두 뷰에 함께 보이고 거리 계산도 동일하다.
struct PointCloudViewerView: UIViewRepresentable {
    let cloud: GridPointCloud
    /// 정점 색 mesh — 있으면 점군 대신 표시 (레퍼런스 앱 텍스처 뷰의 정점 색 근사).
    var mesh: ColoredMesh? = nil
    @Binding var measurePoints: [SIMD2<Float>]

    /// 바닥 히트테스트 전용 카테고리 (점군과 분리).
    private static let floorCategory = 2

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.makeScene(cloud: cloud, mesh: mesh)
        context.coordinator.contentSignature = Self.signature(cloud: cloud, mesh: mesh)
        view.allowsCameraControl = true          // 궤도 회전·핀치 줌·두 손가락 팬
        view.backgroundColor = .black
        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        // mesh가 뒤늦게 도착하면 장면 재구성 (같은 데이터면 카메라 자세 유지 위해 건드리지 않음)
        let signature = Self.signature(cloud: cloud, mesh: mesh)
        if context.coordinator.contentSignature != signature {
            context.coordinator.contentSignature = signature
            uiView.scene = Self.makeScene(cloud: cloud, mesh: mesh)
        }
        context.coordinator.syncMarkers(in: uiView, points: measurePoints)
    }

    private static func signature(cloud: GridPointCloud, mesh: ColoredMesh?) -> Int {
        (mesh?.positions.count ?? 0) &* 31 &+ cloud.positions.count
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PointCloudViewerView
        var contentSignature = 0
        init(_ parent: PointCloudViewerView) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let hits = view.hitTest(gesture.location(in: view),
                                    options: [.categoryBitMask: PointCloudViewerView.floorCategory,
                                              .ignoreHiddenNodes: false])
            guard let hit = hits.first else { return }
            let world = SIMD2(hit.worldCoordinates.x, hit.worldCoordinates.z)
            let current = parent.measurePoints
            parent.measurePoints = current.count >= 2 ? [world] : current + [world]
        }

        /// 측정 마커·선 노드를 measurePoints와 동기화. 이름으로 지우고 다시 그린다 (점 최대 2개라 비용 무시).
        func syncMarkers(in view: SCNView, points: [SIMD2<Float>]) {
            guard let root = view.scene?.rootNode else { return }
            root.childNodes.filter { $0.name == "measure" }.forEach { $0.removeFromParentNode() }
            for p in points {
                let sphere = SCNSphere(radius: 0.06)
                sphere.firstMaterial?.diffuse.contents = UIColor.orange
                sphere.firstMaterial?.lightingModel = .constant
                let node = SCNNode(geometry: sphere)
                node.position = SCNVector3(p.x, 0.05, p.y)
                node.name = "measure"
                root.addChildNode(node)
            }
            if points.count == 2 {
                let vertices = [SCNVector3(points[0].x, 0.05, points[0].y),
                                SCNVector3(points[1].x, 0.05, points[1].y)]
                let source = SCNGeometrySource(vertices: vertices)
                let indices: [Int32] = [0, 1]
                let element = indices.withUnsafeBufferPointer { buf in
                    SCNGeometryElement(data: Data(buffer: buf), primitiveType: .line,
                                       primitiveCount: 1, bytesPerIndex: MemoryLayout<Int32>.size)
                }
                let line = SCNGeometry(sources: [source], elements: [element])
                line.firstMaterial?.diffuse.contents = UIColor.orange
                line.firstMaterial?.lightingModel = .constant
                let node = SCNNode(geometry: line)
                node.name = "measure"
                root.addChildNode(node)
            }
        }
    }

    private static func makeScene(cloud: GridPointCloud, mesh: ColoredMesh?) -> SCNScene {
        let scene = SCNScene()

        // 측정 탭 대상: 보이지 않는 바닥 평면 (y=0). 점·삼각형 히트테스트 대신
        // 바닥 투영 측정으로 통일 — 2D 격자 측정과 같은 수평 거리 시맨틱.
        let floor = SCNNode(geometry: SCNPlane(width: 100, height: 100))
        floor.eulerAngles.x = -.pi / 2
        // isHidden: 렌더에서 완전 제외 — opacity 트릭은 depth buffer에 남아 낮은 각도·아래 시점에서
        // mesh를 절반 가리는 결함이 있었다 (히트테스트는 ignoreHiddenNodes: false로 여전히 잡힘).
        floor.isHidden = true
        floor.categoryBitMask = floorCategory
        scene.rootNode.addChildNode(floor)

        // 정점 색 mesh가 있으면 삼각형으로 — 점군보다 레퍼런스 앱에 가까운 인상.
        if let mesh, !mesh.positions.isEmpty {
            scene.rootNode.addChildNode(SCNNode(geometry: makeMeshGeometry(mesh)))
            addCamera(to: scene, framing: mesh.positions)
            return scene
        }

        guard !cloud.positions.isEmpty else { return scene }
        addCamera(to: scene, framing: cloud.positions)

        let count = cloud.positions.count
        let vertexData = cloud.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)

        // 셀 색 → float RGB (0...1)
        var colorFloats = [Float](); colorFloats.reserveCapacity(count * 3)
        for c in cloud.colors {
            colorFloats.append(Float(c.x) / 255)
            colorFloats.append(Float(c.y) / 255)
            colorFloats.append(Float(c.z) / 255)
        }
        let colorSource = colorFloats.withUnsafeBufferPointer { buf in
            SCNGeometrySource(
                data: Data(buffer: buf), semantic: .color, vectorCount: count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: MemoryLayout<Float>.stride * 3)
        }

        let indices = Array(0..<Int32(count))
        let element = indices.withUnsafeBufferPointer { buf in
            SCNGeometryElement(data: Data(buffer: buf), primitiveType: .point,
                               primitiveCount: count, bytesPerIndex: MemoryLayout<Int32>.size)
        }
        // 점 크기: 화면 공간 반경으로 고정 — 안 주면 1px라 기기에서 안 보인다.
        element.pointSize = 0.05  // 격자 셀 한 변(m)과 동일 — 점이 셀 크기로 보이게
        element.minimumPointScreenSpaceRadius = 2
        element.maximumPointScreenSpaceRadius = 8

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant   // 조명 없이 셀 색 그대로

        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        return scene
    }

    /// 초기 카메라: 방 밖 위쪽 사선에서 전체를 내려다보게 배치 — 기본 카메라는 방 "안"에서
    /// 시작해 근평면에 벽이 잘려 보인다(레퍼런스 앱의 아이소메트릭 첫 화면과 같은 각도로 교정).
    private static func addCamera(to scene: SCNScene, framing positions: [SIMD3<Float>]) {
        var minV = positions[0], maxV = positions[0]
        for p in positions { minV = simd_min(minV, p); maxV = simd_max(maxV, p) }
        let center = (minV + maxV) / 2
        let distance = max(simd_length(maxV - minV), 2) * 1.1

        let camera = SCNCamera()
        camera.zNear = 0.05                       // 근접 클리핑 완화
        camera.zFar = Double(distance) * 10
        let node = SCNNode()
        node.camera = camera
        let dir = simd_normalize(SIMD3<Float>(0.6, 0.9, 0.6))   // 위 사선
        let pos = center + dir * distance
        node.position = SCNVector3(pos.x, pos.y, pos.z)
        node.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(node)
    }

    /// ColoredMesh → 정점 색 삼각형 지오메트리. 조명 없이 색 그대로, 양면 렌더.
    /// MeshTopDownView(미니맵)도 같은 빌더를 쓴다.
    static func makeMeshGeometry(_ mesh: ColoredMesh) -> SCNGeometry {
        let count = mesh.positions.count
        let vertexData = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)

        var colorFloats = [Float](); colorFloats.reserveCapacity(count * 3)
        for c in mesh.colors {
            colorFloats.append(Float(c.x) / 255)
            colorFloats.append(Float(c.y) / 255)
            colorFloats.append(Float(c.z) / 255)
        }
        let colorSource = colorFloats.withUnsafeBufferPointer { buf in
            SCNGeometrySource(
                data: Data(buffer: buf), semantic: .color, vectorCount: count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: MemoryLayout<Float>.stride * 3)
        }

        let element = mesh.indices.withUnsafeBufferPointer { buf in
            SCNGeometryElement(data: Data(buffer: buf), primitiveType: .triangles,
                               primitiveCount: mesh.indices.count / 3,
                               bytesPerIndex: MemoryLayout<Int32>.size)
        }
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant
        // 돌하우스 트릭: ARKit mesh의 면 방향은 관측한 쪽(방 안)을 향한다.
        // 뒷면 컬링을 켜면(양면 렌더 끔) 카메라를 등진 가까운 벽·천장이 투명해져
        // 밖에서 봐도 내부가 보인다 — 천장 스캔 후 닫힌 상자가 되는 문제와
        // top-down 미니맵이 천장에 덮이는 문제를 함께 해결 (뷰어·미니맵 공용 빌더).
        geometry.firstMaterial?.isDoubleSided = false
        return geometry
    }
}
