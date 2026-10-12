---
title: "TencentDB Agent Memory — Team Memory (Memory Hub) Beta"
source_owner: "Tencent Cloud (TencentDB Agent Memory Team) / 비판: VentureBeat (Sean Michael Kerner)"
urls:
  - https://github.com/TencentCloud/TencentDB-Agent-Memory
  - https://github.com/TencentCloud/TencentDB-Agent-Memory/blob/main/README.md
  - https://github.com/TencentCloud/TencentDB-Agent-Memory/blob/main/ROADMAP.md
  - https://github.com/TencentCloud/TencentDB-Agent-Memory/blob/main/MemoryPanel/panel-api-doc.md
  - https://github.com/TencentCloud/TencentDB-Agent-Memory/blob/main/MemoryCore/src/metadata/service/user-visibility.ts
  - https://venturebeat.com/data/tencents-team-memory-shares-ai-agent-memory-across-a-team-with-no-governance-yet-for-when-its-wrong
accessed: 2026-10-12
type: "오픈소스 repo(1차) + 테크 언론 비판 기사(2차)"
read_status: "README(현행, gh api로 수령)·ROADMAP·Panel API 문서 일부(visibility/skill/delete 관련 grep)·user-visibility.ts 전문·VentureBeat 기사 전문 읽음. MemoryCore/MemoryKnowledge v3 API 문서, CHANGELOG, INSTALL은 미독."
---

# TencentDB Agent Memory — Team Memory

> 주의: raw.githubusercontent.com 캐시로 받은 README는 구버전(단일 에이전트 L0–L3 + 단기 Mermaid offload 중심)이었고, `gh api .../readme`로 받은 현행 README(v2.0.0, "Team Memory Beta")가 Memory Hub/팀 기능을 설명한다. 이 노트는 현행본 기준이며, 구버전 수치(단기 메모리 벤치)는 별도 표시.

## 한 줄 요약

Tencent가 기존 개인용 계층형 메모리(L0 Conversation→L1 Atom→L2 Scenario→L3 Persona)를 팀 단위 "Memory Hub"로 확장해, Chat Memory·Skill·Wiki·CodeGraph 네 가지 "Memory Asset"을 owner/version/status/visibility(private·team·restricted·agent)와 함께 관리하고 에이전트별로 "Loadout"(Fixed Binding + ACL)으로 장착시키는 오픈소스 시스템 — 단, 공유된 기억이 틀렸을 때의 정정·만료·충돌 해소 거버넌스는 문서상 아직 없다(VentureBeat 지적, Tencent ROADMAP도 일부 인정).

## 핵심 설계/주장

### 구성 요소 (현행 README)

- 서비스 3종: `memory-core` + `memory-hub`(패널, 기본 `http://localhost:8125`) + `proxy`. `deploy/global-images/start-all.sh`로 일괄 기동.
- **Proxy 방식 통합**: "One Proxy, unchanged protocol, zero-code integration" — 에이전트의 base URL을 Proxy로 바꾸면 플러그인/훅/MCP 없이 메모리 주입·write-back. 지원 클라이언트: DeepSeek Harness, Claude Code, Codex, CodeBuddy, WorkBuddy, Hermes, OpenClaw(Cursor는 로드맵).
- 저장 백엔드: 기본 SQLite(+sqlite-vec), TCVDB, MongoDB(experimental, 기본 off).
- 회상: BM25 + vector + RRF 하이브리드. 결과는 item 수·문자 예산·timeout으로 상한(구버전 설정: `recall.maxResults` 기본 5, `recall.timeoutMs` 5000 등).

### 네 가지 Memory Asset

| Asset | 내용 | 생성 경로 |
|---|---|---|
| **Chat Memory** | 선호·사실·결정·상호작용 이력. L0 Conversation → L1 Atom(사실/선호/제약/이벤트) → L2 Scenario(프로젝트·시나리오 블록) → L3 Core/Persona(장기 프로필) | 대화에서 비동기 파이프라인으로 추출. 에이전트 생성 시 자동으로 자기 메모리 블록(`chat_memory-{team}-{agent}`) 생성 |
| **Skill** | "prompt snippet이 아니라" version, resource files, trigger boundaries, execution steps, validation rules를 가진 절차 자산 | 대화/툴콜에서 추출, `mem:create-skill` 명령. 개인 Skill은 기본 private, "after review" 팀 공유·다른 에이전트 배정 가능. Hermes Agent의 Skill 코드 일부를 차용했다고 명시 |
| **Wiki (LLM-Wiki, asset_type `llm_wiki`)** | 제품 문서·설계 스펙·런북을 link graph 있는 구조화 페이지로 | 문서 import → 비동기 빌드(`processing`→`ready`/`failed`). Karpathy "LLM Wiki" gist에서 영감 |
| **CodeGraph** | 심볼·파일·호출관계·impact path 인덱스 | repo import → 비동기 빌드(`building`). colbymchenry/codegraph 코드 사용. 현재 public HTTPS repo 우선 |

