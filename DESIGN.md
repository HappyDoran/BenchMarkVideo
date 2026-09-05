---
title: 기술 설계 문서
kind: design
last_verified: 2026-09-05
---

# 기술 설계 문서

각 판단은 결정, 이유, 검토한 대안, 되돌리기 조건, 검증 상태를 적는다. 파라미터 값의 정본은 코드 상수다 — 여기 적힌 숫자가 코드와 다르면 코드가 현재 사실이고 이 문서를 고친다. 요구사항 번호는 `docs/spec/requirements.md` 기준.

## 1. 전체 아키텍처와 데이터 흐름

```
ARView(RealityKit) ─ session ─► ARSessionManager (delegateQueue: scan.processing)   [Model]
                                     │ 스로틀(≥100ms) + 샘플링(stride 4, confidence≥medium)
                                     ▼
                          DepthFrameProcessor (unprojection, 순수 함수 — 단위 테스트)  [Model]
                                     ▼
                          OccupancyGrid (5cm cell, 고정 400×400, floor/wall hit)    [Model]
                                     ▼
                          MinimapRenderer (used-bounds crop → MinimapSnapshot)      [Model]
                                     ▼  onSnapshot / onEvent (Sendable, MainActor로 hop)
                          ScanViewModel (@Observable, MainActor)                    [ViewModel]
                                     ▼
                          ContentView · MinimapView · ARPreviewView                 [View]
```

모듈 책임과 파일 위치는 `docs/architecture/folder-structure.md`. 좌표계·동시성 규약은 `TECH_RULES.md`. 이 문서는 "왜 이렇게 했는가"만 다룬다.

### 1.1 아키텍처: MVVM 계층 폴더링

**결정.** 소스를 `App / Model / ViewModel / View` 네 폴더로 나누고, 의존 방향을 `View → ViewModel → Model` 단방향으로 고정한다. 배치 규칙은 `.codex/skills/mvvm-architecture/SKILL.md`.

**이유.**

1. **계층 경계가 곧 격리 경계다.** 이 앱의 핵심 제약은 동시성이다 — ARKit delegate는 `scan.processing` 직렬 큐에서 돌고, SwiftUI는 MainActor에서 돈다. MVVM의 세 계층이 이 두 실행 문맥에 그대로 대응한다: Model은 `nonisolated`로 큐 전용, ViewModel은 MainActor 상태 허브, View는 ViewModel만 읽는다. 폴더 이름만 보고도 "이 파일은 어느 스레드에서 도는가"를 알 수 있다. 격리 규칙을 폴더 규칙으로 바꾸면 기계 검사(`scripts/check-structure.sh`)가 가능해진다.
2. **SwiftUI + `@Observable`의 기본 형태다.** View는 상태의 함수이고, 상태를 소유·발행하는 객체가 하나 필요하다. `ScanViewModel`이 그 하나다. 별도 프레임워크나 boilerplate 없이 Observation만으로 성립한다.
3. **테스트 경계가 분명하다.** Model은 UI 프레임워크를 import하지 않는 순수 계층이라 시뮬레이터에서 단위 테스트할 수 있다 (`BenchMarkVideoTests/`, 16건). 실기기 없이는 런타임을 못 보는 이 프로젝트에서, 실기기 없이도 검증 가능한 영역을 폴더로 분리해 둔 것이다.
4. **LLM 협업에 유리하다.** 배치 규칙이 "파일이 어느 폴더에 있고 무엇을 import하면 안 되는가"라는 기계적 규칙이라 에이전트에게 강제할 수 있고, 위반이 커밋 전에 스크립트로 잡힌다. 기능 단위 폴더링(`Scan/`, `Minimap/`, `UI/`)은 어디까지가 UI이고 어디까지가 파이프라인인지 사람의 판단이 필요했다.
5. **프로젝트 규모에 맞는 무게다.** 단일 화면, 파일 9개다. 세 계층으로 충분하다.

**검토한 대안.**

| 대안 | 기각 이유 |
| --- | --- |
| 기능 단위 폴더링 (`Scan/`, `Minimap/`, `UI/`) — LLM 초안 | 읽는 사람이 계층 책임을 한눈에 읽기 어렵고, 큐 격리 경계가 폴더에 드러나지 않아 View가 Model을 직접 부르는 위반(`ARPreviewView → ARSessionManager.attach`)이 실제로 생겼다 |
| MV (ViewModel 없이 SwiftUI View + `@State`) | 큐 → MainActor hop, `ready/scanning/paused` 상태 머신, 이벤트 해석이 View 안으로 들어가 View가 두꺼워진다. 실기기 없이 검증할 수 있는 층이 사라진다 |
| Clean Architecture (UseCase / Repository / Interface) | 구현이 하나뿐인 인터페이스가 계층마다 생긴다. `TECH_RULES.md` 금지 항목(단일 구현 인터페이스)과 충돌 |
| TCA 등 외부 아키텍처 프레임워크 | 서드파티 의존성 추가. 핵심은 파이프라인이지 상태 관리 프레임워크가 아니다 |

**되돌리기 조건.** 화면이 셋 이상 생기고 화면 간 공유 상태가 필요해지면 feature 단위 상위 폴더(`Features/Scan/{Model,ViewModel,View}`)를 검토한다.

**검증 상태.** 컴파일·구조 검사·단위 테스트 28건 통과. 실기기 검증 완료 (2026-09-04~05, `README.md` 매트릭스).

### 1.2 UI 프레임워크: SwiftUI

**결정.** SwiftUI. 카메라 프리뷰만 `UIViewRepresentable`로 `ARView`를 감싼다.

