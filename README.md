# Threei_Assignment — 실시간 공간 스캔 & Top-Down Minimap

iPhone의 LiDAR 깊이(`sceneDepth`)를 실시간으로 받아 카메라 화면 위에 스캔 영역을 표시하고, 동시에 위에서 내려다본 2D 미니맵(occupancy grid)을 그린다. 순수 Swift, SwiftUI + ARKit + RealityKit, 서드파티 의존성 없음.

| 항목 | 값 |
| --- | --- |
| 개발 환경 | Xcode 26.1, Swift 6 언어 모드, iOS 17.0 이상 (명세 권장 iOS 16 → 17로 상향: `@Observable`이 iOS 17부터) |
| 테스트 기기 | iPhone 15 Pro (iPhone16,1, LiDAR), iOS 26.6 — 2026-09-04 실기기 검증 완료 (화면 녹화 22편 프레임 판독) |
| 아키텍처 | MVVM (`App / Model / ViewModel / View`) — 근거 `DESIGN.md` 1.1절 |
| 산출 문서 | 설계 `DESIGN.md` · LLM 활용 리포트 `LLM_REPORT.md` · 이 README |
| 에이전트 문서 | 작업 규범 `AGENTS.md` · 체계 설명 `docs/AI_AGENT_HARNESS.md` |

## 데모 영상

실기기 검증 후 링크 추가 예정 (3분 이내, 스캔 시작 → 이동하며 미니맵 채워짐 → 종료).

## 실행 방법

```bash
git clone <repo>
cd Threei_Assignment
open Threei_Assignment.xcodeproj
```

1. Xcode에서 scheme을 선택한다 (공유 scheme 2개, 저장소에 포함).
   - `Threei_Assignment-Production` — 실사용·성능 확인용. Release, 디버거 미부착, GPU Frame Capture Disabled, Metal API Validation off. 카메라 표시까지의 시간이 실사용 기준이다.
   - `Threei_Assignment-Development` — 개발·디버깅용. Debug + LLDB. 디버거와 Metal 검증 레이어 때문에 첫 실행·셰이더 컴파일이 수 배 느린 것이 정상이다.
2. Signing & Capabilities에서 본인 팀을 지정한다 (bundle ID `io.tenkm.doran.lidarscan`, 필요하면 변경).
3. LiDAR 기기(iPhone 12 Pro 이상 Pro 계열 / iPad Pro 2020 이상)를 연결하고 Run.
4. 첫 실행 시 카메라 권한을 허용한다. 화면 하단 "스캔 시작"을 누르면 우상단 미니맵이 채워진다.

시뮬레이터에서는 `sceneDepth`가 nil이라 "지원되지 않는 기기" 화면이 뜬다. 단위 테스트만 시뮬레이터에서 돈다.

## 구현 체크리스트

요구사항 번호는 `docs/spec/requirements.md` 기준. 상태: ✅ 구현·검증 / 🔶 구현, 실기기 미검증 / ❌ 미구현.

### R1. 실시간 공간 스캔

| 항목 | 상태 | 구현 |
| --- | --- | --- |
| R1-1 실시간 스캔, 화면 반영 | ✅ | RealityKit `sceneReconstruction` mesh 와이어프레임 (`View/ARPreviewView.swift`). 재구성은 첫 프레임부터 예열, 표시는 스캔 중에만("mesh 보임 = 기록 중"). mesh 준비 전엔 "주변 인식 중…" 배지 |
| R1-2 시작 / 일시정지 / 재개 / 초기화 | ✅ | `ViewModel/ScanViewModel.swift`. 일시정지는 세션 유지·격자 누적만 중단(궤적·마커는 계속, mesh 표시는 숨김), 초기화는 격자·궤적·트래킹 리셋 |
| R1-3 상태 피드백 | ✅ | 상태 배지(대기/스캔 중/일시정지), 누적 포인트 수, 관측 셀 수, 트래킹 경고, mesh 준비 배지 |
| R1-4 트래킹 실패 처리 | ✅ | `cameraDidChangeTrackingState` 5종 메시지, 세션 중단 배지, 세션 실패 안내 화면. 앱은 계속 동작 |

