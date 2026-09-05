import SceneKit
import simd
import SwiftUI

/// 스캔 점군 3D 뷰어 (가산점: 3D 재구성 뷰어).
/// 새 렌더러를 만들지 않는다 — .ply 내보내기와 같은 점군(`GridPointCloud`)을
/// SceneKit 점 지오메트리로 올리고, 회전·줌·팬은 `allowsCameraControl`에 맡긴다.
struct PointCloudViewerView: UIViewRepresentable {
    let cloud: GridPointCloud

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.makeScene(cloud)
        view.allowsCameraControl = true          // 궤도 회전·핀치 줌·두 손가락 팬
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private static func makeScene(_ cloud: GridPointCloud) -> SCNScene {
        let scene = SCNScene()
        guard !cloud.positions.isEmpty else { return scene }

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
}
