---
title: "Claude Managed Agents — Memory stores & Dreams"
vendor: Anthropic
urls:
  - https://docs.claude.com/en/docs/managed-agents/memory
  - https://claude.com/blog/claude-managed-agents-memory
  - https://docs.claude.com/en/docs/managed-agents/dreams
accessed: 2026-10-12
type: vendor-doc
read_status: "full (memory doc, dreams doc, launch blog 전문 web_extract로 읽음; 블로그 URL은 claude.com/resources/articles/...로 리다이렉트됨). self-hosted sandbox memory 페이지·API reference는 미독."
---

# Claude Managed Agents — Memory stores & Dreams

## 한 줄 요약

Memory store는 **workspace 범위의 텍스트 문서(파일) 컬렉션**으로, 세션 생성 시 `/mnt/memory/<slug>/`에 디렉터리로 마운트되고(`read_only`/`read_write`, 세션당 최대 8개), 모든 변경이 불변 `memory version`으로 남아 감사·롤백·redact가 가능하며, 비동기 **Dream** 작업이 기존 store + 과거 세션(1–100개)을 읽어 **새로운 정리된 출력 store**를 만든다(입력 불변).

## 객체 모델 / 범위(scope) 모델

- **Memory store** (`memstore_...`): "workspace-scoped collection of text documents optimized for Claude". 필드: `name`, `description`(에이전트에게 전달됨). 연산: create / retrieve / update / list(`include_archived`) / archive / delete.
- **Memory**: store 내에서 **path**로 주소 지정(예: `/preferences/formatting.md`). `content`, `content_sha256` 보유. API·Console에서 직접 읽기/편집 가능(튜닝·import·export).
- **Memory version** (`memver_...`): 모든 mutation마다 생성되는 불변 스냅샷. **store에 귀속**(개별 memory가 아님) → memory 삭제 후에도 버전 유지(보존 기간 내). `operation` 필드 있음, retrieve 시 전체 `content`.
- **세션 리소스**: `resources: [{type: "memory_store", memory_store_id, access, instructions}]`
  - `access`: 기본 `read_write`, `read_only` 지원.
  - `instructions`: 세션별 사용 지침, **최대 4,096자**.
  - 응답의 `mount_path` 필드를 사용하라고 명시(직접 slug 구성 금지).
- **한도**
  - 세션당 **최대 8개 store**.
  - store당 **10,000 memories** 한도 — 도달 시 새 memory 생성(API create 및 에이전트의 unmapped path 파일 쓰기) 실패, 기존 것은 읽기·편집 가능.
  - 버전 보존 **30일**(단, live memory의 최근 버전은 기간과 무관하게 유지).
- **범위 단위**: 범위 경계는 "store" 자체. 문서가 권장하는 매핑: 사용자별/팀별/프로젝트별 store 하나씩 + 공유 read-only 참조 store. ("one store per end user, per team, or per project, while sharing a single agent configuration")
- 여러 store를 붙이는 이유(문서): 공유 참조 자료(read-only), 제품 구조 매핑, 서로 다른 lifecycle.

## 쓰기 경로 / 읽기 경로 / 동시성

- **에이전트 경로**: store는 샌드박스 `/mnt/memory/<sanitized-name>/`에 마운트(이름 lowercase, 비영숫자 연속 → 하이픈 하나). 에이전트는 일반 agent toolset(파일 도구, bash)으로 읽고 씀 — agent toolset 활성화 필수. 마운트 설명(표시 이름, 경로, access 모드, description, instructions)이 시스템 프롬프트에 자동 삽입.
- mount path 아래 쓰기는 store로 persist되고 **같은 store를 공유하는 세션 간 동기화**. `/mnt/memory/` 다른 경로는 부모가 read-only 마운트라 실패.
- **부착 시점**: store는 **세션 생성 시에만** 부착 가능, 실행 중 추가/제거 불가.
- **Self-hosted sandbox**: live mount가 아니라 environment worker가 store를 다운로드해 동기화된 사본을 유지. self-hosted 환경은 `memory_store` 리소스만 허용.
- **관측성**: 에이전트의 읽기/쓰기는 이벤트 스트림에 일반 `agent.tool_use`/`agent.tool_result`로 나타남.
- **API 경로**: `memories.create`(덮어쓰지 않음), `update`(content/path rename), `delete`, `list`(`path_prefix`는 `/`로 끝나야 하고 세그먼트 단위 매칭, `depth` 0/생략=전체 서브트리, 1=직계 자식, 그 외 400), `retrieve`.
- **동시성**: `update`에 `precondition={"type":"content_sha256", ...}` → 해시 불일치 시 실패, 재읽기 후 재시도(낙관적 동시성). 블로그: "Multiple agents can work concurrently against the same store without overwriting each other."
  - 주의: 에이전트의 파일 도구 쓰기에 동일한 precondition이 적용되는지는 문서에 명시되지 않음.