### R2. Top-Down 실시간 Minimap

| 항목 | 상태 | 구현 |
| --- | --- | --- |
| R2-1 실시간 갱신 | ✅ | 콜백마다 격자 누적 → 스냅샷 발행 (약 10Hz). 사후 일괄 처리 단계 없음 |
| R2-2 Top-down 투영 | ✅ | 월드 xz 평면, 5cm 셀 400×400 occupancy grid + 셀별 카메라 색 (`Model/OccupancyGrid.swift`). 벽은 원색, 바닥은 절반 밝기, 미관측은 투명. 스케일 실측: 1.4m 책상 정합 |
| R2-3 현재 위치·방향 | ✅ | 삼각형 마커 + 시야 부채꼴 (`View/MinimapView.swift`), heading은 단위 테스트로 고정, 실기기 회전·이동 정합 확인 |
| R2-4 오버레이 배치·전체화면 | ✅ | 우상단 150pt 오버레이 — 카메라를 항상 중앙에 두고 반경 6m만 표시(창이 따라 미끄러짐). 탭하면 전체화면(관측 영역 전체), 배경 탭·닫기로 복귀 |
| R2-5 좌표계 기준 명시 | ✅ | 월드 고정 north-up. 이유는 `DESIGN.md` 3.3절 |
| 선택: auto-fit | ✅ | 전체화면에서 관측 영역 + 카메라를 포함하는 정사각 crop (`Model/MinimapRenderer.swift`). 오버레이는 카메라 중심 고정 창 (`DESIGN.md` 3.4절) |
| 선택: 이동 궤적 | ✅ | 0.25m 간격 궤적선 — 일시정지 중에도 기록, 트래킹 normal일 때만 |
| 선택: 팬 / 줌 / 회전 | ❌ | 전체화면 전환만. `DESIGN.md` 13절 |
| 선택: 거리·면적 측정 | ✅ | 전체화면 두 점 탭 → 거리(m) + 관측 면적(m²). 실기기 검증: 1.4m 책상 측정 1.38/1.40m (±1.4%) |

### R3. 실시간 성능

| 항목 | 상태 | 구현 |
| --- | --- | --- |
| R3-1 UI 30fps 이상 | ✅ | 실측 60.0fps (최저 59.9) — 전수 처리(baseline) 최악 부하에서도 60fps 유지. 깊이 처리를 전용 직렬 큐로 격리한 구조 덕 |
| R3-2 3분 이상 연속 스캔 | ✅ | 실측: 3분+ 생존, 강제 종료·메모리 경고 없음. 앱 격자는 고정(약 1.1MB)이나 ARKit mesh 앵커는 스캔 면적에 비례해 증가 (3분 방 스캔 footprint 441 → 770MB) |
| R3-3 직접 측정한 수치 | ✅ | Debug 빌드 자가 계측 — 콜백 p50 11.9ms / p95 17.5ms, points/frame ≤ 3,072 준수. 표와 해석은 `DESIGN.md` 10절 |

### R4. UI/UX

| 항목 | 상태 | 구현 |
| --- | --- | --- |
| R4-1 설명 없이 사용 가능 | ✅ | 화면에 버튼 하나("스캔 시작") + 미니맵. 상태별로 버튼이 바뀜 |
| R4-2 권한·미지원·트래킹 안내 | ✅ | 권한 거부 → 안내 + 설정 열기(재설치 흐름으로 실기기 확인), 미지원 기기 → 안내 화면, 트래킹 불량 → 경고 배지 |
| R4-3 조작 흐름 | ✅ | 시작 → (일시정지 ↔ 재개) → 초기화 단일 흐름 |

### 선택 요구사항 (가산점)

