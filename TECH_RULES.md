---
title: Threei_Assignment 기술 스택과 구현 규칙
kind: rule
last_verified: 2026-09-04
---

# 기술 스택 및 구현 규칙

이 문서는 구현에 적용할 기술 규칙의 소유자다. 문서 소유권과 권위 순서는 `AGENTS.md` 문서 맵이 기준이다 — 여기 복사하지 않는다.

## 1. 고정 기술 스택

- Xcode 26.1, iOS 17.0+, Swift 6 언어 모드, SwiftUI 단일 타깃 `Threei_Assignment`
- ARKit (`ARWorldTrackingConfiguration`, `smoothedSceneDepth`, `sceneReconstruction = .mesh`)
- RealityKit `ARView` — 카메라 프리뷰와 스캔 mesh 시각화 (`.showSceneUnderstanding`)
- Observation (`@Observable`) — ViewModel 상태 발행
- CoreGraphics — 미니맵 비트맵 생성. simd — 좌표 연산
- XCTest — `Threei_AssignmentTests` 타깃 (Model 순수 함수, 시뮬레이터 실행)
- 서드파티 의존성 없음. 표준 프레임워크로 불가능한 경우에만 추가하고, 추가하면 이 절과 `DESIGN.md`에 사유를 적는다.
- 테스트 기기: iPhone 15 Pro (LiDAR). Portrait 고정 (iPhone/iPad).

## 2. 좌표계 규약 — 절대 어기지 말 것

- ARKit 월드: **+y = 위(중력 반대)**. 미니맵 = **xz 평면** 투영.
- `ARCamera.intrinsics`는 **capturedImage(landscape) 해상도 기준**. depthMap(256×192)에 쓸 때는 해상도 비율로 스케일한다 (`DepthFrameProcessor.UnprojectionParams`).
- unprojection 경로: `world = camera.transform × flipYZ × (K⁻¹·(u,v,1)·depth)`. flipYZ = diag(1,-1,-1) — 이미지 좌표(y-down, z-forward)를 ARKit 카메라 좌표(y-up, -z-forward)로 변환. **depthMap 픽셀을 버퍼 좌표 그대로 순회하므로 UI 회전(portrait)은 월드 좌표 경로에 영향 없음.**
- 카메라 heading(yaw): 시선 = transform의 -z축을 xz평면에 투영. `atan2(-m.columns.2.x, m.columns.2.z)` — 항등 변환에서 0(-z 방향), 단위 테스트 `testHeadingIdentityIsZeroAndLookingPlusXIsHalfPi`가 고정.
- 미니맵 방향: **월드 고정(north-up)**. 그리드 원점 = 스캔 시작 시 기기 위치. map col ∝ world x, map row ∝ world z.
- `simd_float4x4`는 **column-major**. translation = `columns.3`.

## 3. 동시성 규약

- 빌드 설정 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. View·ViewModel은 기본 MainActor.
- Model 계층(`ARSessionManager`, `OccupancyGrid`, `MinimapRenderer`, `DepthFrameProcessor`)은 `nonisolated` 명시. 가변 상태는 **전용 직렬 큐 `scan.processing`에서만 접근**한다. `ARSession.delegateQueue` = 그 큐.
- delegate 콜백 안에서 `ARFrame`을 오래 붙잡지 않는다 (프레임 풀 고갈). 콜백 내 동기 처리 목표 <10ms. 스로틀 미달 프레임은 즉시 반환.
- Model → ViewModel 전달은 불변 스냅샷(`MinimapSnapshot`: CGImage + pose)과 `ScanEvent` 값만. ViewModel이 `Task { @MainActor in }`로 hop한다.
- ViewModel → Model 제어(`startAccumulating`/`pauseAccumulating`/`reset`)는 아무 스레드에서 호출 가능하고 Model 내부에서 큐로 hop한다.

## 4. 아키텍처

MVVM 계층 폴더링. 배치 규칙과 허용 의존 방향은 `.codex/skills/mvvm-architecture/SKILL.md`, 채택 근거는 `DESIGN.md` 1.1절이 소유한다. 여기서는 상위 원칙만 못박는다:

- 의존 방향은 `View → ViewModel → Model` 단방향. View가 Model 객체를 직접 호출하지 않는다.
- 계층 경계 = 격리 경계. ViewModel은 MainActor, Model은 `scan.processing` 큐. 두 경계를 넘는 값은 `Sendable` 불변 타입이어야 한다.

```
ARView(RealityKit) ─ session ─► ARSessionManager (delegateQueue: scan.processing)   [Model]
                                     │ 스로틀(≥100ms) + 샘플링(stride 4, confidence≥medium)
                                     ▼
                          DepthFrameProcessor (unprojection, 순수 함수)             [Model]
                                     ▼
                          OccupancyGrid (5cm cell, 고정 400×400, floor/wall hit)    [Model]
                                     ▼
                          MinimapRenderer (used-bounds crop → MinimapSnapshot)      [Model]
                                     ▼  onSnapshot / onEvent (Sendable)
                          ScanViewModel (@Observable, MainActor)                    [ViewModel]
                                     ▼
                          ContentView · MinimapView · ARPreviewView                 [View]
```

## 5. 구현 금지 사항

각 금지에는 기술적 이유와 허용 예외를 함께 적는다 — 이유 없는 규칙은 다음 작업자가 되돌린다. 기계 검사 가능한 항목은 `scripts/check-structure.sh`가 잡는다.

| 금지 | 이유 | 허용 예외 |
| --- | --- | --- |
| `Model/`에서 `SwiftUI`·`UIKit`·`Observation` import | 파이프라인이 UI 프레임워크와 MainActor에 묶여 큐 격리와 단위 테스트 가능성이 깨진다 | 없음 |
| `View/`가 `ARSessionManager`·`OccupancyGrid`·`MinimapRenderer`·`DepthFrameProcessor`를 직접 참조 | ViewModel이 상태 허브가 아니게 되고 큐 hop 규약을 우회한다 | `MinimapSnapshot`·`ScanEvent` 같은 불변 값 타입 소비 |
| `Model/` 최상위 타입에 `nonisolated` 누락 | 기본 격리가 MainActor라 delegate 큐에서 접근하는 코드가 컴파일러 격리 검사와 충돌한다 | 없음 |
| delegate 콜백 밖으로 `ARFrame` 또는 그 버퍼 참조를 넘김 | ARKit 프레임 풀 고갈로 프레임 드롭 | 없음 — 필요한 값은 콜백 안에서 복사 |
| `scan.processing` 밖에서 grid·trajectory·`isAccumulating` 접근 | data race. `@unchecked Sendable`은 이 규약을 전제로만 안전하다 | 없음 |
| Model → UI로 가변 참조(그리드 배열 등) 전달 | 렌더 중 갱신되어 찢어진 프레임과 race | 없음 — 불변 `MinimapSnapshot`만 |
| `project.pbxproj` 수동 편집으로 파일 추가·이동 | synchronized group이라 불필요하고, 인코딩 오타 이력이 있다 | 빌드 설정·타깃 설정 변경 |
| 암묵 import 의존 (`Foundation`을 `CoreGraphics` 경유로 쓰는 등) | `MemberImportVisibility`로 컴파일 실패 | 없음 |

## 6. 검증

`README.md` 검증 절의 명령(단위 테스트, 컴파일, 구조 검사)을 전부 통과해야 완료다. 런타임 동작 변경은 실기기 수동 확인을 병행하고 결과를 완료 보고에 남긴다. 검증 계층 선택 기준은 `.codex/skills/test-policy/SKILL.md`.

## 7. 보고 규칙

- 실기기가 없어 검증하지 못한 항목은 "미검증"으로 명시하고, 가능한 범위(컴파일·구조 검사·순수 함수 수동 계산)까지만 통과로 적는다.
- 플랫폼 제약(시뮬레이터 depth 미지원, 기기별 sceneReconstruction 미지원)으로 요구사항 충족이 불가하면 우회 구현 대신 근거와 최소 대안을 보고한다.