**이유.** 화면이 하나이고 상태(스캔 상태, 스냅샷, 경고)가 곧 UI라 `@Observable` 발행 모델이 가장 짧다. Metal 뷰를 SwiftUI에 얹는 비용은 RealityKit `ARView`를 쓰면서 사라졌다 (2절).

## 2. 실시간 파이프라인 — 깊이 프레임 수신부터 미니맵 픽셀까지 (R1, R2-1)

| 단계 | 어디서 | 무엇을 | 버리는 것 |
| --- | --- | --- | --- |
| ① 프레임 수신 | `ARSessionManager.session(_:didUpdate:)`, `scan.processing` 큐 | `ARFrame` 도착 (기기 기본 60fps) | — |
| ② 스로틀 | 같은 콜백, 첫 줄 | `timestamp - lastProcessedTime < 0.1s`면 즉시 반환 | 약 6프레임 중 5프레임 |
| ③ 자세 추출 | 같은 콜백 | `camera.transform`에서 위치(x, z)와 heading | — |
| ④ 깊이 선택 | 같은 콜백 | `smoothedSceneDepth ?? sceneDepth` (누적 중일 때만) | 일시정지 중엔 ④~⑥ 생략, 궤적·마커만 갱신 |
| ⑤ 샘플링·역투영 | `DepthFrameProcessor.worldPoints` | stride 4로 픽셀 순회, confidence < medium 제외, depth 0.25~5m 밖 제외, 픽셀 → 카메라 좌표 → 월드 좌표. 같은 픽셀의 `capturedImage` 색(YCbCr → RGB)을 `ScanPoint.color`로 동봉 | 픽셀 15/16, 저신뢰·범위 밖 |
| ⑥ 높이 분류·누적 | `OccupancyGrid.accumulate` | 월드 y로 벽/바닥/천장 분류, (x, z) → 셀, `UInt16` hit 증가, 셀 색은 첫 hit 그대로·이후 EMA(3:1), used-bounds 갱신 | 천장, 20m 밖 |
| ⑦ 궤적 | `ARSessionManager` | 0.25m 이상 이동 시 위치 추가. 스캔을 한 번 시작한 뒤에는 일시정지 중에도 기록 | 미세 이동, 스캔 시작 전 이동, 트래킹 limited 중 이동 |
| ⑧ 렌더 | `MinimapRenderer.render` | used-bounds + 카메라를 포함하는 정사각 crop, 셀 → RGBA(벽 = 셀 색, 바닥 = 셀 색 ÷ 2, 미관측 = alpha 0), `CGImage` 생성 | 관측 영역 밖 셀 |
| ⑨ 전달 | `onSnapshot` → `ScanViewModel` | 불변 `MinimapSnapshot`을 `Task { @MainActor }`로 hop | — |
| ⑩ 표시 | `MinimapView` | 이미지 + `Canvas`로 궤적·마커·시야 부채꼴 오버레이. 오버레이 모드는 이미지를 scale·offset해 카메라를 중앙에 고정 (3.4절) | — |

②~⑧이 콜백 안에서 동기로 끝난다. `ARFrame`은 콜백 밖으로 나가지 않는다 — 프레임 풀 고갈 방지 (`TECH_RULES.md` 3절). 실시간 갱신(R2-1)은 이 구조 자체로 보장된다: 스캔 종료 후 일괄 처리하는 단계가 없다.

## 3. 좌표 변환 (R2-2, R2-5)

### 3.1 세 번의 변환

```
[깊이 픽셀 (u, v, d)]
   │ K⁻¹: (u−cx)/fx·d, (v−cy)/fy·d, d       — intrinsics를 depthMap 해상도로 스케일
   ▼
[카메라 좌표]  flipYZ: (x, −y, −z)            — 이미지 y-down·z-forward → ARKit y-up·−z-forward
   │ camera.transform (column-major, translation = columns.3)
   ▼
[월드 좌표 (x, y, z)]  y = 높이 (중력 반대)
   │ y로 벽/바닥/천장 분류, (x, z) / 0.05 반올림 + 200
   ▼
[격자 셀 (col, row)]   col ∝ x, row ∝ z
```

**intrinsics 스케일.** `ARCamera.intrinsics`는 capturedImage(1920×1440 등 landscape) 기준이고 depthMap은 256×192다. fx·cx는 가로 비율, fy·cy는 세로 비율로 각각 스케일한다 (`DepthFrameProcessor.UnprojectionParams`). 이걸 빼먹으면 점이 실제보다 약 7.5배 퍼진다.

**화면 회전.** depthMap을 버퍼 좌표 그대로 순회하고 `camera.transform`으로 월드에 놓으므로 portrait UI 회전은 월드 좌표에 영향이 없다. 회전 보정이 필요한 곳은 "화면에 그릴 때"뿐인데, 미니맵은 월드 xz 평면을 그리므로 여기도 없다. 흔한 함정인 "90도 돌아간 미니맵"은 depthMap 픽셀을 화면 좌표로 바꿔 쓸 때 생기는 문제이고, 이 파이프라인은 그 경로를 타지 않는다.

**heading.** 카메라 시선 = `transform`의 −z축. `atan2(look.x, −look.z)`로 0 = 월드 −z, 시계방향 양수. 미니맵이 north-up(−z가 위, +x가 오른쪽)이라 이 값이 그대로 마커 회전각이 된다.

### 3.2 검증

