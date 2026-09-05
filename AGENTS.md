---
title: BenchMarkVideo 저장소 작업 규범
kind: rule
last_verified: 2026-09-05
---

# BenchMarkVideo — 실시간 공간 스캔 & Top-Down Minimap

LiDAR(sceneDepth) 기반 실시간 공간 스캔 + occupancy grid 미니맵 iOS 앱. SwiftUI 단일 타깃, MVVM 계층 폴더링.

이 문서는 저장소 규칙의 도구 중립 진입점이다. 백과사전이 아니라 라우터다 — 규칙 본문은 아래 소유 문서에서 읽는다. `CLAUDE.md`는 이 파일의 symlink이므로 본문을 복사하지 않는다. Codex는 이 파일과 `.codex/skills/`를, Claude는 `CLAUDE.md`와 `.claude/skills/`(symlink)를 통해 같은 본문을 읽는다.

## 권위 순서 (충돌 시 위가 이긴다)

1. 실행 가능한 계약 — 소스 코드, `BenchMarkVideo.xcodeproj/project.pbxproj` 빌드 설정, `scripts/check-structure.sh`. 문서가 코드와 다르면 코드가 현재 사실이고, 문서를 고친다.
2. `TECH_RULES.md` — 고정 스택, 좌표계·동시성 규약, 구현 금지 사항.
3. 아래 문서 맵의 소유 문서 — 각 사실의 단일 소유자.
4. 이 문서의 절대 금지·작업 흐름.

계약을 바꾸려면 코드와 소유 문서를 같은 커밋에서 함께 바꾼다.

## 문서 맵 (사실 하나당 소유 문서 하나)

| 사실 | 소유 문서 | 갱신을 유발하는 변경 |
| --- | --- | --- |
| 고정 스택, 좌표계 규약, 동시성 규약, 구현 금지 | `TECH_RULES.md` | 프레임워크 변경, 좌표·큐 규칙 변경, 금지 패턴 추가 |
| 프로젝트 개요, 요구사항 대응표, 데모, 빌드·실행·검증 명령, 실기기 수동 검증 절차 | `README.md` | 기능·요구사항 상태·검증 절차 변경 |
| 요구사항 번호(R1~R4), 선택 항목 배점, 산출물·평가 조건 | `docs/spec/requirements.md` | 요구사항 명세 원문 변경 |
| 명세 대비 갭 분석, 보완 백로그와 우선순위, 가산점 후보 | `docs/spec/gap-analysis.md` | 백로그 항목 완료, 실기기 검증으로 판정 변경, 재점검 |
| 설계 판단 근거 (MVVM 채택, 시각화 방식, 격자·스로틀·필터 파라미터) | `DESIGN.md` | 구조 판단 또는 파이프라인 파라미터 변경 |
| 최종결과물 데모 영상 관찰과 현재 구현 범위 차이 | `DESIGN.md` §9 | 최종결과물 영상 재분석, 요구사항 변경 |
| MVVM 계층 배치 규칙과 허용 의존 방향 | `.codex/skills/mvvm-architecture/SKILL.md` | 계층 규칙, 허용 import 변경 |
| 현재 폴더·파일 책임 스냅샷 | `docs/architecture/folder-structure.md` | 파일 추가·이동·삭제 |
| 검증 계층 (단위 테스트·컴파일·구조 검사·실기기 매트릭스)과 테스트 필수 대상 | `.codex/skills/test-policy/SKILL.md` | 테스트 계층·필수 대상·실행 명령 변경 |
| 커밋 제목·본문·작성 주체 표기 규칙 | `.codex/skills/git-commit/SKILL.md` | 표기·본문 규칙 변경 |
| LLM 활용 기록 (도구, 역할 구분, 기각·수정 사례, 프롬프트) | `LLM_REPORT.md` | LLM 제안을 기각·수정한 즉시 |
| AI Agent 작업 지원 체계 | `docs/AI_AGENT_HARNESS.md` | 진입점, 문서 소유권, skill, 검사 흐름 변경 |
| 구조적 결정의 사유와 검증 결과 | Git 커밋 본문 | 구조 규칙 도입, 예외 승인, 동작 변경 |