## 권한·감사·삭제

- **접근 제어**: `access`는 **파일시스템 수준에서 강제** — `read_only` 마운트는 쓰기 거부, `read_write` 쓰기는 **세션에 귀속된(attributed to the session)** memory version 생성.
- **감사**: 버전 엔드포인트로 "who changed what and when" 확인, 스냅샷 조회. 블로그: "you can tell which agent and session a memory came from"; Console에 세션 이벤트로 노출.
- **롤백**: 전용 restore 엔드포인트 없음 → 원하는 version의 content를 `update`로 다시 씀(삭제된 memory는 `create`, 버전이 보존 중일 때).
- **Redact**: 과거 version의 content를 지우되 감사 흔적(누가/언제)은 유지. 용도: 유출된 secret, PII, 사용자 삭제 요청. **현재 head 버전은 redact 불가** → 새 버전 쓰기 또는 memory 삭제 후 redact.
- **보존**: 버전 30일 후 삭제될 수 있음 → 장기 보존은 API로 export.
- **Archive**: store를 read-only로 만들고 새 세션 부착 금지. **단방향(unarchive 없음)**.
- **Delete**: store + 모든 memories + versions 영구 삭제.
- 엔터프라이즈 포지셔닝(블로그): "scoped permissions, audit logs, and full programmatic control"; 예시 "an org-wide store might be read-only, while per-user stores allow reads and writes."
- 주의: 문서상 접근 제어 단위는 **세션의 마운트 모드 + workspace**. principal(사람/서비스 계정)별 store ACL은 이 문서에서 언급 없음.

## 정리(consolidation) 메커니즘 — Dreams

- 문제 정의: 에이전트 쓰기는 "local and incremental" → 중복·모순·stale 항목 누적.
- **Dream** (`drm_...`): 비동기 job. 입력 = 기존 memory store 1개 + **1–100개 세션** transcript. 출력 = **별도의 새 memory store**(`outputs` 배열; running 직후 입력 store를 clone한 뒤 나타남). 중복 병합, stale/모순 항목을 최신 값으로 교체, 새 인사이트 도출.
- **입력은 절대 수정·삭제되지 않음** → 출력 검토 후 채택(세션에 부착) 또는 폐기(delete/archive).
- `instructions`(최대 4,096자)로 합성 방향 지정; 특정 문장 수정 같은 국소 지시는 대개 효과 없음 → 개별 수정은 Memory Stores API로.
- 상태: `pending` → `running` → `completed` / `failed` / `canceled`. failed/canceled여도 출력 store는 부분 내용으로 남음. `session_id`로 파이프라인 세션 이벤트 스트리밍 가능, 종료 후 archive(삭제 아님).
- 지원 모델(research preview): claude-opus-5-5, claude-fable-5-1, claude-opus-5, claude-fable-5, claude-opus-4-8, claude-opus-4-7, claude-sonnet-5-5, claude-sonnet-5, claude-sonnet-4-6.
- 소요: 수 분~수 시간. 과금: 표준 토큰 단가, 세션 수·길이에 대략 선형.
- 오류 타입: `timeout`, `internal_error`, `memory_store_org_limit_exceeded`, `input_memory_store_too_large`, `input_memory_store_unavailable`, `input_session_unavailable`.
- Memory 문서의 best practice도 store가 꽉 차기 전 "Condense or prune", dream 출력 store로 세션 전환 후 원본 archive/delete를 권장.

## 문서가 명시한 보안 경고·권장사항