- 단위 테스트(`DepthFrameProcessorTests`): 주점 픽셀 → (0, 0, −d), 이미지 오른쪽 → +x, 이미지 아래 → −y, translation이 column 3에서 읽히는지, +x를 보는 자세의 heading = π/2, 실제 `CVPixelBuffer`에서 stride·confidence·범위 필터.
- 실기기: 알려진 길이 물체 실측으로 검증 완료 — 1.4m 책상 거리 측정 1.38/1.40m (±1.4%), 미니맵 셀 뭉치 폭 픽셀 측정 정합 (`README.md` 매트릭스 "스케일").

### 3.3 미니맵 회전 기준: 월드 고정 north-up (R2-5)

**결정.** 맵은 월드 xz 평면에 고정하고, 사용자 마커(삼각형 + 시야 부채꼴)만 heading에 따라 회전한다. 원점 = 스캔 시작 시 기기 위치. "북"은 ARKit 월드 −z, 즉 세션 시작 시 기기가 바라본 방향이다 (`ARWorldTrackingConfiguration` 기본 `worldAlignment = .gravity`).

**이유.** 사용자가 회전해도 지도가 흔들리지 않아 벽 윤곽을 누적 관찰하기 쉽다 — 이 프로젝트의 질문 "어디를 찍었고 어디가 비어 있는가"에는 고정 지도가 맞다. 렌더러가 회전 변환 없이 격자 배열을 그대로 비트맵으로 옮긴다.

**대안.** heading-up(진행 방향 고정) — 내비게이션에 익숙하지만 매 프레임 비트맵 회전이 필요하고, 정지 상태에서 yaw 노이즈로 지도가 떨린다. 시작 방향 고정 — `.gravity` 정렬에서는 north-up과 같다.

### 3.4 오버레이 창: 카메라 중심 고정, 좌하단 반경 2m (R2-3, R2-4)

**결정.** 좌하단 오버레이는 `MinimapView(visibleRadius: 2)` — 카메라가 항상 중앙에 오고 한 변이 4m인 근접 창. 배경은 정점 색 mesh를 직교 카메라로 수직 하향 촬영한 실시간 렌더(`MeshTopDownView`, 1.5초 주기 갱신)라 격자 비트맵보다 매끈하고, 마커·궤적 캔버스는 같은 카메라 중심·반경 매핑으로 정합된다. mesh가 생기기 전(스캔 극초반)에는 격자 이미지를 fallback으로 쓴다. 전체화면 2D도 같은 mesh top-down에 세계 창(중심 월드 좌표 + 반경, 핀치 0.5~20m·드래그) 팬·줌을 얹는다. 격자는 표시가 아니라 데이터·측정·내보내기의 정본으로 유지된다. 전체화면을 열면 스캔 중이었을 때 자동 일시정지하고 닫을 때 복귀한다(수동 일시정지는 존중) — 결과를 보는 동안 mesh가 재빌드되면 3D 카메라가 리셋되고 기하가 바뀌어 공간이 뒤틀려 보였다(실기기 재현). 3D는 진입 시점 mesh를 고정해 이를 구조적으로 차단한다.

**이유.** 실기기 1차 확인에서 auto-fit 오버레이는 맵이 커질수록 마커가 가장자리로 밀려 "내가 지금 어디인가"를 150pt 안에서 읽을 수 없었다 (`LLM_REPORT.md` 사례 8). 작은 창의 질문은 "내 주변 어디가 비었나"이고, 전체 구조는 전체화면이 답한다. 참고 영상의 오버레이도 마커가 중앙 부근에 고정돼 있다.

**미관측 셀은 alpha 0.** 이미지가 뷰보다 작을 때(관측 영역 < 8m) 이미지 안쪽과 바깥쪽이 다른 색이면 창 안에 어두운 사각형이 떠 있고 스캔할수록 커지는 것처럼 보인다. 미관측을 완전 투명으로 두면 View 배경(`Color.black.opacity(0.55)`) 하나만 보이고 관측 셀만 그 위에 얹힌다. 반경 밖 내용은 `clipShape`가 잘라낸다 — 걸어서 8m를 벗어난 영역은 격자에 남아 있어도 오버레이에는 안 보이고, 전체화면에서 보인다.

**대안.** 렌더러가 카메라 중심 crop을 따로 만들기 — 프레임마다 비트맵 두 장. View 변환이 공짜라 기각. 반경은 4m → 6m(실기기 1차) → 3m → 2m로 조정, 위치도 우상단 → 좌하단 — 사용자가 레퍼런스 앱을 제시하며 "게임 미니맵처럼 주변이 크게"와 시선·엄지 배치를 결정 (2026-09-05). 넓은 맥락은 전체화면 팬·줌이 담당한다 (`LLM_REPORT.md` 사례 8). 격자는 계속 누적하므로 창 밖 데이터는 버리지 않고 전체화면에서 보인다.

**되돌리기 조건.** mesh top-down 레이어(SCNView 상시 렌더)가 저사양 기기에서 부하가 되면 격자 이미지 표시로 되돌린다 — 두 경로 모두 유지돼 있다.

## 4. 스캔 시각화: RealityKit mesh (Metal 포인트클라우드 대신)

**결정.** 카메라 프리뷰 위 시각화는 `ARView` + `sceneReconstruction = .mesh` + `debugOptions.showSceneUnderstanding`으로 처리한다. 직접 렌더러는 없다.

**이유.** 요구사항의 무게중심은 미니맵이다. Apple의 Metal 포인트클라우드 샘플을 이식하면 셰이더·버퍼 관리 코드가 파이프라인 코드보다 커진다. RealityKit mesh는 설정 세 줄로 "어디를 스캔했는지"를 사용자에게 보여주고, 참고 영상의 초록 와이어프레임과 같은 형태다.