문서 추가 규칙 (이 문단이 소유):
- 같은 사실의 소유자가 위 표에 있으면 새 문서 대신 그 문서를 갱신한다.
- 새 소유 문서는 현재 코드·실기기 증거로 내용을 채울 수 있을 때만 만들고, 만들면 이 표에 한 줄 추가한다. TBD 자리 문서와 빈 디렉터리는 만들지 않는다.
- 에이전트용 문서(루트 규범 문서, `docs/`)는 `title`, `kind`(`rule|design|guide|snapshot|history|spec`), `last_verified` frontmatter를 둔다. 사람이 읽는 산출 문서(`README.md`, `LLM_REPORT.md`)은 frontmatter를 두지 않는다.
- skill은 `name`, `description` frontmatter로 `.codex/skills/<name>/SKILL.md`에 두고 `.claude/skills/<name>/SKILL.md`는 symlink만 둔다.
- ADR·튜닝 로그·CI·PR 템플릿은 같은 결정의 번복, 파라미터 조정 반복, 원격 PR 리뷰 시작 같은 반복 비용이 생겼을 때 도입한다 (`docs/AI_AGENT_HARNESS.md` 확장 조건).

## 작업 유형별 필독

| 작업 | 시작 전 읽는 문서 |
| --- | --- |
| 모든 코드 변경 | `TECH_RULES.md`, `.codex/skills/test-policy/SKILL.md` |
| 파일 추가·이동, 리팩토링 | `.codex/skills/mvvm-architecture/SKILL.md`, `docs/architecture/folder-structure.md` |
| 파이프라인 파라미터(격자·스로틀·높이 밴드·샘플링) 튜닝 | `DESIGN.md`, `TECH_RULES.md` 좌표계 절 |
| 실기기 검증 결과·요구사항 상태 반영 | `docs/spec/requirements.md`, `docs/spec/gap-analysis.md`, `README.md` 체크리스트·수동 검증 절, `LLM_REPORT.md`, `DESIGN.md` |
| 문서·Agent 체계 변경 | `docs/AI_AGENT_HARNESS.md`, 이 문서의 문서 추가 규칙 |

## 절대 금지 (이 문서가 소유)

- 검증하지 않은 결과를 통과로 보고하지 않는다. sceneDepth는 시뮬레이터에서 nil이므로 런타임 동작은 실기기 확인 없이는 "미검증"이다.
- 파일·브랜치 삭제, 이력 재작성(`push --force`, `reset --hard`)은 사용자 승인 없이 하지 않는다.
- LLM 제안을 기각·수정한 사례를 몰아 쓰지 않는다 — 발생 즉시 `LLM_REPORT.md`에 추가한다.
- 커밋 메시지에 `Co-Authored-By`, `Claude-Session` 등 AI 트레일러를 넣지 않는다. 작성 주체는 제목의 `[llm]`/`[human]`/`[llm+human]` 태그로만 표기한다.
- 사용자 문구와 문서는 한국어로 쓴다. 코드 식별자·프레임워크 용어는 원문 유지.

## 명령어와 로컬 함정

실행·검증 명령의 단일 기준은 `README.md`.

- 실기기(iPhone 15 Pro) 필수 — 시뮬레이터·비-LiDAR 기기에서는 `ARFrame.sceneDepth`가 nil이라 파이프라인이 동작하지 않는다. 단위 테스트(Model 순수 함수)와 컴파일은 시뮬레이터에서 돈다.
- Xcode 26 신규 프로젝트는 `MemberImportVisibility`가 켜져 있어 암묵 import에 의존하면 컴파일이 실패한다. 쓰는 모듈은 명시적으로 import한다.
- `project.pbxproj`는 `PBXFileSystemSynchronizedRootGroup`이라 디스크에서 파일을 옮기면 타깃에 그대로 반영된다. 파일 추가·이동 때문에 pbxproj를 손으로 고치지 않는다.
- 한글 IME 오타로 타깃명이 바뀐 이력이 있다 (`핻`). pbxproj가 diff에 잡히면 의도한 변경인지 확인한다.

## 작업 흐름

1. 시작 전에 범위를 나눈다 — 동작 변경인지, 구조 변경인지, 파라미터 튜닝인지, 실기기 확인이 필요한지.
2. 변경 범위의 소유 문서만 읽는다. 전부 읽지 않는다.
3. 코드를 바꾸는 모든 작업은 `.codex/skills/test-policy/SKILL.md`를 적용한다 — Model 순수 로직은 `BenchMarkVideoTests/`에 테스트를 함께 두고, `xcodebuild test`와 `scripts/check-structure.sh`를 통과시키고, 런타임 동작이 바뀌면 실기기 수동 매트릭스를 남긴다.
4. 사실이 바뀌면 문서 맵의 소유 문서를 같은 커밋에서 갱신하고 `last_verified`를 갱신 날짜로 맞춘다.
5. 커밋은 의미 단위. 제목 끝에 작성 주체 `[llm]`/`[human]`/`[llm+human]`을 표기하고 본문에 사유와 검증을 남긴다 (`.codex/skills/git-commit/SKILL.md`).
6. 완료 보고에는 실행한 검증과 실행하지 못한 검증을 구분해 적는다.
