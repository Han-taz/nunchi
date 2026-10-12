---
title: "Databricks managed agent memory (current) + legacy Unity Catalog memory stores"
vendor: Databricks
urls:
  - https://learn.microsoft.com/en-us/azure/databricks/agents/agent-memory/managed-memory
  - https://docs.databricks.com/aws/en/agents/agent-memory/managed-memory
  - https://learn.microsoft.com/en-us/azure/databricks/agents/agent-memory/managed-memory-stores
  - https://learn.microsoft.com/en-us/azure/databricks/agents/agent-memory/memory-store-api
accessed: 2026-10-12
type: vendor-doc
read_status: "full (현행 managed-memory 페이지 Azure/AWS 판 동일 내용 확인, last updated 2026-10-06; legacy 개요 + legacy API reference 전문, last updated 2026-10-08). learn.microsoft.com/.../agent-memory/ 인덱스는 404. managed-sessions 및 현행 REST API reference 미독."
---

# Databricks managed agent memory

## 한 줄 요약

**중요: 작업 지시에 적힌 "Unity Catalog securable / scope" 모델은 현재 'legacy'로 표기되어 곧 종료(turned down soon) 예정**이며, 현행(Beta) managed agent memory는 **workspace-scoped memory store**(Lakebase 백엔드) 안의 entry를 `actor_id`/`session_id`/`path`로 분할하고 BM25 검색을 제공한다; 두 버전 모두 "범위 키(scope / actor_id)는 신뢰된 앱 코드가 정하고 **모델이 고르게 하지 말라**", "범위 키는 접근 제어가 아니다"를 명시한다.

## 객체 모델 / 범위(scope) 모델

### 현행 (Beta) — `/api/2.0/agents/memory-stores`

- **Memory store**: "workspace-scoped container for an agent's memories". 생성 시 Lakebase 스토리지 자동 프로비저닝. `display_name`으로 주소(3–56자, 소문자 시작, 문자/숫자로 끝, 소문자·숫자·하이픈) — **생성 후 불변**, `description`만 수정 가능.
- **Memory entry**: `content`(자유 텍스트), `description`(검색용 짧은 설명), `actor_id`(필수; 최종 사용자 또는 다른 에이전트), `session_id`(선택; 출처 추적용), `path`(필수; 예 `/preferences/response-style.md`). **고유 키 = (`actor_id`, `session_id`, `path`)**.
- **Scope 전략(actor_id)**
  - 사용자별 private: 검증된 end-user identity.
  - 그룹 공유: 팀·프로젝트·조직 ID 같은 고정 키 → "Everyone reads and writes the same memories."
  - 기타 분할: `{tenant}:{user}`, `user:project` 복합 키.
- SDK: `databricks-agentbricks`(AgentKit SDK, Python 3.10+), `AgentKitClient(WorkspaceClient())`, `memory_stores.create/add/search`, `grant_permission(principal_id)`.
- 과금: 프리뷰 기간 Lakebase 인스턴스 비용만.

### Legacy — Unity Catalog securable (`/api/2.1/unity-catalog/memory-stores`), 종료 예정

- **Memory store**: UC securable, 3단계 이름 `catalog.schema.memory_store_name`, `securable_type` = `MEMORY_STORE`, `owner`, `created_by`, `memory_store_id`(UUID). 이름 `[A-Za-z0-9_-]+` 1–255자. "inherits the same governance, access control, and lineage as any other Unity Catalog asset." 요구: UC 활성 workspace.
- **Memory entry**: `scope`(필수, 호출자 지정 파티션 키) + `path`(`/memories/`로 시작, 불변), `contents`, `description`, `has_contents`, `create_time`, `update_time`.
- **Scope 전략**: per-user(`user_client` 값이 end-user ID 자동 해석), 그룹 공유 고정 키, 복합 키. 한 에이전트가 한 요청에서 개인 scope + 팀 scope를 함께 읽을 수 있음.
- **Conversation**: OpenAI 호환 대화 상태를 memory store의 단일 scope(`scope.kind` = `user` | `user_defined`, `scope.value`)에 바인딩; metadata 최대 16 key(키 64자, 값 512자), 초기 items 최대 20.

## 쓰기 경로 / 읽기 경로 / 동시성

- **쓰기(현행)**: 앱/도구가 `add(actor_id, path, content, description)` 또는 `POST .../memory-stores/{name}/entries`. 권장 패턴: search/save를 프레임워크 tool로 감싸되 `actor_id`는 **클로저로 고정**(모델 인자로 노출하지 않음) — 문서 예시 `make_memory_tools(memory_store, actor_id)`.
- **읽기(현행)**: List(actor 단위, `session_id`/`path` prefix 필터) / Search(actor 단위 자연어 쿼리, **BM25 full-text**, top-N 최대 100, 페이지네이션·벡터 검색 없음). "Every list and search is scoped to a single `actor_id`."
- **Legacy 쓰기**: create(`?scope=`), update는 정확히 하나의 연산 `replace_all` | `str_replace`(정확히 1회 일치) | `insert`(`insert_line`, `insert_text`), delete. search는 path/content/description 키워드, `top_k` 기본 10·최대 50. list는 contents 생략(메타데이터만).
- **동시성**: 두 버전 모두 낙관적 잠금/ETag/precondition **언급 없음**. legacy `str_replace`의 "must match exactly once"가 유일한 암묵적 충돌 감지.

## 권한·감사·삭제