**대안.** Metal 포인트클라우드 렌더러 — 점 단위 시각화가 더 직관적이지만 코드량 대비 요구사항 기여도가 낮아 기각.

**켜는 시점 — 재구성과 표시를 분리.** 첫 구성은 mesh 없이 실행해 카메라 표시를 앞당기고, **첫 프레임이 도착한 직후**(카메라 패스스루가 이미 시작된 시점) `sceneReconstruction = .mesh`로 구성을 교체한다. 실기기에서 "스캔 시작 직후 카메라 위에 아무 변화 없는 2초"가 관찰됐는데, 구성 교체 후 첫 mesh 앵커 생성과 와이어프레임 셰이더 컴파일이 그 시점에 몰렸기 때문이다. 예열 시점을 트래킹 `normal`에 뒀다가 여전히 늦어(트래킹 수렴에 수 초) 첫 프레임으로 더 앞당겼다. 카메라가 이미 떠 있어 패스스루 지연은 생기지 않는다. 구성 교체는 reset 옵션 없이 하므로 트래킹은 유지된다.

그런데 예열을 앞당기자 스캔 시작 전에도 와이어프레임이 보였다. 재구성(`sceneReconstruction`, 세션 구성)과 표시(`debugOptions.showSceneUnderstanding`, ARView)는 별개이므로 재구성은 첫 프레임부터 돌리고, 표시는 `ARPreviewView(showMesh:)`로 스캔 상태에 묶는다 — **`scanning`에서만 표시**. 예열 효과 중 셰이더·트래킹 준비는 유지된다. 앵커는 첫 스캔 시작에서 resetSceneReconstruction으로 비운다 — 예열이 스캔 전에 쌓은 mesh가 시작 순간 화면을 덮으면 "체크무늬 = 스캔된 곳"이라는 사용자 멘탈 모델과 어긋나기 때문 (사용자 결정, 2026-09-05). 재생성 ~1초는 "주변 인식 중…" 배지가 커버하고, 초기화 후 시작과 같은 UX로 통일된다. 일시정지 중 재구성 확장분은 수용 — 재구성을 끄면 ARKit이 기존 mesh 앵커를 삭제해 재개 시 체크무늬가 통째로 사라지는 더 나쁜 UX가 된다. 미니맵(실제 기록)이 채워지지 않는 것으로 구분은 화면에 존재한다.

**일시정지에서도 숨기는 이유.** 일시정지의 의미는 "여기는 지도에 담지 않되 어디로 가는지는 계속 추적"이다 (궤적은 일시정지 중에도 기록). 그런데 재구성은 계속 돌므로 mesh를 켜두면 일시정지 중에도 와이어프레임이 새 영역으로 자란다 — pts 카운트는 멈췄는데 화면은 스캔 중처럼 보이는 상태 모순. 그래서 "mesh 보임 = 지금 기록 중"으로 문법을 통일한다. 표시는 `debugOptions` 토글이라 재개 시 즉시 다시 나타난다 (구성 교체·로딩 없음). 한계: 일시정지 중 걸어간 영역도 ARKit이 뒤에서 mesh를 만들어 두므로 재개 시 그 영역 와이어프레임이 함께 보인다. mesh는 시각화 보조고 데이터 정본은 미니맵이라 허용한다 (부분 삭제는 ARKit 미지원).

**초기화 후.** 초기화는 `resetSceneReconstruction`으로 mesh를 전부 지우므로 다음 스캔 시작 때 ARKit이 첫 앵커를 다시 만들 때까지 약 1초가 걸린다. 이건 "초기화 = 스캔 결과를 지운다"는 의미에서 오는 지연이라 남겨 둔다. 대신 초기화 세션은 mesh를 켠 채 바로 재시작해 구성 교체를 한 번으로 줄인다 (처음 실행 때만 mesh 없이 시작한다 — 카메라 표시가 우선인 구간은 그때뿐이다).

남는 공백에는 이름을 붙인다 — 스캔 중인데 첫 mesh 앵커가 아직 없으면 "주변 인식 중…" 배지를 띄우고, `session(_:didAdd:)`에서 첫 `ARMeshAnchor` 도착(`ScanEvent.meshReady`)에 해제한다. 고정 타이머가 아니라 실제 신호로 끝나므로 환경이 느려도 거짓말하지 않는다. 전면 로딩이 아닌 상태 배지인 이유: 카메라·미니맵은 이미 살아 있어 막을 이유가 없고, mesh가 점점 그려지는 것 자체가 진행 표시다.

**되돌리기 조건.** 요구사항이 "포인트클라우드 시각화"를 명시하거나, mesh가 지원되지 않는 기기를 지원해야 할 때.

## 5. 누적 자료구조: 고정 400×400 occupancy grid, 셀 5cm

**결정.** `OccupancyGrid.cellSize = 0.05`, `dimension = 400` (20m × 20m). 셀마다 `wallHits`·`floorHits` `UInt16` 카운트(640KB)와 카메라 색 `SIMD3<UInt8>`(480KB). 메모리 상한 약 1.1MB.

**이유.** 점을 무한 누적하면 메모리가 스캔 시간에 비례해 커져 3분 연속 스캔(R3-2)을 보장할 수 없다. 카운트 격자는 상한이 고정되고 노이즈 컷(`wallHitThreshold = 3`, `floorHitThreshold = 2`)이 자연스럽다. 5cm는 실내 벽 윤곽 구분에 충분하고 depth 노이즈보다 크다. 400셀은 사무실 한 층 복도 정도(20m)를 덮는다.