| 항목 | 상태 |
| --- | --- |
| 테스트 코드 (+2) | ✅ `Threei_AssignmentTests/` 16건 — 좌표 변환·버퍼 필터·색 샘플링·격자 누적·색 EMA·crop |
| auto-fit, 이동 궤적 | 🔶 위 R2 표 |
| 성능 최적화 전후 비교 (+2) | ✅ stride 1·스로틀 0 baseline 대비 콜백 약 9배·points 16배 절감, 큐 포화 방지 실증 — `DESIGN.md` 10절 |
| 거리·면적 측정 (+2) | ✅ 실기기 검증 — 1.4m 책상 측정 1.38/1.40m (±1.4%), 면적 라벨 스캔 연동 |
| 스캔 결과 내보내기 (+2) | ✅ 실기기 검증 — 공유 시트(iOS가 3D 항목 인식)·AirDrop 전송, .ply 검판(vertex 정합·격자 정렬·색) |
| 3D 재구성 뷰어, 면적 측정, 드리프트 보정 | ❌ (드리프트는 실측상 보정 불요 — 방 규모에서 셀 이하) |

## 아키텍처

```
ARView(RealityKit) ─ session ─► ARSessionManager (delegateQueue: scan.processing)   [Model]
                                     │ 스로틀(≥100ms) + 샘플링(stride 4, confidence≥medium)
                                     ▼
                          DepthFrameProcessor (unprojection, 순수 함수 — 단위 테스트)  [Model]
                                     ▼
                          OccupancyGrid (5cm cell, 고정 400×400, floor/wall hit)    [Model]
                                     ▼
                          MinimapRenderer (used-bounds crop → MinimapSnapshot)      [Model]
                                     ▼  onSnapshot / onEvent (Sendable)
                          ScanViewModel (@Observable, MainActor)                    [ViewModel]
                                     ▼
                          ContentView · MinimapView · ARPreviewView                 [View]
```

Model은 `scan.processing` 직렬 큐에서만 돌고, ViewModel은 MainActor다. 계층 경계가 곧 스레드 경계라서 MVVM을 택했다 — 파이프라인 전 과정, 좌표 변환, 바닥·천장 필터, 격자 해상도 근거, 스레딩, 성능은 `DESIGN.md`. 좌표계·동시성 규약은 `TECH_RULES.md`. 파일 배치는 `docs/architecture/folder-structure.md`.

## 사용한 라이브러리·오픈소스

- 서드파티 라이브러리 없음. Apple 시스템 프레임워크만 사용: ARKit, RealityKit, SwiftUI, Observation, CoreGraphics, simd, XCTest.
- 참고한 코드: Apple 샘플 [Visualizing a Point Cloud Using Scene Depth](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth)의 역투영 방식(intrinsics 역행렬 + y·z 부호 반전). 코드를 복사하지 않고 `Model/DepthFrameProcessor.swift`에 CPU 버전으로 다시 작성했다. Metal 렌더러는 가져오지 않았다 (`DESIGN.md` 4절). 라이선스: Apple Sample Code License (개념 참고 범위).

## 성능 측정 결과 (R3)

2026-09-04, iPhone 15 Pro · iOS 26.6, Development(Debug) 빌드 3분 연속 스캔, 자가 계측 로그 판독 (`DESIGN.md` 10절에 전체 표·해석):

