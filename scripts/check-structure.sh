#!/usr/bin/env bash
# 구조·문서 계약 검사. 규칙 본문: .codex/skills/mvvm-architecture/SKILL.md, docs/AI_AGENT_HARNESS.md
# grep 기반 — 간접 참조·의미 위반은 잡지 못한다.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=Threei_Assignment
ERRS=$(mktemp)
trap 'rm -f "$ERRS"' EXIT
err() { echo "✗ $1"; echo x >>"$ERRS"; }

# 1. 필수 문서
for f in AGENTS.md TECH_RULES.md README.md DESIGN.md LLM_REPORT.md \
         docs/AI_AGENT_HARNESS.md docs/architecture/folder-structure.md docs/spec/requirements.md \
         docs/spec/gap-analysis.md docs/spec/device-test-checklist.md; do
  [ -f "$f" ] || err "필수 문서 없음: $f"
done

# 2. frontmatter (루트 *.md + docs/**/*.md): title, kind, last_verified. 산출 문서(README, LLM_REPORT)는 제외.
while IFS= read -r f; do
  case "$f" in ./README.md|./LLM_REPORT.md) continue;; esac
  head -1 "$f" | grep -q '^---$' || { err "frontmatter 없음: $f"; continue; }
  fm=$(sed -n '2,/^---$/p' "$f")
  grep -q '^title: .' <<<"$fm" || err "frontmatter title 없음: $f"
  grep -qE '^kind: (rule|design|guide|snapshot|history|spec)$' <<<"$fm" || err "frontmatter kind 잘못됨: $f"
  grep -qE '^last_verified: [0-9]{4}-[0-9]{2}-[0-9]{2}$' <<<"$fm" || err "frontmatter last_verified 잘못됨: $f"
done < <(find . -maxdepth 1 -name '*.md' -type f; find docs -name '*.md' -type f)

# 3. canonical 진입 symlink
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ] || err "CLAUDE.md는 AGENTS.md symlink여야 함"
for d in .codex/skills/*/; do
  n=$(basename "$d")
  [ -f "$d/SKILL.md" ] || { err "skill 파일 없음: $d/SKILL.md"; continue; }
  grep -q "^name: $n$" "$d/SKILL.md" || err "skill name 불일치: $d/SKILL.md"
  grep -q '^description: .' "$d/SKILL.md" || err "skill description 없음: $d/SKILL.md"
  [ "$(readlink ".claude/skills/$n/SKILL.md")" = "../../../.codex/skills/$n/SKILL.md" ] \
    || err "symlink 없음/잘못됨: .claude/skills/$n/SKILL.md"
done
for d in .claude/skills/*/; do
  n=$(basename "$d")
  [ -f ".codex/skills/$n/SKILL.md" ] || err "canonical 없는 skill: $d"
done

# 4. Swift 배치: App / Model / ViewModel / View 아래만
find "$SRC" -name '*.swift' | grep -vE "^$SRC/(App|Model|ViewModel|View)/[^/]+\.swift$" \
  | while read -r f; do err "MVVM 폴더 밖 또는 하위 폴더: $f"; done

# 4b. 테스트 배치: Threei_AssignmentTests/*Tests.swift, Model 계층만 대상
TESTS=Threei_AssignmentTests
[ -d "$TESTS" ] || err "테스트 디렉터리 없음: $TESTS"
find "$TESTS" -name '*.swift' 2>/dev/null | grep -vE "^$TESTS/[A-Za-z0-9_]+Tests\.swift$" \
  | while read -r f; do err "테스트 파일 이름·위치 규칙 위반 (<Type>Tests.swift): $f"; done
grep -lE '\b(ContentView|MinimapView|ARPreviewView|ScanViewModel)\b' "$TESTS"/*.swift 2>/dev/null \
  | while read -r f; do err "테스트가 View/ViewModel 참조 (Model만 대상): $f"; done
for m in DepthFrameProcessor OccupancyGrid MinimapRenderer; do
  [ -f "$TESTS/${m}Tests.swift" ] || err "Model 순수 로직 테스트 없음: $TESTS/${m}Tests.swift"
done

# 5. 계층 규칙
check_absent() { # dir pattern message
  grep -lE "$2" "$SRC/$1"/*.swift 2>/dev/null | while read -r f; do err "$3: $f"; done
}
VIEW_TYPES='ContentView|MinimapView|ARPreviewView'
MODEL_OBJECTS='ARSessionManager|OccupancyGrid|MinimapRenderer|DepthFrameProcessor'
check_absent Model     '^import (SwiftUI|UIKit|Observation)$'   "Model에서 UI 프레임워크 import"
check_absent Model     "\b(ScanViewModel|$VIEW_TYPES)\b"         "Model이 상위 계층 참조"
check_absent ViewModel '^import (SwiftUI|UIKit|RealityKit)$'    "ViewModel에서 UI 프레임워크 import"
check_absent ViewModel "\b($VIEW_TYPES)\b"                       "ViewModel이 View 참조"
check_absent View      "\b($MODEL_OBJECTS)\b"                    "View가 Model 객체 직접 참조"
check_absent View      '\bDispatchQueue\b'                       "View에서 큐 접근"
# Model 최상위 타입은 nonisolated 명시 (접근 제어자 붙은 선언도 검사)
grep -nE '^(((public|internal|private|fileprivate|package)(\([a-z]+\))?|final) )*(class|struct|enum|actor) ' "$SRC"/Model/*.swift 2>/dev/null \
  | while IFS=: read -r f _ line; do err "Model 최상위 타입에 nonisolated 누락: $f — $line"; done

# 6. 문서 인라인 경로 존재 검사 (`path.swift|md|sh|pbxproj`; fenced block 밖만). 저장소 루트 또는 소스 루트 기준.
while IFS= read -r f; do
  awk '/^```/{c=!c} !c' "$f" | grep -oE '`[A-Za-z0-9_./-]+\.(swift|md|sh|pbxproj)`' | tr -d '`' | sort -u \
  | while read -r p; do
      case "$p" in *\**) continue;; esac
      if [[ "$p" == */* ]]; then [ -e "$p" ] || [ -e "$SRC/$p" ] || err "$f 가 없는 경로 참조: $p"
      else [ -n "$(find . -name "$p" -not -path './.git/*' | head -1)" ] || err "$f 가 없는 파일 참조: $p"; fi
    done
done < <(find . -name '*.md' -type f -not -path './.git/*' -not -path './.claude/*')

if [ -s "$ERRS" ]; then echo "구조 검사 실패"; exit 1; fi
echo "✓ 구조 검사 통과"
