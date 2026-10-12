---
title: 팀에서 바로 쓰는 에이전트 메모리 — 구현 가이드 v1
date: 2026-10-12
basis: synthesis.md 의 수렴 패턴 중 "지금 검증된 것"만 채택
principle: 최소 구성으로 시작, 과잉 설계 금지
---

# 팀에서 바로 쓰는 에이전트 메모리 — 구현 가이드 v1

## 결론: git 저장소 하나 + 디렉터리 범위 + PR 승격

조사 결과 지금 검증되어 바로 쓸 수 있는 패턴은 네 가지다.

- 파일/git 메모리 (Claude memory store, Letta MemFS, AGENTS.md)
- 범위 분리 + 공유 자료는 read-only (Claude 권장 패턴)
- private → shared 승격에 관문 두기 (MAPLE-Guard에서 가장 효과가 컸던 지점)
- 원천 권한 상속 (Asana)

반대로 벡터 DB 기반 메모리 제품(Mem0 등)을 먼저 들이는 건 비추천이다. GateMem에서 단순 baseline을 못 이겼고 권한/삭제 처리도 약했다. 검색 인덱스는 파일이 수백 개를 넘으면 그때 붙인다.

> ⚠ v1.1 점검 결과 (2026-10-12): 이 문서의 git 구성은 **개발 조직 전용 변형**이다. 비개발 조직이나 섞인 조직은 아래 8장의 "범용 구성"을 기준으로 한다. 개발 조직이라도 1장의 "디렉터리 = 권한 범위"는 틀렸다. GitHub/GitLab은 디렉터리 단위 읽기 권한이 없고 CODEOWNERS는 리뷰 담당만 정한다. 접근 경계가 다르면 **저장소(store)를 분리**해야 한다.

## 1. 저장소 구조

```text
team-memory/                  # git repo (GitHub/GitLab 권한 = 메모리 권한)
├── INDEX.md                  # 디렉터리별 한 줄 설명. 에이전트가 항상 먼저 읽는 목차
├── org/                      # 조직 공통: 용어집, 정책, 코딩/문서 규칙
├── teams/<team>/             # 팀 runbook, 운영 지식
├── projects/<project>/
│   ├── facts/                # 현재 유효한 사실 (환경, 담당자, 제약)
│   └── decisions/            # 결정 기록. append-only, YYYY-MM-DD-제목.md
├── skills/<name>/SKILL.md    # 검증된 절차 (배포, 장애 대응, 리포트 작성 등)
└── inbox/                    # 에이전트가 제안하는 곳. 에이전트는 여기만 쓴다
```

- 개인 작업 기억(세션 맥락, 개인 선호)은 각자 에이전트의 private 메모리에 둔다(Hermes memory, Claude Code auto memory 등). 팀 repo에 넣지 않는다.
- 민감 정보(인사, 고객 PII, 계약)는 **내용을 복사하지 말고 원천 링크만** 둔다. 그래야 접근 권한을 원천 시스템이 그대로 강제한다(Asana 방식).

## 2. 메모리 파일 형식

```markdown
---
description: 한 줄 설명 (목차와 검색에 노출됨)
scope: project:payments          # org | team:<x> | project:<x>
owner: @alice                    # 정정 책임자
source: https://jira.../PAY-123  # 근거 원문 링크 (필수)
status: active                   # active | superseded
valid_from: 2026-10-01
superseded_by:                   # 대체한 파일 경로
created_by: agent:claude-code/session-abc | human:@bob
origin: internal                 # internal | external (웹, 외부 문서에서 온 내용)
---
본문 (짧게. 파일 하나에 주제 하나)
```

## 3. 쓰기 흐름 = 승격 관문