- "`access` is enforced at the filesystem level: a `read_only` mount rejects writes"
- "Limit write access where appropriate. Sessions that only read shared reference material don't need `read_write`."
- "Use focused stores." — 사용자별/공유 도메인 지식/프로젝트별로 분리(각각 10,000 한도).
- Redact 용도: "removing leaked secrets, PII, or user deletion requests."
- "Past memory versions might be deleted after 30 days. To preserve memory history for longer, export versions through the API."
- store가 범위를 넘어 커지면 새 store를 read_write로, 원본은 `read_only`로 부착.
- (주의) 이번에 읽은 페이지에는 프롬프트 인젝션/메모리 오염(poisoning)에 대한 명시적 경고 문구는 없음.

## 팀/조직 메모리 설계에 주는 시사점

- **범위 = store 단위, 권한 = 마운트 모드**: 조직 공용(read_only) + 팀(read_write, 소수 세션) + 개인(read_write) 3계층을 store 분리 + 세션당 최대 8개 부착으로 구현하는 것이 문서가 직접 제시한 패턴.
- 공유 store의 쓰기 권한을 좁히면 성장 출처 추적이 쉬워짐 → 팀 메모리는 "기록 담당" 세션/에이전트만 read_write로.
- 부착이 세션 생성 시점 고정이므로, **어떤 principal의 세션에 어떤 store를 붙일지**는 오케스트레이터(신뢰 코드)가 결정해야 함 — 모델이 범위를 고르지 않음.
- 불변 버전 + 세션 귀속 + redact 조합은 팀 메모리의 provenance·컴플라이언스(삭제 요청) 요구에 부합. 단 30일 보존 → 장기 감사는 export 파이프라인 필요.
- 정리는 **원본 비파괴 + 새 store 산출 + 사람/에이전트 검토 후 교체**(blue/green) 방식 → 공유 메모리에 대한 자동 정리의 위험을 낮추는 좋은 레퍼런스.
- 동시 쓰기는 `content_sha256` precondition 기반 낙관적 동시성 → 다중 에이전트 공유 store에서는 API 경로 쓰기에 precondition을 강제하는 것이 안전.

## 다른 플랫폼과 비교 포인트

- vs **Letta MemFS**: 둘 다 파일/경로 기반 + 버전 관리. Letta는 git commit/worktree/merge로 동시성, Anthropic은 서버 측 version + sha256 precondition. Letta 공유 repo는 org 소유, Anthropic은 workspace 범위 store.
- vs **AWS AgentCore**: AgentCore는 하나의 memory resource 내부를 namespace 계층으로 분할하고 IAM 조건 키로 강제; Anthropic은 store를 여러 개로 나누고 세션 마운트 모드로 강제(IAM 수준 namespace 정책 없음).
- vs **Databricks**: Databricks 신규 managed memory도 "store가 보안 경계"라고 명시(actor_id는 접근 제어 아님) — Anthropic의 "focused stores" 권장과 같은 결론. Databricks는 BM25 검색 API, Anthropic은 파일 도구 탐색.
- 정리: Anthropic Dreams(별도 출력 store, 비파괴) vs Letta dreaming/defrag(worktree에서 작업 후 merge, defrag 전 백업) vs AgentCore(namespace 내부 자동 consolidation, reflection은 namespace prefix 단위).

## 확인 필요

- 에이전트의 파일 도구 쓰기(동일 store를 공유하는 동시 세션)가 충돌 시 어떻게 처리되는지(last-writer-wins인지, sha256 precondition과 동등한 보호가 있는지) — 블로그는 "without overwriting each other"라고만 함.
- memory version 객체의 정확한 귀속 필드명(session id / API key / user 등) — API reference(memory_versions/list) 미독.
- workspace 내 principal(사용자/API key)별 store 접근 제어가 존재하는지 여부.
- 개별 memory의 크기 한도, store 크기 한도(Dream의 `input_memory_store_too_large` 기준값).
- Dream 출력 store에 원본의 version 이력/출처(어느 세션에서 유래했는지)가 이어지는지.
- self-hosted sandbox에서 동기화 주기·충돌 처리(별도 페이지 `self-hosted-sandboxes-memory` 미독).
