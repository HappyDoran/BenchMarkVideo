# LLM 활용 리포트

> 작성 규칙: 사례 발생 즉시 추가 (몰아 쓰기 금지). 최종 정리.

## 1. 사용한 도구와 워크플로우

- **도구**: Claude Code (CLI)
- **워크플로우**: 요구사항 명세 전체를 컨텍스트로 제공 → 브리핑/아키텍처 합의 → 프로젝트 `CLAUDE.md`에 좌표계·동시성 규약을 먼저 고정 → 모듈 단위로 구현 위임 → 매 단계 `xcodebuild` 컴파일 검증 → 실기기 테스트 결과를 피드백으로 재투입.
- **에이전트 컨텍스트 세팅** (`CLAUDE.md`): LLM이 자신 있게 틀리는 영역(좌표 변환, column-major, intrinsics 방향)을 규약으로 박아 두고, 동시성 규칙(scan.processing 큐 전용 접근)과 커밋 표기 규칙(`[llm]`/`[human]`/`[llm+human]`)을 명시. 의도: 세션이 바뀌어도 같은 규약으로 작업 이어가기 + 리포트 작성 근거를 커밋 로그에 남기기.
- **문서 체계 확장** (세션 2): `CLAUDE.md` 한 파일을 `AGENTS.md` 라우터(CLAUDE.md는 symlink) + 소유 문서(`TECH_RULES.md`, `DESIGN.md`, `README.md`) + skill + `scripts/check-structure.sh`로 분리. Claude·Codex가 같은 본문을 읽는다. 구조는 `docs/AI_AGENT_HARNESS.md`.

## 2. 역할 구분

| 파일/모듈 | 작성 주체 | 비고 |
|---|---|---|
| `Model/DepthFrameProcessor.swift` | LLM 초안 | unprojection 수식은 Apple 샘플의 flipYZ 방식 채택. 실기기 검증 예정 (벽 길이 비교) |
| `Model/ARSessionManager.swift` | LLM 초안 | 스로틀 주기·pause 의미(세션 유지, 누적만 중단)는 사람이 결정 |
| `Model/OccupancyGrid.swift` | LLM 초안 | 격자 해상도(5cm)·높이 밴드 파라미터는 실기기 튜닝 예정 |
| `Model/MinimapRenderer.swift` | LLM 초안 | auto-fit crop 방식 |
| `View/MinimapView.swift`, `View/ARPreviewView.swift`, `View/ContentView.swift` | LLM 생성 | UI 보일러플레이트 |
| `ViewModel/ScanViewModel.swift` | LLM 생성 | 세션 attach 중계는 MVVM 재배치 때 추가 (사례 4) |
| `Threei_AssignmentTests/*` (16건), XCTest 타깃·공유 scheme | LLM 생성 | 테스트 도입 시점은 사람 결정 (사례 6). 케이스 선정은 좌표 규약 문서 기준 |
| `docs/spec/requirements.md`, `README.md` 체크리스트·`DESIGN.md` 명세 대응 절 | LLM 생성 | 세션 2에서 명세 원문을 그대로 제공 → 요구사항 번호·산출물 조건을 소유 문서로 고정하고 R1~R4 상태를 매핑. 최종결과물 비디오는 프레임을 추출해 LLM이 직접 비교 |
| 아키텍처 결정 (RealityKit mesh 시각화로 Metal 렌더러 대체, north-up 고정, 고정 격자 채택, MVVM 계층 폴더링) | 사람 (LLM 브리핑 기반 합의) | 근거는 `DESIGN.md` |
| 문서 체계 (`AGENTS.md`, `TECH_RULES.md`, `README.md`, `DESIGN.md`, skill 3종, `scripts/check-structure.sh`) | LLM 초안 + 사람 | 다른 프로젝트의 Agent 작업 지원 체계를 순수 Swift 단일 타깃 규모에 맞게 축소. 구조는 사람이 지정, 본문은 LLM |

## 3. LLM이 틀렸던 지점 / 수정 사례

### 사례 1 — ARView.session 소유권 설계 오류 (설계 수정)
- **무엇**: LLM 초안의 `ARSessionManager`가 `ARSession`을 직접 생성·소유하고 ARView에 주입하는 구조로 작성.
- **어떻게 알았나**: RealityKit `ARView.session`은 **get-only** — 외부 세션 주입 불가.
- **수정**: 소유권 반전 — ARView가 세션을 소유하고 매니저는 `attach(to:)`로 delegate만 연결.

