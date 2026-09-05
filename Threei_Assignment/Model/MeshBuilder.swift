import ARKit
import simd

/// 정점 색이 입혀진 삼각형 mesh — 3D 뷰어용 값 타입 (Sendable, 큐 경계 통과).
nonisolated struct ColoredMesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD3<UInt8>] = []
    var indices: [Int32] = []
    /// 빌드 순번 — 정점 수가 같아도 색·기하가 갱신됐는지 뷰가 판별하는 기준 (ARSessionManager가 부여).
    var version: Int = 0
}

/// 월드 복셀 → 카메라 색 저장소. 깊이 점(ScanPoint) 스트림에서 누적한다.
/// mesh 정점은 앵커 갱신으로 계속 바뀌므로 정점이 아니라 월드 공간에 색을 저장 —
/// 뷰어 생성 시점에 정점 위치로 조회한다 (레퍼런스 앱의 텍스처 베이킹을 정점 색으로 근사).
///
/// 스레딩: scan.processing 큐에서만 접근 (OccupancyGrid와 동일 규약).
nonisolated final class VoxelColorStore {

    /// 3단계 복셀(m) — 조밀할수록 색 디테일, 성길수록 미관측 정점 커버리지 (fallback 체인).
    static let fineSize: Float = 0.05
    static let midSize: Float = 0.15
    static let coarseSize: Float = 0.4

    private var fine: [SIMD3<Int32>: SIMD3<UInt8>] = [:]
    private var mid: [SIMD3<Int32>: SIMD3<UInt8>] = [:]
    private var coarse: [SIMD3<Int32>: SIMD3<UInt8>] = [:]

    static func key(_ p: SIMD3<Float>, size: Float) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((p.x / size).rounded(.down)),
                     Int32((p.y / size).rounded(.down)),
                     Int32((p.z / size).rounded(.down)))
    }

    /// 첫 관측은 그대로, 이후는 EMA(3:1) — OccupancyGrid 셀 색과 같은 규칙.
    func accumulate(points: [ScanPoint]) {
        for sp in points {
            blend(&fine, key: Self.key(sp.position, size: Self.fineSize), color: sp.color)
            blend(&mid, key: Self.key(sp.position, size: Self.midSize), color: sp.color)
            blend(&coarse, key: Self.key(sp.position, size: Self.coarseSize), color: sp.color)
        }
    }

    private func blend(_ map: inout [SIMD3<Int32>: SIMD3<UInt8>], key: SIMD3<Int32>, color: SIMD3<UInt8>) {
        if let old = map[key] {
            map[key] = SIMD3<UInt8>(truncatingIfNeeded:
                (SIMD3<UInt16>(truncatingIfNeeded: old) &* 3 &+ SIMD3<UInt16>(truncatingIfNeeded: color)) / 4)
        } else {
            map[key] = color
        }
    }

    /// 조밀 → 성긴 순 조회. 전부 없으면 nil (호출부가 중간 회색 등으로 대체).
    func color(at p: SIMD3<Float>) -> SIMD3<UInt8>? {
        fine[Self.key(p, size: Self.fineSize)]
            ?? mid[Self.key(p, size: Self.midSize)]
            ?? coarse[Self.key(p, size: Self.coarseSize)]
    }

    func reset() {
        fine.removeAll(keepingCapacity: true)
        mid.removeAll(keepingCapacity: true)
        coarse.removeAll(keepingCapacity: true)
    }
}

/// ARMeshAnchor 기하 + 복셀 색 → ColoredMesh. scan.processing 큐에서 호출 (앵커 스냅샷 소비).
nonisolated enum MeshBuilder {

    /// 색 미관측 정점의 대체색 (중간 회색).
    static let fallbackColor = SIMD3<UInt8>(128, 128, 128)

    static func coloredMesh(anchors: [ARMeshAnchor], colors store: VoxelColorStore) -> ColoredMesh {
        var mesh = ColoredMesh()
        for anchor in anchors {
            let g = anchor.geometry
            let base = Int32(mesh.positions.count)

            let v = g.vertices
            let vbuf = v.buffer.contents().advanced(by: v.offset)
            mesh.positions.reserveCapacity(mesh.positions.count + v.count)
            mesh.colors.reserveCapacity(mesh.colors.count + v.count)
            for i in 0..<v.count {
                // float3는 12바이트 packed — SIMD3 로드(16바이트) 금지, Float 3개로 읽는다.
                let f = vbuf.advanced(by: i * v.stride).assumingMemoryBound(to: Float.self)
                let local = SIMD4<Float>(f[0], f[1], f[2], 1)
                let w = anchor.transform * local
                let world = SIMD3(w.x, w.y, w.z)
                mesh.positions.append(world)
                mesh.colors.append(store.color(at: world) ?? fallbackColor)
            }

            let faces = g.faces
            let fbuf = faces.buffer.contents()
            let indexCount = faces.count * faces.indexCountPerPrimitive
            mesh.indices.reserveCapacity(mesh.indices.count + indexCount)
            if faces.bytesPerIndex == 4 {
                let p = fbuf.assumingMemoryBound(to: UInt32.self)
                for i in 0..<indexCount { mesh.indices.append(base + Int32(p[i])) }
            } else {
                let p = fbuf.assumingMemoryBound(to: UInt16.self)
                for i in 0..<indexCount { mesh.indices.append(base + Int32(p[i])) }
            }
        }
        return mesh
    }
}