- Wiki/CodeGraph는 컨텍스트에 통째로 주입하지 않고 도구로 노출: `/v3/tools/list`로 발견 → `/v3/tools/call`로 페이지·소스·impact path 조회 ("called on demand").

### 가시성(visibility) 티어

| 값 | 의미 (README 원문 요지) |
|---|---|
| `private` | Owner만 읽음 — "not even team admins" |
| `team` | 팀원 읽기 가능, Owner/Admin 관리 |
| `restricted` | User / Role / Agent ACL로 정밀 접근 |
| `agent` | 같은 팀 내 특정 에이전트에 타깃 장착 |

- **새 Chat Memory·Skill은 기본 private** — "Sharing is an explicit action, not a default leak."
- Panel API의 `POST /knowledge/set-visibility`는 `private`/`team`/`restricted`/`agent`/**`task`** 다섯 값을 받는다 → README에 없는 `task` 범위가 API에 존재.
- Panel API: 팀 자산 읽기 권한 = "owner / `visibility=team` / 이미 caller 소유 agent가 차용(借入)" 중 하나; 아니면 `403 ASSET_NOT_ACCESSIBLE`. ACL 액션: `acl grant/revoke/list/check`. 오류코드 `ASSET_NOT_SHARED`, `NOT_ASSET_OWNER` 등.

### 역할(Role) 모델

- 전역 **System Admin**(사용자·팀 생성, 멤버 추가, 자산 관리 기능 사용 가능) + 팀 레벨 **Admin**/**Member**. 자산 소유는 **Owner** 필드로 추적, Owner는 자동으로 관리 권한.
- `user-visibility.ts`: system_admin 계정은 목록 조회 시 타인에게 기본 숨김; 일반 사용자는 자기 자신만 조회, 팀 리스트 문맥(`allowTeamPeers`)에서는 팀 동료 조회 허용. 주석상 "단일 인스턴스에 system_admin은 하나(설계 불변식)".

### Agent Loadout

- "Memory isn't a global prompt — it's the Agent's loadout." 모든 자산을 Memory Asset으로 통일 등록 → **Fixed Binding + ACL**: 먼저 Team·User·Agent·visibility로 권한 범위를 좁히고, 그 안에서 현재 query로 검색.
- 예시: Scout(인터뷰 Chat Memory + 시장조사 Wiki + 경쟁분석 Skill), Builder(Product Wiki + CodeGraph + Feature Delivery Skill), Reviewer(장애이력 Chat Memory + CodeGraph + Release Checklist Skill).
- Hub 기능: Team Up / Asset Library / Agent Loadout(우선순위·usage mode 조정) / Knowledge Workshop / Access Control("revoke sharing when needed").
- 자산 메타: "where it came from, which version it is, who it's assigned to, and whether it's been used recently" — ownership, versions, status, visibility, usage counts(`touch-usage` 액션), agent bindings.
- 자동 라우팅은 아직 아님: "The Hub supports manual asset binding; fully automated memory routing is still under iteration."

### 버전·리뷰·삭제 (확인된 범위)

- Skill API 15개 액션에 `versions`(버전 목록), `patch`, `export`, `extract`, `conversation/add` 포함. Skill 목록 필터 `status: ["active"]`.
- Chat Memory: `POST /chat-memory/layer-delete`(L0/L1 계층 일괄 삭제). Agent 삭제는 `delete-cascade`(소유 active skill 삭제 후 archive).
- ROADMAP v2.0.1: **"Editable memories: L1–L3"** — "facts expire, decisions get reversed, and extraction itself can be off. The panel currently only allows viewing and deleting." → 현재(v2.0.1-beta.1)는 조회·삭제만 가능, 편집은 계획.
- ROADMAP: Agent 템플릿(관리자가 기본 loadout 정의), `mem:` 명령 확장(Task 생성/갱신), L0/L1 검색(결론을 원 출처로 역추적), Cursor 지원.
- `mem:` 세션 명령(v2.0.0 출시): `mem:sync`(세션에 주입된 Skills/memories/Knowledge/Task&Agent 설명 갱신), `mem:create-skill [prompt]`, `mem:help`.