- 콜백 처리: 누적 p50 11.9ms / p95 17.5ms / max 22.2ms — 목표 <10ms는 Debug 기준 미달. 시간이 지날수록 미니맵 비트맵 생성(관측 면적 비례)이 지배. 전용 직렬 큐라 UI를 직접 막지 않으며 Release는 이보다 낮다.
- 프레임당 처리 점: 970~3,072 — 설계 상한 준수.
- 3분+ 연속 스캔 생존, 메모리 경고 없음. footprint 441 → 770MB — 증가분은 ARKit mesh 앵커(스캔 면적 비례), 앱 격자는 고정.
- UI fps: 60.0 (최저 59.9) — **전수 처리 baseline(아래)에서 측정한 최악 부하 값**. 처리 큐와 UI가 격리돼 있어 tuned는 동일 이상.
- 전후 비교(stride 1·스로틀 0 baseline 대비): 콜백 107.7ms → 11.9ms (약 9배), points/frame 49,152 → ≤3,072 (16배). baseline은 처리 큐 포화 + ARFrame 11~13개 적체 경고(카메라 공급 중단 직전) — 스로틀·샘플링이 이를 막는 실증. 상세 표는 `DESIGN.md` 10절.

## 알려진 버그·제약

- 드리프트를 보정하지 않는다. 실기기 확인 결과 방 한 바퀴 규모에서는 드리프트가 셀 해상도(5cm) 이하 — 재관측 점이 기존 셀에 겹쳐 벽이 한 겹으로 유지됐다 (`DESIGN.md` 12절). 더 큰 공간·장시간은 미확인.
- 바닥·천장 구분이 스캔 시작 시 기기 높이(바닥 위 약 1.2~1.5m)에 의존한다. 실기기 확인: 앉아서(약 0.6m) 시작하면 바닥이 벽 취급(원색)으로 칠해져 벽/바닥 의미 구분이 사라진다. 공간 형태 가독성과 앱 동작은 유지.
- 격자는 시작 위치 중심 20m × 20m 고정. 밖의 점은 버린다.
- 트래킹이 limited인 동안 누적·궤적 기록을 중단한다(normal 게이트). 단 극단적으로 흔들면 ARKit이 normal을 유지한 채 포즈가 오염돼 유령 셀·궤적 뻗침이 생길 수 있다 — 게이트로 걸러지지 않으며 초기화로 복구한다.
- `excessiveMotion` 경고는 iPhone 15 Pro에서 유발 불가였다 (트래킹이 흔들기에 강함). 경고 경로 자체는 `insufficientFeatures`로 실증.
- 트래킹 회복 직후 새 영역의 mesh는 ARKit 재구성 재개까지 수 초 뒤에 나타난다. 기존 영역은 즉시 보인다.
- 미니맵 팬·줌·회전 없음. 전체화면 전환만.

## 검증

코드를 바꾼 뒤 아래 셋을 모두 통과해야 완료다. 계층 선택 기준은 `.codex/skills/test-policy/SKILL.md`.

```bash
# 1. 단위 테스트 (Model 순수 함수, 시뮬레이터) — 16건
xcodebuild test -project Threei_Assignment.xcodeproj -scheme Threei_Assignment-Development \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO

# 2. 실기기 타깃 컴파일 (서명 없이)
xcodebuild -project Threei_Assignment.xcodeproj -scheme Threei_Assignment-Development \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# 3. 구조·문서 계약 검사 (MVVM 배치, 계층 import 규칙, 테스트 배치, symlink, 문서 경로)
scripts/check-structure.sh
```

시뮬레이터 이름은 `xcrun simctl list devices available`에서 있는 것으로 바꾼다.

## 실기기 수동 검증 매트릭스

런타임 동작을 바꾼 커밋은 아래 시나리오 중 영향받는 항목을 실기기에서 확인하고 결과를 커밋 본문에 남긴다. "확인 방법"이 실패 판정 기준이다.

결과 열: iPhone 15 Pro (iPhone16,1) × iOS 26.6, 2026-09-04 — 사용자 촬영 화면 녹화 22편을 1fps 프레임 추출로 판독한 회차. 세부 근거는 해당 일자 docs 커밋 본문.