### 사례 2 — CVPixelBuffer 포인터 타입 불일치 (컴파일 오류)
- **무엇**: confidence map 접근에서 `UnsafePointer<UInt8>?` 변수에 `CVPixelBufferGetBaseAddress` 결과(`UnsafeMutableRawPointer` → `assumingMemoryBound`는 Mutable 포인터 반환)를 대입.
- **어떻게 알았나**: `xcodebuild` 검증에서 "type of expression is ambiguous" — 에러 위치가 대입문이라 타입 추적으로 파악.
- **수정**: `UnsafeMutablePointer<UInt8>?`로 선언 변경. 매 모듈 컴파일 검증을 파이프라인에 둔 이유.

### 사례 3 — MemberImportVisibility로 인한 암묵 import 실패
- **무엇**: `MinimapRenderer`에서 `Data` 사용하며 `Foundation` import 누락 (LLM이 CoreGraphics 경유 암묵 import 가정). Xcode 26 신규 프로젝트는 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`라 실패.
- **수정**: 명시 import 추가.

### 사례 4 — 기능 단위 폴더링을 MVVM 계층 폴더링으로 교체 (구조 수정, 사람 결정)
- **무엇**: LLM 초안은 `Scan/`, `Minimap/`, `UI/` 기능 단위로 파일을 배치. 사람이 MVVM(`App/Model/ViewModel/View`) 계층 기준으로 재배치를 지시.
- **왜**: 이 앱의 핵심 제약은 큐 격리(MainActor vs `scan.processing`)인데, 기능 폴더링은 어느 파일이 어느 스레드에서 도는지 드러내지 않았다. 계층 폴더링은 격리 경계를 폴더로 보이게 하고 배치 규칙을 스크립트로 검사할 수 있게 한다. 대안 비교는 `DESIGN.md` 1.1절.
- **재배치 중 발견한 LLM 코드 위반**: `ARPreviewView`(View)가 `ARSessionManager`(Model)의 `attach(to:)`를 직접 호출하고 있었다. View → ViewModel → Model 단방향을 깨는 구조라 `ScanViewModel.attach(session:)` 중계 메서드를 두고 View는 `ARSession` 콜백만 받도록 수정. `ScanViewModel`의 불필요한 `import SwiftUI`도 제거.
- **재발 방지**: `scripts/check-structure.sh`가 View의 Model 객체 참조, Model의 UI 프레임워크 import, `nonisolated` 누락을 grep으로 검사. 같은 스크립트가 이 리포트의 옛 경로(`Scan/…`, `Minimap/…`)도 잡아냈다.

### 사례 5 — 참조 프로젝트 잔재가 문서에 섞임 (내용 수정)
- **무엇**: 문서 체계를 다른 프론트엔드 mono-repo의 Agent 체계에서 착안해 옮기면서, LLM이 `docs/AI_AGENT_HARNESS.md`에 "참조 프로젝트 대비 뺀 것: workspace별 AGENTS, feature README, 브리지 계약 인덱스…" 같은 비교 문장과 참조 프로젝트 이름을 남겼다.
- **어떻게 알았나**: 사람이 "순수 Swift 프로젝트라 그 프로젝트에서만 쓰는 내용은 제거하라"고 지적.
- **수정**: 전 문서 grep으로 mono-repo·React·npm·브리지 등 용어를 전수 검색해 잔재 3곳 제거. 나머지 문서는 처음부터 Swift 전용으로 작성돼 0건.

### 사례 6 — 단위 테스트를 "도입 조건부"로 미룬 정책 기각 (정책 수정, 사람 결정)
- **무엇**: LLM이 `test-policy`를 쓰면서 XCTest 타깃을 "파라미터 두 번째 수정 또는 좌표 버그 발견 시" 도입하는 조건부로 미뤘다. 요청받지 않은 범위를 늘리지 않으려는 판단이었다.
- **왜 틀렸나**: 요구사항에 테스트가 포함되는 상황에서 "도입 조건"은 곧 감점 사유다. 사람이 문서 완성도를 묻는 질문에 LLM 스스로 이 점을 지적했고, 사람이 적용을 결정.
- **수정**: `Threei_AssignmentTests` 타깃과 공유 scheme을 `project.pbxproj`에 추가하고 Model 계층 테스트 14건 작성(좌표 규약·버퍼 필터·격자 분기·crop). 첫 실행에서 전부 통과. `test-policy`를 "Model 순수 로직은 테스트 필수"로 개정하고 `scripts/check-structure.sh`가 세 Model 타입의 테스트 파일 존재를 검사.

### 사례 7 — 규약 문서의 heading 수식이 코드와 π만큼 어긋남 (교차 리뷰로 발견)
- **무엇**: LLM이 규약 문서(TECH_RULES.md 좌표계 절)에 heading 수식을 `atan2(-m2.x, -m2.z)`로 적었으나 코드는 `atan2(-m2.x, +m2.z)` — 항등 변환에서 문서는 π, 코드는 0. "LLM은 좌표 변환에서 자신 있게 틀린다"가 규약 문서 자체에서 재현된 사례.
- **어떻게 알았나**: 단위 테스트가 코드 쪽(`heading == 0`)을 고정하고 있었고, 전체 diff 대상 `/code-review`가 문서-코드 모순을 보고.
- **수정**: 문서 수식을 코드에 맞추고, 수식 옆에 고정 테스트 이름을 병기해 어느 쪽이 정본인지 명시.
- **교훈**: 규약을 문서에 박아도 문서 자체가 LLM 산출물이면 같은 오류 축이 남는다. 정본은 테스트가 고정한 코드이고, 문서는 테스트를 참조해야 한다 (권위 순서 1번이 코드인 이유).

### 사례 8 — 전체 diff 코드 리뷰 반영 (LLM 리뷰 → LLM 수정, 사람 승인)
- **무엇**: `/code-review`(정확성)와 ponytail 리뷰(과잉 설계)를 교차 실행. 정확성 10건 전부 수용: 트래킹 limited 상태 누적 차단(유령 벽), 세션 오류의 일괄 fatal 처리에 재시도 경로 추가, 콜백 hop을 Task(순서 미보장)에서 main 큐 FIFO로 교체, reset 잔상 방지, 마커의 반 셀 오프셋(+0.5), straight/premultiplied alpha 불일치, 수직 시선에서 heading 노이즈 회전, 구조 검사 정규식의 접근 제어자 누락, 암묵 import 2건, 사례 7의 문서 수식.
- **과잉 설계 리뷰**: 3건(-19줄)만 나옴 — 궤적 조건 6줄→1줄, 상태 배지 switch 병합, 매직 넘버 패딩 제거.

### 사례 9 — 실기기 1차 확인에서 LLM 설계 2건 기각, 1건 부작용 수정 (사람 판단)
- **무엇**: iPhone 15 Pro에서 처음 돌린 결과 (a) 오버레이 미니맵이 auto-fit이라 맵이 커질수록 마커가 가장자리로 밀림, (b) 미니맵이 벽 흰색·바닥 회색 단색이라 실제 공간과 대응이 안 읽힘, (c) "스캔 시작"을 눌러도 카메라 위 mesh가 2초 뒤에 나타남.
- **어떻게 알았나**: 전부 사람이 실기기 화면을 보고 지적. (a)(b)는 LLM이 "비용이 낮고 가독성이 높다"고 근거를 달아 제안했고 문서(`DESIGN.md` 11절)에도 그렇게 적혀 있었지만, 150pt 창에서 실제로 보니 "내가 어디 있나"와 "여기가 어디인가"를 둘 다 못 읽었다. (c)는 LLM이 카메라 표시를 앞당기려고 mesh를 스캔 시작 시점으로 미룬 이전 결정(커밋 3d1c4e4)의 부작용.
- **수정**: (a) 렌더러는 그대로 두고 `MinimapView`가 scale·offset으로 카메라를 중앙에 고정, 반경 4m만 표시 — 전체화면은 auto-fit 유지 (`DESIGN.md` 3.4절). (b) `capturedImage`를 depth 픽셀과 같은 좌표로 샘플링해 셀별 색을 EMA로 누적 (`ScanPoint.color`, `OccupancyGrid.colors`). (c) mesh를 트래킹 `normal` 시점에 미리 켜는 예열로 변경.
- **교훈**: "비용 대비 가독성" 같은 설계 근거는 실기기 화면 크기에서 다시 검증해야 한다. LLM 근거가 논리적으로 맞아도 150pt 창이라는 물리 제약은 문서만으로 못 본다.

### 사례 10 — 같은 수정의 1차 결과를 실기기에서 다시 기각 (2회차 피드백)
- **무엇**: 사례 9의 수정을 실기기에서 재확인한 결과 2건이 여전히 틀렸다. (a) 카메라 중심 창은 됐지만 미관측 셀을 "반투명 검정"으로 칠해 둬서, 이미지 영역과 그 바깥 배경의 색이 달라 창 안에 어두운 사각형이 떠 있고 스캔할수록 커지는 것처럼 보였다. (b) mesh 예열을 트래킹 `normal` 시점에 걸었는데 트래킹 수렴 자체가 수 초라 여전히 늦었다.
- **어떻게 알았나**: 사람이 스크린샷과 함께 "마커 주변 검은 배경이 인식할수록 늘어난다", "카메라가 뜨고 나서 아직도 mesh가 바로 안 보인다"고 지적.
- **수정**: (a) 미관측 셀 alpha를 150 → 0. View 배경 하나만 남아 창이 균일해지고, 반경 밖은 `clipShape`가 자른다. (b) 예열을 첫 프레임 도착 직후로 앞당김 — 카메라 패스스루가 이미 시작된 뒤라 표시 지연은 안 생긴다.
- **덧붙임 2**: 예열을 첫 프레임으로 앞당기자 스캔 시작 전에도 와이어프레임이 보였다 (사람이 3회차 확인에서 지적). LLM이 "재구성"과 "표시"를 하나로 다뤄서 생긴 부작용 — 세션 구성(`sceneReconstruction`)과 ARView 디버그 옵션(`showSceneUnderstanding`)은 별개다. 재구성은 예열 유지, 표시만 `ARPreviewView(showMesh:)`로 스캔 상태에 묶어 해결.
- **덧붙임**: 같은 확인에서 사람이 "반경을 넓혀도 문제없다"고 판단해 오버레이 반경을 4m → 6m로 조정. 창이 카메라를 따라 미끄러지며 들어온 영역이 나타나고 벗어난 영역이 사라지는 동작은 (a)의 clipShape로 이미 성립해 있었고, 값만 바꿨다.
- **교훈**: LLM이 "고쳤다"고 보고한 것과 사용자가 화면에서 보는 것은 다르다. 두 건 모두 첫 수정이 논리적으로는 맞았고(창은 중앙 고정됐고, 예열은 앞당겨졌다) 사용자가 불편한 지점은 그대로였다. 실기기 확인은 수정 1회당 1회가 아니라 사용자가 됐다고 할 때까지 반복해야 한다.

### 사례 11 — 일시정지 의미의 재정의 (사람 결정)
- **무엇**: LLM 초안은 일시정지 중 격자 누적과 궤적 기록을 함께 멈췄다. 사람이 "일시정지 후 다른 곳으로 가서 재개하면 어떻게 되는가"를 물었고, 답(새 영역은 실제 위치에 그려지지만 이동 구간의 궤적은 끊긴다)을 듣고 "궤적은 일시정지 중에도 기록하라"고 결정.
- **왜**: 궤적의 목적은 "어디를 지나왔는가"이고, 이는 격자를 채웠는지와 무관하다. 끊긴 궤적은 사용자에게 A와 B 사이를 순간이동한 것처럼 보인다.
- **수정**: `ARSessionManager`에 `hasStarted` 플래그를 두고, 스캔을 한 번 시작한 뒤에는 `isAccumulating`과 무관하게 궤적을 기록. 스캔 시작 전 이동은 기록하지 않는다 (`reset`에서 해제).

### 사례 12 — 실기기 항목 24개를 코드로 사전 추적, 3건 결함 발견 (LLM 자체 검증, 사람 요청)
- **무엇**: 사람이 "실기기 테스트 항목 1~24를 먼저 코드로 확인하라"고 요청. LLM이 각 시나리오를 소스에서 추적한 결과 3건이 코드상 틀려 있었다. (a) 사례 11에서 궤적을 일시정지 중에도 기록하게 바꾸면서 `tracking normal` 조건까지 같이 빠져, 흔드는 동안 튀는 포즈가 궤적 스파이크로 남는다. (b) `sessionShouldAttemptRelocalization`을 구현하지 않아 백그라운드 복귀 후 ARKit이 트래킹을 새로 시작하면 원점이 바뀌고 격자가 통째로 어긋난다. (c) 세션 오류 후 "다시 시도"로 ARView가 재생성될 때 mesh 예열 플래그가 그대로라 예열이 안 걸린다.
- **어떻게 알았나**: 시나리오별로 상태 플래그(`isAccumulating`·`hasStarted`·`didRequestMeshWarmUp`)와 delegate 콜백 경로를 손으로 따라감. (a)는 직전 커밋의 diff에서, (b)(c)는 "복귀 후 미니맵 유지"·"다시 시도" 시나리오를 따라가다 발견.
- **수정**: (a) 궤적 조건에 `case .normal` 복원. (b) `sessionShouldAttemptRelocalization → true` 명시. (c) `attach`에서 예열 플래그 해제.
- **교훈**: 사람이 준 실기기 체크리스트는 코드 리뷰 체크리스트로도 쓸 수 있다. 실기기에 가기 전에 시나리오를 코드로 한 번 따라가면 왕복 횟수가 준다. 다만 (b)는 ARKit 기본 동작에 의존하는 문제라 코드만으로는 "어긋난다"를 확정할 수 없고, 명시적으로 `true`를 두는 것이 어느 쪽이든 안전한 선택이었다.

<!-- 실기기 검증 단계에서 좌표 변환·필터 파라미터 관련 사례 추가 예정 -->

## 4. 핵심 프롬프트 발췌

(최종 정리 — 후보: ① 요구사항 명세 전체 + 브리핑 요청 → 아키텍처 합의, ② CLAUDE.md 규약 선행 작성 지시, ③ 실기기 테스트 피드백 루프 프롬프트)