### 구버전 README의 설계 원칙 (단일 에이전트 시절, 현행에도 계층 유지)

- "Lower layers preserve evidence; upper layers preserve structure." 하위(사실·로그·트레이스)는 DB, 상위(persona·scene·canvas)는 사람이 읽는 Markdown.
- drill-down 경로 보장: Persona/canvas → Scenario/jsonl → L0 Conversation/refs. 단기 메모리는 툴 로그를 `refs/*.md`로 offload하고 Mermaid canvas + `node_id`만 컨텍스트에 유지.
- 구버전 설정: `pipeline.everyNConversations` 5(L1 추출 주기), `persona.triggerEveryN` 50, `extraction.enableDedup` true(L1 vector dedup/충돌 감지), `capture.l0l1RetentionDays` 0(=영구).

## 근거 (모두 vendor-reported)

- 현행 README 벤치: **PersonaMem 48% → 76% (+59% 상대)** — "Agent가 장기 상호작용 후 사용자 정보를 올바르게 이해·적용하는가". 팀 기능(Loadout·공유) 자체에 대한 벤치마크는 없음.
- 구버전 README(OpenClaw 통합, 단기 메모리): WideSearch 성공률 33%→50%(+51.52%), 토큰 221.31M→85.64M(−61.38%); SWE-bench 58.4%→64.2%(+9.93%), 토큰 3474.1M→2375.4M(−33.09%); AA-LCR 44.0%→47.5%(+7.95%), 토큰 −30.98%. "SWE-bench runs 50 consecutive tasks per session".
- VentureBeat: Tencent가 repo가 GitHub TypeScript trending 1위라고 밝힘(Tencent 측 X 게시물 인용). 기사 날짜 2026-08-07, Team Memory Beta는 "this week" 출시.
- VentureBeat가 인용한 VB Pulse(2026년 6월): 기업 57%가 확신에 찬 오답을 누락/불일치 컨텍스트로 추적; 25%만 governed context layer를 프로덕션 운영(VB 자체 설문).

## 비판·한계

### 출처에 나온 비판

- **VentureBeat(Kerner)**: 접근 모델은 "누가 읽을 수 있나"에 답하지만 "기억이 틀렸을 때 어떻게 되나"에는 답하지 않음. 문서에 ownership·versioning·status는 있으나 "nothing in the documentation describes a correction or expiry process for a fact that's already been read and reused by other agents on a team, or a way to resolve it when two agents' memories of the same thing disagree."
- X 실무자 반응(기사 인용): Blake Murphy — "Shared memory makes the write path the interesting problem… a wrong fact written once now propagates to every teammate's agent"; Virgil Maro — "someone has to decide what never gets written down"; Austin Green — "whose memory wins when two teammates' agents have written contradicting facts… Shared memory drifts fast".
- 기사가 연결한 독립 논문 "Governed Memory: A Production Architecture for Multi-Agent Workflows"(arXiv 2603.17787): governance fragmentation, 피드백 루프 없는 silent quality degradation을 공유 메모리의 구조적 위험으로 지목(본 노트에서 논문 본문은 미독).
- Tencent 자신의 ROADMAP도 "facts expire, decisions get reversed, extraction itself can be off" 및 현재 view/delete만 가능함을 인정.

### 자체 평가