1. 에이전트는 작업 중 배운 것을 `inbox/`에 파일로 쓰거나 브랜치에 커밋한다. 다른 경로에는 쓰기 권한이 없다.
2. PR이 열리면 리뷰어가 확인한다. 리뷰어는 사람(CODEOWNERS로 범위별 담당 지정) 또는 리뷰 에이전트(1차 검사)다. 확인 항목:
   - source 링크가 있나
   - 기존 사실과 충돌하나 (충돌하면 옛 파일은 `status: superseded` + `superseded_by` 처리. 지우지 않는다)
   - `origin: external`이면 지시문("앞으로 항상 ~해라")이 섞여 있지 않나 (메모리 오염 1순위 경로)
   - 비밀값이 없나 (pre-commit에 secret scanning)
3. 머지되면 해당 범위 디렉터리로 이동한다. `org/`는 관리자 승인 필수다.

이유: 하나 잘못 쓰면 모든 에이전트가 따라 쓴다. 공유로 올라가는 순간만 막으면 비용 대비 효과가 가장 크다.

## 4. 읽기 흐름

- 각 에이전트에 **필요한 디렉터리만 read-only로** 붙인다(Agent Loadout). 예: 리서치 에이전트는 org/ + projects/x/, 코딩 에이전트는 org/ + projects/x/ + skills/.
- 붙이는 방법(툴별):
  - Claude Code / Codex / OpenCode: 프로젝트 AGENTS.md(CLAUDE.md)에 "team-memory/INDEX.md를 먼저 읽고 필요한 파일만 열어라" + git submodule 또는 sparse checkout
  - Claude Managed Agents: org store(read_only) + 팀/프로젝트 store(read_write는 inbox 역할만)
  - 그 외 에이전트: 읽기 전용 MCP 파일 서버 하나
- 검색은 ripgrep으로 시작한다. 파일 수백 개를 넘거나 grep으로 찾기 어려워지면 그때 임베딩 인덱스를 추가한다.

## 5. 정정과 결정 기록

- 사실은 덮어쓰지 않는다. 옛 파일은 superseded로 남긴다. git history가 감사 로그다.
- 결정은 `decisions/`에 append-only로 쌓는다. 무엇을 정했나, 왜, 대안, 승인자, 근거 링크를 적는다. "왜 이렇게 했지?"에 답하는 팀 기억이고, context graph의 실용 버전이다.
- 틀린 사실이 발견되면 superseded 처리하고, 그 파일을 `source`로 인용한 다른 파일을 grep해서 함께 점검한다(정정 전파의 수동 버전).

## 6. 정리(consolidation)

- 주 1회 예약 작업이 inbox/와 최근 변경을 읽고 중복 병합, 오래된 사실 표시, INDEX 갱신을 **PR로 제안**한다. 자동 머지는 하지 않는다.
- 원본을 직접 고치지 않고 제안만 한다(Claude Dreams의 "새 store 출력" 원칙과 같다).

## 7. 단계별 도입

| 주차 | 할 일 | 완료 기준 |
|---|---|---|
| 1 | repo 생성, 디렉터리 구조, INDEX.md, 템플릿, CODEOWNERS, secret scanning | 사람이 org/·projects/에 초기 사실 20~30개 입력 |
| 2 | 각 에이전트에 read-only 연결 + inbox 쓰기 규칙 | 에이전트가 작업 중 메모리를 인용하고 inbox 제안을 올림 |
| 3 | 리뷰 에이전트 + 주간 정리 PR 자동화 | 제안 → 리뷰 → 머지 흐름이 사람 개입 최소로 돔 |
| 이후 | 필요할 때만: 검색 인덱스, Graphiti(시간 그래프), 관리형 store 전환 | 실제 불편이 생긴 지점만 |

## 8. 범용 구성 (비개발 조직 포함) — v1.1

### 8.1 git 구성이 비개발 조직에서 깨지는 지점

| 문제 | 이유 |
|---|---|
| PR/YAML을 아무도 안 씀 | 영업, 인사, 운영 담당자가 리뷰와 기여를 안 하면 승격 관문이 멈춘다 |
| 디렉터리별 읽기 권한 불가 | repo 접근 권한이 있으면 teams/hr/도 다 읽힌다 |
| 개인정보 삭제 불가에 가까움 | git history에 남은 PII를 지우려면 history를 재작성해야 한다. 삭제 요청 대응이 사실상 안 된다 |
| 민감 정보 비중이 큼 | 고객, 계약, 인사 정보가 기본값이라 "복사 금지, 링크만"이 예외가 아니라 원칙이 된다 |
| 사실이 빨리 바뀜 | 고객 상태, 담당자 변경 등은 markdown 파일보다 구조화된 레코드가 맞다 |