**대안.** 동적 확장 / chunk 격자 — 대공간 대응이 되지만 요구사항 범위(실내 한 공간)에는 과하다. 코드에 `ponytail:` 주석으로 확장 경로를 남겼다.

**되돌리기 조건.** 실기기에서 20m 초과 공간을 스캔해야 하거나, 5cm에서 벽이 두 셀 이상으로 번져 윤곽이 뭉개지면 셀 크기를 조정한다.

**검증 상태.** `cellIndex`·`accumulate`·bounds는 단위 테스트로 고정. 실제 스케일은 실기기 실측(1.4m 책상 ±1.4%)으로 검증 완료.

## 6. 바닥·천장 필터: 높이 밴드 슬라이스

**결정.** 월드 y 기준으로 `wallBand = -0.9...0.7`은 벽·가구, `y < floorBelow (-0.9)`는 바닥, 그 위는 천장으로 버린다. 원점 y = 스캔 시작 시 기기 높이(바닥 위 약 1.2~1.5m 가정) → 밴드는 바닥 위 약 0.3~2.2m.

**이유.** 구현이 비교 두 번이고 프레임당 비용이 없다. 바닥 점을 벽 채널에서 분리하지 않으면 바닥 전체가 벽처럼 칠해진다. 바닥은 버리지 않고 별도 채널로 누적해 "관측한 영역"을 어둡게 표시한다 — 벽 윤곽과 커버리지를 동시에 보여주기 위해서다.

**대안.**

| 대안 | 판정 |
| --- | --- |
| `ARPlaneAnchor`로 바닥 평면 추정 후 밴드 기준을 잡음 | 시작 높이 가정을 없애지만 평면 검출 지연과 앵커 갱신 처리가 추가된다. 되돌리기 1순위 |
| 셀별 높이 분산 (수직으로 퍼지면 벽) | 셀마다 min/max y 저장이 필요해 메모리 2배, 가구 상판이 벽으로 분류됨 |

**되돌리기 조건.** 실기기에서 시작 높이 가정이 자주 깨지거나(앉아서 시작, 테이블 위에서 시작), 드리프트로 밴드가 어긋나면 ARPlaneAnchor 방식으로 교체한다. 코드에 `ponytail:` 주석으로 표시.

**검증 상태.** 분기 로직은 단위 테스트로 고정. 밴드 값 실기기 검증 완료 — 바닥 방향 스캔 시 벽 셀 미생성(cells 불변), 천장 폐기 실증. 한계도 실측 확인: 앉은 시작(약 0.6m) 시 바닥이 벽 취급 (스캔 시작 높이 재기준으로 실행-스캔 높이 차는 해소, 시작 자세 가정은 유지).

## 7. 샘플링과 스로틀

| 파라미터 | 값 | 이유 |
| --- | --- | --- |
| `ARSessionManager.processInterval` | 0.1s | 60fps 중 약 10fps만 그리드에 반영. 콜백 동기 처리 <10ms 목표 유지. 미니맵은 10Hz면 "지연 없이" 보인다 |
| `DepthFrameProcessor.pixelStride` | 4 | 256×192에서 최대 3,072점/프레임. 5cm 셀에 충분한 밀도 |
| confidence 하한 | `ARConfidenceLevel.medium` | low 신뢰 픽셀은 가장자리·반사면 노이즈 |
| `DepthFrameProcessor.depthRange` | 0.25...5.0m | 근접 노이즈와 원거리 저신뢰 값 제외 |
| `ARSessionManager.trajectoryStep` | 0.25m | 궤적 점 수 억제 |
| `MinimapRenderer.margin` | 10셀 | crop 가장자리 여백 |

CPU 처리다. 프레임당 3천 점 × 10Hz = 초당 3만 점 역투영은 CPU 한 코어로 충분하고, Metal compute로 옮기면 GPU→CPU 격자 동기화 비용이 생긴다. GPU 이관은 측정값이 목표를 넘을 때만 검토한다 (10절).

**되돌리기 조건.** 실기기에서 미니맵이 듬성하면 stride를 줄이고, 프레임 드롭이 보이면 interval을 늘린다. 값 변경 시 이 표를 갱신한다.

## 8. 스레딩·동시성

**결정.** `ARSession.delegateQueue = DispatchQueue(label: "scan.processing")`. 그리드·궤적·누적 플래그는 이 큐에서만 접근한다. UI로는 불변 `MinimapSnapshot`만 넘긴다. ViewModel → Model 제어(`startAccumulating` 등)는 큐로 `async` hop한다.

| 작업 | 실행 문맥 |
| --- | --- |
| ARKit delegate 콜백, 역투영, 격자 누적, 비트맵 생성 | `scan.processing` 직렬 큐 |
| `ScanViewModel` 상태 갱신, SwiftUI 렌더 | MainActor |
| RealityKit mesh 렌더 | RealityKit 내부 (관여 없음) |

**이유.** 메인 스레드에서 unprojection과 비트맵 생성을 하면 SwiftUI 렌더가 막힌다(R3-1). 직렬 큐 하나면 락 없이 상태를 보호할 수 있다. 빌드 설정 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 아래에서 Model만 `nonisolated`로 빼 컴파일러가 경계를 검사한다.

**대안.** actor로 감싸기 — `ARSessionDelegate`가 동기 콜백이라 actor hop이 프레임마다 필요해 오히려 복잡하다. `@unchecked Sendable`은 "큐 전용 접근" 규약을 전제로만 안전하며 그 규약은 `TECH_RULES.md`가 소유한다.

## 9. ARSession 소유권: ARView가 소유, 매니저는 attach

**결정.** `ARView.session`은 get-only이므로 세션은 ARView가 만들고, `ScanViewModel.attach(session:)` → `ARSessionManager.attach(to:)`로 delegate만 연결한다.