- **정정 = 삭제만 가능**: 삭제는 이미 그 사실을 읽어 Skill/파생 자산에 반영한 다른 에이전트에 전파되지 않는다(파생 자산 lineage/무효화 연쇄 메커니즘이 문서에 없음). Zep식 유효기간(valid/invalid) 개념도 없음.
- **visibility가 "읽기"만 다룸**: 쓰기 권한(누가 team 자산을 수정·승격할 수 있는가)은 Owner/Admin 수준으로만 기술. 공유 승격 시 "review"의 실제 워크플로(리뷰어 지정, 승인 기록)가 README/Panel API에서 확인되지 않음.
- **Persona(L3)가 팀 맥락에서 의미하는 바 불명확**: "user's and team's context"라고 하지만 팀 persona가 누구의 대화로부터 어떻게 합성되는지, 개인 private 대화가 팀 persona로 새지 않는 보장이 문서로 확인되지 않음.
- **`task` visibility가 README에는 없고 API에는 존재** → 문서와 구현 간 드리프트 가능성.
- 벤치는 개인화(PersonaMem) 한정, 팀 공유 효용/누출률/오염 전파에 대한 측정 없음.
- CodeGraph private repo 미지원, 자동 라우팅 미지원 → 현재는 사람이 수동으로 loadout을 구성하는 "자산 레지스트리"에 가깝다.

## 팀/조직 메모리 설계에 주는 시사점

- **메모리를 "자산"으로 1급 객체화**: 타입(chat memory/skill/wiki/codegraph) × owner × version × status × visibility × binding × usage count의 메타데이터 스키마는 조직 메모리 레지스트리의 좋은 출발점.
- **기본 private + 명시적 공유(opt-in)** 가 다중 주체 환경의 안전한 디폴트. 다만 "공유 승격(promotion)"에는 리뷰어·승인 기록·근거 링크를 필수 필드로 둬야 한다.
- **권한 필터 먼저, 검색은 그다음**(Fixed Binding + ACL → query retrieval): pre-filter 방식은 검색 결과 후처리 필터보다 누출에 강하다(Neo4j 문서의 "결과 페이지 후필터는 경계가 아니다" 경고와 일치).
- **역할별 loadout**: 에이전트마다 필요한 자산만 장착 → 노이즈·누출 표면 감소. 관리자 정의 템플릿(로드맵)은 신규 에이전트 cold start 표준화에 유용.
- **쓰기 경로 거버넌스가 핵심 격차**: 정정(edit with history), 만료(TTL/valid_until), 충돌 해소(정본 우선순위·소유자 결정), 파생물 무효화 전파를 설계 초기에 넣어야 한다 — Tencent 사례가 반면교사.
- 문서/코드 지식은 주입이 아니라 **도구 호출(on-demand)** 로 노출하면 컨텍스트 예산과 권한 검사를 호출 시점에 걸 수 있다.

## 다른 개념과의 연결

- **Asana AI Teammates**: 같은 "공유 메모리 + 접근통제" 문제를 폐쇄형 플랫폼에서 해결. Asana는 메모리 접근을 "원 작업(source work)의 권한 상속 + 트리거한 사용자 기준"으로 스코프 — Tencent는 자산별 visibility 라벨. 두 모델 비교가 유익(→ asana-awm.md).
- **Zep/Graphiti**: bi-temporal 무효화(`t_invalid`, `t'_expired`)는 Tencent에 없는 "정정·만료" 메커니즘의 직접적 대안(→ zep-graphiti-2501.13956.md).
- **Context graph / decision traces**: Skill 리뷰·공유 승격 결정 자체를 decision record로 남기면 "왜 이 Skill이 팀 정본이 되었나"를 감사 가능(→ context-graphs-decision-traces.md).
- **Karpathy LLM Wiki, Hermes Agent Skills, CodeGraph**: 직접 차용 관계 명시.
- 계층 L0→L3은 Zep의 episode→semantic→community 계층과 구조적으로 유사(원본 보존 + 상위 요약).

## 확인 필요

- `MemoryCore/v3-api-memorycore-doc.md`·`MemoryKnowledge/v3-api-memoryknowledge-doc.md`에 Skill 공유 "review" 상태 전이(예: draft→pending→active)와 리뷰어/승인 필드가 실제로 있는지.
- `task` visibility의 정확한 의미(Task에 묶인 에이전트만 접근?)와 README 4티어와의 관계.
- 팀 레벨 L3 Persona가 어떤 대화(어떤 visibility)로부터 합성되는지, private 대화가 팀/에이전트 메모리로 유입되지 않는 보장 로직.
- 자산 삭제/visibility 하향(revoke) 시 이미 다른 에이전트가 `借入`(차용)한 사본·파생 Skill 처리 방식.
- CHANGELOG 기준 Team Memory Beta 정확한 릴리스 날짜/버전(v2.0.0 vs v2.0.1-beta.1).
- PersonaMem 수치가 현행 Team Memory 구성에서 재측정된 것인지, 구버전 결과의 재게시인지.
