import ARKit
import simd

/// 정점 색이 입혀진 삼각형 mesh — 3D 뷰어용 값 타입 (Sendable, 큐 경계 통과).
nonisolated struct ColoredMesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD3<UInt8>] = []
    var indices: [Int32] = []
    /// 빌드 순번 — 정점 수가 같아도 색·기하가 갱신됐는지 뷰가 판별하는 기준 (ScanPipeline이 부여).
    var version: Int = 0
    #if SCAN_DIAGNOSTICS
    var diagnosticGeneration = 0
    var diagnosticSourceTimestamp: Double = 0
    var diagnosticBuildMs: Double = 0
    #endif

    /// 측정 평면용 바닥 높이 (밀도 기반 — MeshBuilder.estimatedFloorY).
    var estimatedFloorY: Float { MeshBuilder.estimatedFloorY(of: positions) }
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

    #if SCAN_DIAGNOSTICS
    var diagnosticEntryCount: Int { fine.count + mid.count + coarse.count }
    #endif

    private var fine: [SIMD3<Int32>: SIMD3<UInt8>] = [:]
    private var mid: [SIMD3<Int32>: SIMD3<UInt8>] = [:]
    private var coarse: [SIMD3<Int32>: SIMD3<UInt8>] = [:]

    /// 월드 위치를 지정한 크기의 복셀 정수 좌표로 양자화한다.
    static func key(_ p: SIMD3<Float>, size: Float) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((p.x / size).rounded(.down)),
                     Int32((p.y / size).rounded(.down)),
                     Int32((p.z / size).rounded(.down)))
    }

    /// 첫 관측은 그대로, 이후는 EMA(3:1) — OccupancyGrid 셀 색과 같은 규칙.
    func accumulate(points: [ScanPoint]) {
        // 같은 관측점을 세 해상도에 함께 저장해 색 디테일과 미관측 정점 커버리지를 모두 확보한다.
        for sp in points {
            blend(&fine, key: Self.key(sp.position, size: Self.fineSize), color: sp.color)
            blend(&mid, key: Self.key(sp.position, size: Self.midSize), color: sp.color)
            blend(&coarse, key: Self.key(sp.position, size: Self.coarseSize), color: sp.color)
        }
    }

    private func blend(_ map: inout [SIMD3<Int32>: SIMD3<UInt8>], key: SIMD3<Int32>, color: SIMD3<UInt8>) {
        // 기존 색이 있으면 이전 관측에 3배 가중치를 둔 EMA로 프레임별 색 노이즈를 누른다.
        if let old = map[key] {
            map[key] = SIMD3<UInt8>(truncatingIfNeeded:
                (SIMD3<UInt16>(truncatingIfNeeded: old) &* 3 &+ SIMD3<UInt16>(truncatingIfNeeded: color)) / 4)
        } else {
            // 처음 관측한 복셀은 카메라 색을 손실 없이 그대로 저장한다.
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
        // 딕셔너리 용량은 재사용하면서 이전 공간의 모든 복셀 색만 제거한다.
        fine.removeAll(keepingCapacity: true)
        mid.removeAll(keepingCapacity: true)
        coarse.removeAll(keepingCapacity: true)
    }
}

/// ARMeshAnchor 기하 + 복셀 색 → ColoredMesh. scan.processing 큐에서 호출 (앵커 스냅샷 소비).
nonisolated enum MeshBuilder {

    /// 색 미관측 정점의 대체색 (중간 회색).
    static let fallbackColor = SIMD3<UInt8>(128, 128, 128)

    /// 바닥 높이 추정 — 정점 y 히스토그램(10cm)에서 아래부터 올라가며 충분히 밀집한 첫 버킷.
    /// 단순 최저값은 유리 반사·노이즈가 실제 바닥보다 수 m 아래 허상 정점을 만들면 그리로 끌려가
    /// 측정 평면·마커가 지하에 깔린다 — 바닥 슬래브는 정점이 밀집하므로 밀도 임계로 걸러낸다.
    /// View는 값 타입 프로퍼티(ColoredMesh/GridPointCloud.estimatedFloorY)로 소비한다.
    static func estimatedFloorY(of positions: [SIMD3<Float>]) -> Float {
        // 정점이 없으면 3D 측정 평면의 안전한 기본 높이인 0을 사용한다.
        guard let minY = positions.map(\.y).min() else { return 0 }
        // 최저 정점을 기준으로 10cm 높이 구간별 정점 수를 집계한다.
        let bucketSize: Float = 0.1
        var counts: [Int: Int] = [:]
        for p in positions {
            counts[Int(((p.y - minY) / bucketSize).rounded(.down)), default: 0] += 1
        }
        // 가장 밀집한 높이의 20% 또는 50개 이상인 첫 구간만 실제 바닥 후보로 인정한다.
        let threshold = max((counts.values.max() ?? 0) / 5, 50)
        let floorBucket = counts.keys.sorted().first { counts[$0]! >= threshold } ?? 0
        return minY + (Float(floorBucket) + 0.5) * bucketSize
    }

    static func coloredMesh(anchors: [ARMeshAnchor], colors store: VoxelColorStore) -> ColoredMesh {
        // 여러 ARMeshAnchor의 정점과 인덱스를 하나의 월드 좌표 mesh로 합친다.
        var mesh = ColoredMesh()
        for anchor in anchors {
            // 현재 앵커의 로컬 인덱스가 가리킬 전역 정점 시작 위치를 기억한다.
            let g = anchor.geometry
            let base = Int32(mesh.positions.count)

            // Metal vertex buffer의 offset과 stride를 존중해 각 float3를 읽는다.
            let v = g.vertices
            let vbuf = v.buffer.contents().advanced(by: v.offset)
            mesh.positions.reserveCapacity(mesh.positions.count + v.count)
            mesh.colors.reserveCapacity(mesh.colors.count + v.count)
            for i in 0..<v.count {
                // float3는 12바이트 packed — SIMD3 로드(16바이트) 금지, Float 3개로 읽는다.
                let f = vbuf.advanced(by: i * v.stride).assumingMemoryBound(to: Float.self)
                let local = SIMD4<Float>(f[0], f[1], f[2], 1)
                // 앵커 로컬 정점을 고정된 ARKit 월드 좌표로 변환한다.
                let w = anchor.transform * local
                let world = SIMD3(w.x, w.y, w.z)
                mesh.positions.append(world)
                // 같은 월드 복셀에서 관측한 RGB를 붙이고 없으면 중간 회색으로 표시한다.
                mesh.colors.append(store.color(at: world) ?? fallbackColor)
            }

            // face index 폭에 맞춰 UInt32 또는 UInt16으로 읽고 전역 base를 더한다.
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
        // 모든 앵커가 한 SceneKit geometry에서 소비할 수 있는 값 타입 mesh가 완성된다.
        return mesh
    }
}