**이유.** LLM 초안(매니저가 세션 생성·주입)은 API 제약으로 성립하지 않았다 (`LLM_REPORT.md` 사례 1). View → ViewModel → Model 경로를 유지하기 위해 ViewModel이 attach를 중계한다.

## 10. 성능 예산과 측정 (R3)

**목표.** UI 30fps 이상(R3-1), 내부 목표는 기기 기본 60fps 유지. delegate 콜백 동기 처리 <10ms. 3분 이상 연속 스캔에서 메모리 증가 없음 (격자 고정, 궤적만 선형).

**설계상 비용 통제.**

| 장치 | 효과 |
| --- | --- |
| 100ms 스로틀 | 깊이 처리를 초당 약 10회로 제한. 나머지 프레임은 즉시 반환 |
| stride 4 샘플링 | 프레임당 최대 3,072점. 역투영 비용 상한 |
| 고정 격자 hit count | 점 누적 대신 셀 카운트 — 메모리가 시간에 비례하지 않음 |
| used-bounds crop | 비트맵 생성이 관측 영역 크기에만 비례 |
| 불변 스냅샷 전달 | UI 갱신이 파이프라인을 막지 않음 |
| mesh 재빌드 스킵 | 입력 서명(앵커 수+누적 점) 미변경·스캔 전이면 1.5초 주기 빌드 생략 — 일시정지·정지 중 부하 0 |
| 렌더 이미지 재사용 | 격자·crop 미변경 시 CGImage 재생성·텍스처 재업로드 생략 |
| 궤적 상한 2,048점 | 도달 시 절반 데시메이션 + 간격 배가 — 메모리·스냅샷 복사 고정 |

**측정 방법 (실기기 iPhone 15 Pro).**

1. `ARSessionManager.session(_:didUpdate:)` 진입·종료에 `os_signpost` 구간을 두고 Instruments Points of Interest로 콜백 처리 시간 분포를 본다. 측정 코드는 `#if DEBUG`.
2. Instruments Allocations로 3분 이상 스캔 중 메모리 곡선과 피크를 본다.
3. Xcode Debug Navigator FPS 게이지로 평균·최저 FPS를 읽는다.
4. 프레임당 처리 포인트 수는 `worldPoints` 반환 배열 길이를 DEBUG 로그로 남긴다.

**결과.** 2026-09-04, iPhone 15 Pro · iOS 26.6, **Development(Debug) 빌드** 3분 연속 스캔, 자가 계측 로그(처리 프레임 1,560개) 판독. Instruments는 CLI 설치 빌드 attach 거부로 미사용 — 앱이 3초마다 지표를 unified log로 남기는 방식으로 대체.

| 항목 | 목표 | 측정값 | 기기·iOS·일자 |
| --- | --- | --- | --- |
| 평균 / 최저 FPS | ≥30 (기기 기본 유지) | 60.0 / 59.9 — **최악 부하(baseline 전수 처리)에서 측정**. tuned는 부하 1/9이라 동일 이상 | iPhone 15 Pro · 26.6 · 2026-09-04 |
| 콜백 처리 시간 p50 / p95 | <10ms | 누적 p50 11.9ms / p95 17.5ms / max 22.2ms — **목표 초과, 해석 아래** | iPhone 15 Pro · 26.6 · 2026-09-04 |
| 피크 메모리 | 격자 1.1MB + 앱 기본 | footprint 441 → 770MB 선형 증가 후 723MB — 증가분은 격자가 아니라 ARKit mesh 앵커·RealityKit (아래) | 〃 |
| 프레임당 처리 포인트 수 | ≤3,072 | 970~3,072 — 상한 정확히 준수 | 〃 |
| 연속 스캔 시간 | ≥3분, 강제 종료 없음 | 3분+ 생존, 메모리 경고 없음 | 〃 |

**해석 (측정 후 추가).**

- 콜백 시간은 시간에 따라 상승한다 — 초반 3초 p50 0.31ms → 말미 누적 11.9ms. 격자 누적이 아니라 `MinimapRenderer` 비트맵 생성이 관측 영역 면적에 비례해 커지는 것이 원인. Debug(-Onone) 수치라 Release는 이보다 낮고, 콜백은 전용 직렬 큐에서 돌아 UI 프레임을 직접 막지 않는다 (10Hz × 12ms ≈ 큐 점유 12%). 목표 <10ms는 Debug 기준 미달 — Release 재측정 전에는 7절 파라미터를 조정하지 않는다 (계측이 `#if DEBUG` 전용이라 Release 측정은 계측 플래그 분리가 선행 조건).
- "메모리 증가 없음" 가정은 앱 격자에만 성립한다. `sceneReconstruction` mesh 앵커는 스캔 면적에 비례해 ARKit이 계속 쌓는다 — 3분 방 스캔에 약 +330MB. 초기화(`resetSceneReconstruction`)가 회수 수단이다.
- 3분 시점 ARKit이 "resource constraints" 경고와 함께 depth integration을 건너뛰는 구간이 관측됐다 (Debug + 계측 부하 조건). Production 기준 재현 여부는 미확인.

**재측정 (2026-09-05, 최종 빌드 — 뷰어·mesh 미니맵·복셀 색 포함).** 기능 확장 후 같은 방법(자가 계측, Debug, 약 4.5분·일시정지 40초 포함)으로 재검증:

| 항목 | 1차 측정 (09-04) | 재측정 (09-05 최종) | 해석 |
| --- | --- | --- | --- |
| 콜백 p50 / p95 | 누적 11.9 / 17.5ms | **창(3s) 단위 12~14 / 13~16ms** (피크 16.7/20.3, max 20.8) | 복셀 색 누적이 추가됐는데 +1ms 수준. 창 단위 통계로 바꾸니 시간 경과 저하 없음 — 1차의 "누적 상승"은 초반 샘플 지배 왜곡이었음 |
| points/frame | 970~3,072 | 1,931~3,072 | 상한 준수 유지 |
| 메모리 | 3분 441→770MB | **4.5분 445→570MB** | 재빌드 스킵·이미지 재사용으로 증가율 완화. 일시정지 40초 구간 처리 로그 침묵 + 메모리 평탄 — 스킵 실증 |
| UI fps | 60.0/59.9 | **60.0/59.9 상시** (SCNView 미니맵 상시 렌더 포함) | 전체화면 열닫·3D 진입 순간만 일시 하락(min 7~16) — 전환 프레임, 지속 아님 |

**전후 비교 (선택 "성능 최적화 근거").** 같은 공간에서 `perf-baseline` 브랜치(stride 1 · 스로틀 0, 전수 처리)로 재측정 (2026-09-04, Debug):

| 항목 | tuned (stride 4 · 100ms) | baseline (stride 1 · 0ms) |
| --- | --- | --- |
| points/frame | ≤ 3,072 | 36,755~49,152 (전수, 16배) |
| 콜백 p50 / p95 / max | 11.9 / 17.5 / 22.2ms | 107.7 / 126.6 / 137.5ms (약 7~9배) |
| 처리 큐 | 점유 약 12% (10Hz) | 포화 — 처리율 약 9fps, ARKit "delegate retaining 11~13 ARFrames" 경고 연속 (카메라 공급 중단 직전) |
| UI fps | 60 (동일 경로, 부하 더 낮음) | 60.0 / 최저 59.9 |

두 발견: (1) **UI 60fps는 최악 부하에서도 유지** — 전용 직렬 큐 + 불변 스냅샷의 UI 격리가 실증됨. (2) 스로틀·stride가 없으면 처리 큐가 포화되고 ARFrame 적체로 카메라 공급 중단 직전까지 감 — 100ms 스로틀과 stride 4가 정확히 이를 막는다. baseline 브랜치는 측정 재현용으로 보존, main에 머지하지 않는다.

## 11. 참고 영상 대비 차이

| 관찰 포인트 | 참고 영상 | 이 구현 | 이유 |
| --- | --- | --- | --- |
| 카메라 위 스캔 표시 | 초록 mesh 와이어프레임 | 같음 (RealityKit `showSceneUnderstanding`) | 4절 |
| 미니맵 내용 | 텍스처가 입혀진 top-down mesh | 같음 — 정점 색 mesh의 직교 하향 실시간 렌더 (`MeshTopDownView`) | 단색 격자 → 셀 색 격자 → mesh top-down으로 3단 진화 — 도트 질감 한계를 표시층 교체로 해소, 텍스처 대신 정점 색 근사 (`LLM_REPORT.md` 사례 8·18) |
| 미니맵 위치 | 좌하단, 마커 중앙 고정 | 같음 — 좌하단, 마커 중앙 고정(반경 2m), 탭으로 전체화면 | 처음엔 우상단이었으나 레이아웃 재설계로 동일 문법 채택 — 정보 상단 중앙·버튼 우하단 |
| 위치 마커 | 파란 점 + 시야 | 노란 삼각형 + 시야 부채꼴 + 궤적 | 방향을 점보다 명확히. 궤적은 커버리지 판단 보조 |
| 스캔 종료 후 | 처리 대기 → 2D/3D 결과·측정 | 같음 — 전체화면 2D/3D 통합 뷰어(팬·줌·회전·거리 측정·.ply 내보내기), 처리 대기 없이 즉시 | 텍스처 베이킹 단계가 없어 대기가 불필요 — 정점 색 근사의 이점 |

## 12. 알려진 한계와 드리프트