| 시나리오 | 요구사항 | 확인 방법 | 결과 |
| --- | --- | --- | --- |
| 카메라 권한 거부 | R4-2 | 첫 실행에서 거부 → "실행할 수 없습니다" 화면과 설정 열기 링크 표시 | 통과 (앱 삭제 후 재설치 흐름, 허용 후 정상 복귀까지) |
| 미지원 기기 | R4-2 | 비-LiDAR 기기 또는 시뮬레이터 → "지원되지 않는 기기" 화면 | 미검증 (비-LiDAR 실기기 없음) |
| 스캔 시작 | R1-1, R1-3 | 시작 전에는 카메라 위에 mesh가 없음. 시작 후 상태가 "스캔 중", 포인트·셀 카운트 증가. mesh 준비 전이면 "주변 인식 중…" 배지가 뜨고 첫 mesh 표시와 함께 사라짐 | 통과 (배지: 콜드 시작·초기화 후·재설치 후 3개 트리거 확인) |
| 일시정지·재개 | R1-2 | 카운트 증가 멈춤, mesh 표시 사라짐, 위치 마커와 궤적선은 계속 움직임. 재개하면 mesh 즉시 재표시, 새 영역이 실제 거리만큼 떨어진 자리에 그려지고 궤적이 두 영역을 잇는다 | 통과 |
| 초기화 | R1-2 | 미니맵 비워지고 "대기" 상태, 궤적 사라짐 | 통과 |
| 실시간 갱신 | R2-1 | 걸으면서 미니맵이 1초 안에 따라 채워짐 | 통과 |
| 미니맵 방향 | R2-3, R2-5 | 기기를 제자리에서 회전 → 맵은 고정, 마커 삼각형만 회전 (north-up) | 통과 |
| 오버레이 중심 고정 | R2-3, R2-4 | 걸어 다녀도 오버레이의 마커는 중앙, 맵이 밑에서 흐름. 창 배경이 균일하고(어두운 사각형 없음) 반경 6m 밖은 사라졌다가 되돌아가면 다시 나타남. 전체화면은 관측 영역 전체가 보임 | 통과 |
| 미니맵 색상 | R2-2 | 관측 셀이 카메라에 비친 색으로 칠해짐 — 벽 원색, 바닥 절반 밝기. 흰색 단색이 아님 | 통과 |
| 스케일 | R2-2 | 알려진 길이의 물체를 스캔 → 미니맵 셀 폭 환산이 실측과 정합 | 통과 (1.4m 책상, 오버레이 창 픽셀 측정 ±20%) |
| 바닥·천장 필터 | R2-2 | 바닥을 향해 스캔해도 벽(밝은 픽셀)이 생기지 않고, 천장은 무시 | 통과 (바닥: cells 불변 실증 / 천장: cells 3,658→3,660) |
| 전체화면 전환 | R2-4 | 미니맵 탭 → 전체화면, 배경 탭 → 복귀 | 통과 |
| 트래킹 경고 | R1-4 | 트래킹 limited 시 경고 배지, 앱 지속 | 통과 (`insufficientFeatures`로 실증. `excessiveMotion`은 유발 불가 — 알려진 제약 절) |
| 세션 중단 | R1-4 | 앱을 백그라운드로 보냈다가 복귀 → "세션이 중단되었습니다" 배지가 떴다가 사라짐. 이어서 "위치 재인식 중…"이 잠깐 뜨고, 복귀 후 이전 미니맵이 그 자리에 유지됨 (원점 불변) | 통과 (약 4초 내 재개, 격자 같은 자리) |
| 성능 | R3 | `DESIGN.md` 10절 측정 — FPS ≥30, 콜백 <10ms, 3분 스캔 중 강제 종료·메모리 경고 없음 | 통과 — fps 60/59.9, 3분 생존·경고 없음. 콜백 p50 11.9ms(Debug)는 목표 초과이나 UI 격리로 영향 없음 (10절 해석) |

결과 기록 형식: `기기 × iOS × 시나리오 × 결과(통과/실패/미검증)`. 실패는 `LLM_REPORT.md` 사례 후보이며, 파라미터를 바꾸면 `DESIGN.md` 근거를 갱신한다.
