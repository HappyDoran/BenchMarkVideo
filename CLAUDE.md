# Threei_Assignment — 실시간 공간 스캔 & Top-Down Minimap

3i iOS 사전과제. LiDAR(sceneDepth) 기반 실시간 스캔 + occupancy grid 미니맵.

## 빌드 / 실행

- Xcode 26.1, iOS 17.0+, SwiftUI. 테스트 기기: iPhone 15 Pro (실기기 필수 — sceneDepth는 시뮬레이터/비-LiDAR 기기에서 nil).
- 컴파일 검증: `xcodebuild -project Threei_Assignment.xcodeproj -scheme Threei_Assignment -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
- Portrait 고정 (iPhone/iPad).

## 좌표계 규약 — 절대 어기지 말 것

- ARKit 월드: **+y = 위(중력 반대)**. 미니맵 = **xz 평면** 투영.
- `ARCamera.intrinsics`는 **capturedImage(landscape) 해상도 기준**. depthMap(256×192)에 쓸 때는 해상도 비율로 스케일.
- unprojection 경로: `world = camera.transform × flipYZ × (K⁻¹·(u,v,1)·depth)`. flipYZ = diag(1,-1,-1) — 이미지 좌표(y-down, z-forward)를 ARKit 카메라 좌표(y-up, -z-forward)로 변환. **depthMap 픽셀을 버퍼 좌표 그대로 순회하므로 UI 회전(portrait)은 월드 좌표 경로에 영향 없음.**
- 카메라 heading(yaw): 시선 = transform의 -z축. `atan2(-m.columns.2.x, -m.columns.2.z)`.
- 미니맵 방향: **월드 고정(north-up)**. 그리드 원점 = 스캔 시작 시 기기 위치. map col ∝ world x, map row ∝ world z.
- simd_float4x4는 **column-major**. translation = columns.3.

## 동시성 규약

- 빌드 설정 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. UI/ViewModel은 기본 MainActor.
- 스캔 파이프라인(ARSessionManager, OccupancyGrid, 렌더러)은 `nonisolated` 명시, **전용 직렬 큐 `scan.processing`에서만 접근**. ARSession.delegateQueue = 그 큐.
- delegate 콜백 안에서 ARFrame을 오래 붙잡지 말 것 (프레임 풀 고갈). 콜백 내 동기 처리 목표 <10ms.
- 그리드→UI 전달은 불변 스냅샷(CGImage + pose)을 MainActor로 hop.

## 아키텍처

```
ARView(RealityKit, mesh 시각화) ─ session ─► ARSessionManager (delegateQueue: scan.processing)
                                                │ 스로틀(≥100ms) + 샘플링(stride, confidence≥medium)
                                                ▼
                                     DepthFrameProcessor (unprojection, 순수 함수 — 테스트 대상)
                                                ▼
                                     OccupancyGrid (5cm cell, 고정 400×400, floor/wall hit 분리)
                                                ▼
                                     MinimapRenderer (used-bounds crop → CGImage)
                                                ▼
                                     ScanViewModel (@Observable, MainActor) ─► SwiftUI
```

- 카메라 위 스캔 시각화는 Apple Metal 포인트클라우드 샘플 대신 RealityKit `sceneReconstruction` + `.showSceneUnderstanding` 사용 (직접 렌더러 없음 — 과제 무게중심은 미니맵).
- 바닥/천장 필터 v1: 높이 슬라이스 (월드 y 기준 밴드). 그리드/필터 파라미터는 `OccupancyGrid.swift` 상수.

## 문서 규칙

- LLM 제안을 기각/수정한 사례 발생 즉시 `LLM_REPORT.md`에 추가 (몰아 쓰기 금지).
- 설계 판단(격자 해상도, 스로틀, 필터 밴드 등) 변경 시 DESIGN.md 근거 갱신.
- 커밋은 의미 단위. 메시지에 작성 주체 표기: `[llm]`, `[human]`, `[llm+human]`.