- **드리프트.** 오래 스캔하면 VIO 추정이 누적 오차를 갖고 같은 벽이 두 겹으로 그려질 수 있다. 현재 보정하지 않는다. hit threshold(벽 3, 바닥 2)가 얇은 노이즈는 걸러 주지만 드리프트로 어긋난 두 번째 벽은 그대로 남는다.
- **중단 후 재로컬라이즈.** `sessionShouldAttemptRelocalization`을 `true`로 두어 백그라운드 복귀 등 중단 뒤 ARKit이 기존 월드 원점으로 되돌아오게 한다. 이렇게 하지 않으면 트래킹이 새로 시작돼 원점이 바뀌고, 그때까지의 격자가 통째로 어긋난다. 재로컬라이즈 중(`limited(.relocalizing)`)에는 누적·궤적을 멈추고 배지를 띄우며, 끝나지 않으면 사용자가 초기화로 탈출한다. **정합 보정 시도**: 복귀(`normal` 전이) 후에도 1초간 누적·궤적을 계속 보류한다 (`relocalizationSettleTime`) — 복귀 직후는 ARKit이 월드·앵커를 미세 조정하며 수렴하는 구간이라, 그 포즈로 찍은 점이 격자에 굳으면 기존 관측과 어긋난다(실측 #21 복귀 시퀀스 약 4초의 마지막 정렬 단계). 수렴이 끝난 뒤 격자를 옮기는 보정은 하지 않는다 — 실측상 잔여 오차가 셀 해상도 이하다.
- **시작 높이 가정.** 6절 밴드는 시작 시 기기 높이에 의존한다.
- **20m 상한.** 5절. 밖의 점은 버린다.
- **트래킹 불량 시 누적.** `limited`인 동안 누적·궤적 기록을 중단한다(normal 게이트, `adff017`). 남는 한계: 극단적으로 흔들면 ARKit이 normal을 유지한 채 포즈가 오염돼 유령 셀이 생길 수 있다 — 실사용 조건 미발생으로 후속 없음, 초기화로 복구.

## 13. 스캔 결과 뷰어: 정점 색 mesh·복셀 색·측정 (선택 항목 설계)

**결정.** 3D 뷰어와 미니맵 배경은 하나의 데이터로 통일한다 — ARKit `ARMeshAnchor` 기하에 카메라 색을 정점 단위로 입힌 **ColoredMesh** (`Model/MeshBuilder.swift`). 색은 깊이 점 스트림에서 **월드 복셀**(`VoxelColorStore`, 5/15/40cm 3단 fallback)에 EMA(3:1)로 누적해 두고 뷰어 생성 시 정점 위치로 조회한다 — mesh 정점은 앵커 갱신으로 계속 바뀌므로 정점이 아닌 공간에 색을 저장해야 한다.

**이유.** 참고 영상의 미니맵·3D는 텍스처 mesh 렌더다. 진짜 텍스처 베이킹(키프레임 이미지 저장 → 삼각형별 최적 프레임 선택 → UV 아틀라스)은 메모리·이음새·베이킹 시간 문제로 이 프로젝트 범위를 넘어, 이미 있는 두 재료(mesh 기하 + 색 샘플링 파이프라인)를 합친 정점 색 근사를 채택했다. 렌더는 SceneKit — 점/삼각형 지오메트리에 `allowsCameraControl`로 회전·줌이 공짜고, 같은 mesh를 직교 카메라로 수직 하향 촬영하면 미니맵 배경(`MeshTopDownView`)이 된다. 렌더러 하나로 두 화면.

**구현 요점.**
- ARKit 정점 버퍼는 packed float3(12바이트) — SIMD3 직접 로드(16바이트 정렬) 금지, Float 3개로 읽는다.
- **돌하우스**: ARKit mesh 면은 관측한 쪽(방 안)을 향한다. 뒷면 컬링(`isDoubleSided = false`) 한 줄로 카메라를 등진 벽·천장이 투명해져 밖에서도 내부가 보인다. 천장 스캔 후 닫힌 상자가 되는 문제와 top-down 미니맵이 천장에 덮이는 문제를 함께 해결.
- **갱신 규율**: 빌드는 1.5초 주기 + 입력 서명(앵커 수 + 누적 점) 미변경 시 스킵, 스캔 시작·재개 시 1회 즉시. 뷰는 빌드 version으로만 재구성 — 보는 중 장면 교체가 카메라를 리셋해 "공간 뒤틀림"이 되므로 3D는 진입 시점 mesh를 고정하고, 전체화면 자체가 자동 일시정지다 (3.4절).

**측정 설계.** 시맨틱은 수평(xz) 거리 — 2D 격자 측정과 동일하고, `measurePoints`를 2D/3D가 공유해 어느 쪽에서 찍어도 양쪽에 표시된다. 3D 탭은 mesh 표면 히트 우선(가구 모서리를 직접 잡음, 마커는 표면 높이에 부착), 빈 공간은 바닥 평면 투영 fallback. 바닥 높이는 **밀도 기반 추정**(`MeshBuilder.estimatedFloorY`) — y 히스토그램(10cm)에서 아래부터 임계 밀도 이상인 첫 버킷. 단순 최저값은 유리 반사 허상 정점에 끌려 평면이 지하로 꺼져 오측정을 냈다(실기기 재현 → 단위 테스트로 고정).

**한계.** 정점 색 보간이라 면 텍스처 대비 흐릿하고, 색 미관측 정점은 회색이다(스캔 진행으로 자연 해소). 높이 방향 측정은 시맨틱 분기를 피해 미지원. 진짜 텍스처 베이킹 경로는 14절 7번.

**되돌리기 조건.** 저사양 기기에서 SCNView 부하가 문제 되면 미니맵은 격자 이미지 표시로 복귀 가능 — 두 경로 모두 유지돼 있다 (3.4절).

## 14. 시간이 더 있었다면

1. ~~실기기 튜닝 루프~~ — 완료 (2026-09-04): 영상 판독 검증 46항목, 10절 표·전후 비교 기입.
2. **`ARPlaneAnchor` 바닥 추정** — 시작 높이 가정 제거 (6절 되돌리기). 실측상 앉은 시작 시 의미 구분 소실이나 형태 가독성은 유지 — 우선순위 유지.
3. ~~트래킹 `limited` 중 누적 중단~~ — 완료 (`adff017`), 12절.
4. ~~드리프트 대응~~ — 시도 구현 (12절 재로컬라이즈 안정화 창). 격자 이동 보정은 실측상 방 규모 드리프트가 셀 이하라 불요 판정.
5. ~~미니맵 팬·줌~~ — 완료: 전체화면 세계 창(중심+반경) 방식.
6. ~~스캔 결과 내보내기~~ — 완료: 관측 셀 .ply + ShareLink (`GridExporter`).
7. **키프레임 텍스처 베이킹** — 현재 3D는 정점 색 근사. 참고 영상 수준의 면 단위 사진 텍스처는 스캔 중 키프레임(이미지+포즈) 저장 → 삼각형별 최적 프레임 선택 → UV 아틀라스 베이킹이 필요하다. 공개 참고 코드: TokyoYoshida/ExampleOfiOSLiDAR (MIT, 단일 프레임 투영).