- **현행**: "Access control is enforced at the store level. Per-entry and per-actor access control are not available." 다른 principal(에이전트 service principal 등)은 store의 grant-permission 연산으로 접근 부여.
- **Legacy UC 권한**:

  | Privilege | 대상 | 의미 |
  |---|---|---|
  | `CREATE MEMORY STORE` | 부모 schema | store 생성 |
  | `READ MEMORY STORE` | store | 메타데이터·entry 읽기(get/list/search) |
  | `WRITE MEMORY STORE` | store | entry 생성·수정·삭제, conversation 쓰기 |
  | `MANAGE` | store | store 수정·삭제, 권한 부여 |
  | `USE SCHEMA` | 부모 schema | store 목록 |

  - List는 호출자가 읽을 수 있는 store만 필터링.
- **감사**: legacy 문서 — Databricks가 "the governed store, encryption, isolation primitives, and audit trail"을 제공. 현행 문서에는 감사/lineage 언급 없음. entry 버전 이력·redact 기능은 두 버전 모두 언급 없음(`update_time`만).
- **삭제**: legacy store 삭제 시 모든 entry 삭제(`MANAGE`). entry/conversation/item 단위 삭제 API 존재. 보존 정책 언급 없음.

## 정리(consolidation) 메커니즘

- 서버 측 자동 consolidation/dreaming/reflection **없음**(문서상). 정리는 시스템 프롬프트 지침에 의존.
- Legacy 문서의 `MEMORY_INSTRUCTIONS` 예시(managed-memory skill/템플릿): 저장 전 list로 기존 topic 찾기, "update_memory an existing topic instead of minting a near-duplicate", 모순되면 교체("rather than keeping both"), "delete_memory what's stale", 하나의 넓고 안정적인 `/memories/...` topic에 구체 내용, secrets·추측·대화 한정 정보 저장 금지, 저장/수정/삭제 시 사용자에게 알림.

## 문서가 명시한 보안 경고·권장사항

- 현행: "Set the `actor_id` in trusted application code from the verified end-user identity. **Never let the model choose whose memory to read or write.**"
- 현행: "If your strategy depends on an end-user identity, reject requests that don't carry one rather than falling back to a shared `actor_id`."
- 현행 Warning: "`actor_id` separates memories, but it is not an access control. Managed memory stores are workspace-scoped, so any principal that can reach a store can read and write every entry across all actors. **The store, not the actor, is the security boundary.** For strict isolation between tenants or users, create a separate memory store per boundary."
- Legacy: scope는 OBO 토큰의 검증된 사용자 identity 등 "trusted caller context that the request can't tamper with"에서 설정; "Scope is the isolation boundary between users, but it is not an access control. The app service principal can read every scope, so protect its credential accordingly."
- Legacy 보안 권장: per-user scope 기본(`user_client`); 최소 권한 — service principal만 `WRITE MEMORY STORE`, `READ`는 좁게, 사람/대규모 그룹 광범위 부여 회피; SP 자격증명을 고가치 자격증명으로(단기 토큰, 로그 금지, **SSRF 방어**).
- Legacy 프롬프트 지침: 비밀정보(secrets) 저장 금지.

## 팀/조직 메모리 설계에 주는 시사점

- **"범위 키 ≠ 접근 제어"**: 같은 store 안의 팀/개인 파티션 분리는 논리적 분리일 뿐, 강한 격리가 필요하면 **경계마다 store를 분리**하고 store 권한으로 강제.
- **모델이 범위를 고르지 않게**: 범위(actor/scope)는 인증된 호출 컨텍스트에서 앱이 바인딩하고, 도구 시그니처에서 제거 — 팀 메모리 도구 설계의 핵심 규칙.
- **fail-closed**: 사용자 identity가 없으면 공유 범위로 폴백하지 말고 거부.
- 서비스 principal이 모든 파티션을 읽을 수 있는 구조 → 팀 메모리 서버의 자격증명이 최고 위험 자산(SSRF 등 방어).
- 한 요청에서 개인 + 팀 범위를 함께 읽는 **다중 범위 읽기**를 명시적으로 지원(legacy) — 개인/팀/조직 계층 조합의 근거.
- 거버넌스(UC 권한·lineage) 통합 모델이 legacy로 밀려난 점은 시사적: 현행은 단순 workspace store + store 단위 grant로 회귀 → 세밀 권한은 store 분할로 해결하는 방향.

## 다른 플랫폼과 비교 포인트

- "store = 보안 경계" 결론은 Anthropic의 focused stores/세션별 마운트와 같음; AWS는 반대로 단일 resource 내 namespace + IAM 조건 키로 세밀 격리 가능.
- entry 모델(`actor_id`/`session_id`/`path` + description)은 Anthropic memory(path + content)와 AWS namespace(actor/session 계층)의 중간 형태.
- 버전/redact/감사 이력: Anthropic(명시적 memory version, redact) ≫ Letta(git) > Databricks/AWS(문서상 없음; legacy는 "audit trail" 언급만).
- 정리 자동화 없음 — Anthropic Dreams, Letta dreaming, AWS consolidation/reflection과 대비. 프롬프트 지침 기반 수동 정리.
- 검색: Databricks BM25(벡터 없음), AWS semantic retrieval, Anthropic/Letta 파일 탐색(+ Letta 선택형 검색 mod).

## 확인 필요

- 현행 managed memory store가 Unity Catalog securable인지 여부(현행 문서는 "workspace-scoped"만 언급, UC 언급 없음)와 grant-permission이 부여하는 권한 수준(read/write 구분 가능 여부).
- 현행 버전의 감사 로그(system tables/audit log) 및 lineage 지원.
- legacy 종료 일정과 legacy → 현행 마이그레이션 경로(scope → actor_id 매핑).
- 현행 REST API의 update 연산 형태(legacy의 str_replace/insert/replace_all 유지 여부)와 동시성 제어.
- entry 크기·개수 한도, 보존/TTL 정책.
- 현행에서 legacy의 `user_client`처럼 OBO 토큰으로 actor_id를 서버가 자동 해석하는 기능이 있는지.