### 8.2 유지할 원칙 (조직 종류와 무관)

1. 접근 경계마다 store를 분리한다. 디렉터리나 태그는 정리용일 뿐 권한이 아니다.
2. 원문은 원래 시스템에 두고 에이전트는 사용자 권한으로 읽는다. 메모리에는 요약 + 원문 링크만 남긴다.
3. 에이전트는 제안만 하고, 공유로 올리는 건 담당자 승인을 거친다.
4. 사실은 덮어쓰지 않고 superseded로 남긴다. 결정은 쌓기만 한다.
5. 모든 항목에 출처, 담당자, 작성 주체(에이전트/사람), 내부/외부 표시를 붙인다.

### 8.3 범용 구성: 3층

```text
① 원천 지식층 — 기존 시스템 그대로 (Drive/SharePoint/Notion/CRM/티켓)
   에이전트는 커넥터로 "요청한 사용자 권한"으로 읽음. 복사하지 않음.
② 팀 메모리층 — 접근 경계(팀/부서)마다 store 1개
   에이전트가 배운 것: 요약 + 원문 링크 + 메타데이터
   구현: Notion DB / SharePoint List / 관리형 메모리 store 중 조직이 이미 쓰는 것
③ 승인 흐름 — 메신저(Slack/Teams)에서 승인/반려 버튼
   에이전트 제안 → 해당 store 담당자 승인 → 반영
```

- **store 형태:** 레코드 하나 = 메모리 하나. 속성은 description, 범위, 담당자, 원문 링크, 상태(제안/활성/대체됨), 유효일, 작성 주체, 내부/외부. 사용자가 YAML 대신 표로 보고 고친다.
- **조직 공통(org) store:** 전사 읽기 전용, 쓰기는 관리자 승인만.
- **삭제:** 레코드 삭제 + 버전 기록 정리가 가능한 플랫폼이어야 한다. 개인정보는 애초에 ②에 넣지 않고 ①의 링크로만 참조한다.
- **절차(skill):** 업무 매뉴얼, 체크리스트도 같은 승인 흐름을 거친 문서로 관리한다. 개발팀은 SKILL.md, 그 외 팀은 문서 페이지로 둔다.
- **개발팀:** 이 문서 1~7장의 git 구성을 개발팀용 ② store 구현으로 그대로 쓸 수 있다. 원칙이 같아서 다른 팀 store와 섞여도 된다.

### 8.4 플랫폼별 고르는 기준

- 이미 Microsoft 365 → SharePoint List(②) + Teams 승인(③). Copilot/에이전트 커넥터가 원천 권한을 따른다.
- 이미 Google Workspace / Notion → Notion DB 또는 Sheets(②) + Slack 승인(③).
- 자체 에이전트를 Claude Platform에서 운영 → 팀별 Claude memory store(②). 조직 store는 read_only로 붙이고, 승인은 앱에서 구현. 버전 보관 30일이라 주기적으로 export.
- 직접 구축해야 하면 → Postgres 테이블 + 행 단위 보안(RLS). store 경계 = 정책 경계.

## 9. 관리형으로 갈 때 기준

- Claude Platform 위에서 에이전트를 돌리면: Claude Managed Agents memory store. org는 read_only, 팀은 read_write. 버전 보관이 30일이라 git으로 주기적 export가 필요하다.
- AWS 위라면: AgentCore Memory namespace `/org/{org}/team/{team}/actor/{actorId}/` + IAM 조건키.
- 시간에 따라 바뀌는 사실이 많고(고객 상태, 담당자 변경) 질의가 복잡해지면: Graphiti를 사실 계층에만 추가한다. 이때 "최신이 이긴다" 규칙은 신뢰도 낮은 출처에서 오면 위험하니 승격 관문 뒤에 둔다.
