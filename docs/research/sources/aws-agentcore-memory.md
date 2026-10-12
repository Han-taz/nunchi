---
title: "Amazon Bedrock AgentCore Memory — namespaces, custom variables, IAM, episodic/reflection"
vendor: AWS
urls:
  - https://aws.amazon.com/blogs/machine-learning/organizing-agents-memory-at-scale-namespace-design-patterns-in-agentcore-memory/
  - https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/specify-long-term-memory-organization.html
  - https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/episodic-memory-strategy.html
accessed: 2026-10-12
type: vendor-doc
read_status: "full (블로그 — 'September 2026: reviewed and updated' — 및 dev guide 2개 페이지 전문 web_extract). 블로그 그림 내용, IAM condition key 레퍼런스 페이지, metadata 페이지, episodic system prompt 페이지는 미독."
---

# Amazon Bedrock AgentCore Memory

## 한 줄 요약

AgentCore Memory는 하나의 **memory resource** 안에서 strategy(semantic, user preference, summary, episodic)가 대화 event에서 장기 memory record를 추출해 **계층형 namespace**(`/actor/{actorId}/...`)에 저장하고, `namespace`(정확 일치)/`namespacePath`(서브트리) 검색과 **IAM 조건 키**(`bedrock-agentcore:namespace`, `:namespacePath`, `:namespaceVariable/<key>`)로 범위를 강제하며, **custom namespace variables**(`namespaceKeys`)로 tenant/org/team 계층을 단일 resource에서 표현한다.

## 객체 모델 / 범위(scope) 모델

- **Memory resource**: control plane(`bedrock-agentcore-control`)의 `create_memory(name, description, eventExpiryDuration, memoryStrategies, namespaceKeys)`. 데이터 평면은 `bedrock-agentcore` 클라이언트(`CreateEvent`, `RetrieveMemoryRecords`, `ListMemoryRecords`, `GetMemoryRecord`, `DeleteMemoryRecord`).
- **Event (short-term)**: `CreateEvent(memoryId, actorId, sessionId, payload, extractionConfig)`; `eventExpiryDuration`(예시 30, 10 — 단위는 문서 예시상 일로 보이나 이번 페이지에 명시 없음).
- **Memory strategy** → 각자 `namespaceTemplates`. 블로그 권장:
  - Semantic(facts), UserPreference: actor 범위 `/actor/{actorId}/facts/`, `/actor/{actorId}/preferences/` (세션 간 누적).
  - Summary: 세션 범위 `/actor/{actorId}/session/{sessionId}/summary/`.
  - Episodic: episodes `/actor/{actorId}/session/{sessionId}/episodes/`, reflections `/actor/{actorId}/` (reflection namespace는 episode namespace의 **prefix**여야 함).
  - cross-actor 조회가 주 패턴이면 `/facts/{actorId}/`처럼 actor를 타입 아래에 두되, "everything about customer-123" 서브트리가 사라지고 IAM 문장이 타입별로 늘어나는 trade-off.
- **Built-in 변수**: `{actorId}`, `{sessionId}`, `{memoryStrategyId}`(dev guide에서는 strategyId라고도 표기). dev guide 예시 granularity: 세션 / actor across sessions / strategy across actors / 전역 `/`.
- **Actor**: "entity such as end users or agent/user combinations".
- **Custom namespace variables** (`namespaceKeys`):
  - resource당 최대 **5개 key**, template당 최대 **5개 custom 변수**.
  - key: 소문자 영숫자만, 최대 **32자**, built-in 이름 재사용 불가.
  - 값: 소문자, 최대 **64자**(블로그).
  - validation: `allowedValues`(최대 **10개**, 소문자 영숫자·`-`·`_`) 및/또는 `regexPattern`(최대 **64자**) — 둘 다 지정 시 AND.
  - 미참조 key 사전 등록 가능, 한 key를 여러 strategy가 참조 가능, **참조 중인 key는 삭제 불가**(template에서 먼저 제거).
  - 예: `/org/{orgname}/team/{teamname}/actor/{actorId}/session/{sessionId}/`, 블로그의 `/tenant/{tenant}/service/{service}/component/{component}/team/{team}/actor/{actorId}/facts/`.
  - 값 공급: `CreateEvent`의 `extractionConfig.namespaceVariables`. **쓰기 경로에만 영향** — 읽기 시 namespace는 이미 resolve됨.
- **Namespace vs metadata**: namespace = "where a memory lives"(보안 경계, record는 정확히 하나의 namespace), metadata = "what a memory is about"(검색 필터). "metadata is the wrong tool for tenant isolation."

## 쓰기 경로 / 읽기 경로 / 동시성

- **쓰기**: 앱이 `CreateEvent`로 대화 이벤트 기록 → 서비스가 strategy별로 비동기 추출·consolidation·(episodic) reflection 수행 → resolve된 namespace에 record 저장. 에이전트가 record를 직접 쓰는 구조가 아님(이번 문서 기준).
- **Namespace resolution 실패**: template이 참조하는 custom 변수가 요청에 없으면 해당 strategy의 장기 추출이 **조용히 skip**되고 `CreateEvent`는 성공(단기 메모리엔 저장). `NamespaceResolutionFailure` 메트릭(차원 `Operation`, `Resource`, `StrategyType`, `StrategyId`)으로 감지, vended logs 설정 필요.
- **Validation 실패**: 잘못된 값은 `CreateEvent`가 거부(즉시 발견). 여러 validation 중 하나라도 실패하면 전체 요청 실패.
- **읽기**: `RetrieveMemoryRecords`(semantic, `searchCriteria{searchQuery, topK}`), `ListMemoryRecords`(열거/감사), `GetMemoryRecord`/`DeleteMemoryRecord`(단건).
  - `namespace` = **exact match**, `namespacePath` = **hierarchical(서브트리)**. "the level you start from is the level you're trusting the caller with."
  - 선행·후행 슬래시 필수: 없으면 `/actor/customer-1`이 `/actor/customer-12/`도 매칭.
  - 모호한 사용자 입력은 LLM이 검색 쿼리를 재구성(추가 모델 호출 지연).
- **UpdateMemory**: `namespaceKeys`는 **전체 교체**(merge 아님) → GetMemory → 수정 → 전체 목록 제출(read-modify-write). 참조 중인 key 누락 시 `ValidationException`.
- **동시성**: 다수 클라이언트의 동시 event 기록·consolidation 충돌 처리에 대한 설명은 이번 문서에 없음(서비스 내부 처리).

## 권한·감사·삭제

- **IAM 읽기**: `StringEquals` + `bedrock-agentcore:namespace` = `/actor/${aws:PrincipalTag/userId}/preferences/`(principal tag는 인증 시 주입); 계층 접근은 `StringLike` + `bedrock-agentcore:namespacePath` = `/actor/${aws:PrincipalTag/userId}/*`. 대상 Action: `RetrieveMemoryRecords`, `ListMemoryRecords`.
- **IAM 쓰기**: `bedrock-agentcore:namespaceVariable/<variableName>` — 예: `CreateEvent`에 `"bedrock-agentcore:namespaceVariable/tenant": "${aws:PrincipalTag/tenant}"` → 손상된 클라이언트가 다른 tenant 값을 보내도 거부.
  - 정책이 조건으로 거는 변수를 요청이 생략하면 조건 키가 없어 Allow 불일치 → **거부**(다른 문장이 허용하지 않는 한). 즉 해당 변수가 사실상 필수가 됨 → 롤아웃 전 클라이언트 준비.
- prefix 기반 IAM은 계층 순서를 상속 → tenant-first 계층이 보안상 유리.
- **삭제**: `DeleteMemoryRecord`(단건) — 사용자의 보기/정정/삭제 워크플로. `eventExpiryDuration`으로 이벤트 만료.
- **감사/버전/redaction**: record 버전 이력·redact 기능은 이번 문서에 언급 없음. `ListMemoryRecords`가 "auditing what exists" 용도로 언급될 뿐.

## 정리(consolidation) 메커니즘

- "The consolidation engine merges related memories within the same namespace, so **the namespace boundary is also the consolidation boundary**." → namespace 설계가 곧 병합 범위 설계.
- **Episodic strategy** 단계: Extraction(진행 중 episode 분석, 완료 여부 판단) → Consolidation(완료 episode를 하나로 결합) → **Reflection**(episode 간 인사이트). 출력은 XML; episode는 situation, intent, assessment, justification, episode-level reflection으로 분해. episode는 **항상 단일 세션**에서 생성. episode는 "intent", reflection은 "use case" 기준으로 인덱싱. episode 완료가 감지되어야 record가 생성되므로 다른 strategy보다 늦음.
- Reflection namespace는 episode namespace와 같은 패턴이되 덜 중첩 가능: actor 수준 → actor의 모든 episode에서; strategy 수준 → **모든 actor에 걸친** 인사이트.

## 문서가 명시한 보안 경고·권장사항

- 블로그 서두: namespace 설계를 잘못하면 "one user's memories leak into another's conversation."
- Reflection cross-actor(dev guide, Important): "Because reflections can span multiple actors within the same memory resource, consider the privacy implications of cross-actor analysis when retrieving reflections. Consider using guardrails in conjunction with memory or reflecting at the actor level if this is a concern."
- 블로그: reflection을 `/`까지 잘라내면 "insights derived from one customer's interactions become retrievable in every other customer's context. Do that only when episodes contain nothing customer-specific."
- 복합 키 안티패턴: `actorId`에 `octank:payments:dev-123`을 넣으면 cross-session consolidation이 깨지고 사용자 기반 IAM 정책과 어긋남. tenant 하드코딩 template은 고객마다 resource/strategy 필요.
- "Set validation even when it feels redundant" — tenant 격리 버그는 요청 시점 앱 코드(stale 변수, 잘못된 env)에서 발생.
- "Put the broadest isolation boundary at the top." / "Add a level only if you'll actually query or isolate at it."
- "If getting it wrong would be a security finding, it belongs in the namespace."
- `NamespaceResolutionFailure` 알람 권장.

## 팀/조직 메모리 설계에 주는 시사점

- **경계 계층을 경로 최상단부터**: `/org/{org}/team/{team}/actor/{actorId}/...` 순서로 두면 `namespacePath` 쿼리와 prefix IAM이 구조적으로 tenant/팀 밖으로 못 나감.
- **쓰기 경로도 권한 대상**: 팀 값(namespace variable)을 principal tag와 IAM으로 묶어 "자기 팀에만 쓰기"를 강제 — 다른 플랫폼에서 흔히 빠지는 write-side 범위 검증의 좋은 레퍼런스.
- **consolidation 경계 = namespace 경계**: 팀 공유 지식을 원하면 팀 수준 namespace를 따로 두고, 개인 사실은 actor 수준에 둬야 섞이지 않음.
- **집계형 인사이트(reflection)는 프라이버시 경계를 넘는다**: 팀/조직 수준 reflection은 개인 데이터가 없는 경우에만, 아니면 actor 수준 + guardrails.
- **조용한 실패 모니터링**: 범위 변수 누락 시 장기 메모리가 쌓이지 않는 silent failure → 범위 해석 실패를 메트릭/알람으로 다뤄야 함.
- 범위 값은 신뢰된 앱 코드/인증 컨텍스트에서 주입(principal tag) — 모델이 namespace를 고르게 하지 않는 원칙과 일치.

## 다른 플랫폼과 비교 포인트

- 4개 중 유일하게 **namespace 단위 IAM 정책(읽기+쓰기)** 으로 단일 resource 내 세밀 격리를 지원. Databricks 신규 버전은 "actor_id는 접근 제어 아님, store가 경계", Anthropic은 store 분리 + 마운트 모드, Letta는 attach 단위.
- 메모리 생성이 **서버 측 LLM 추출 파이프라인**(event → record) — Anthropic/Letta는 에이전트가 파일을 직접 씀, Databricks는 앱/도구가 entry를 직접 add.
- 버전/redact 이력은 문서상 없음 → Anthropic(memory version + redact), Letta(git 이력) 대비 감사 기능이 약하게 문서화됨.
- Reflection(cross-episode)은 Anthropic Dreams / Letta dreaming과 유사한 "상위 정리"지만 namespace prefix 규칙으로 범위가 정해짐.

## 확인 필요

- memory record의 버전 이력·수정 이력·출처(어느 event/세션에서 추출) 필드 존재 여부와 보존 기간.
- `eventExpiryDuration` 단위·범위, 장기 record의 TTL/보존 정책.
- `DeleteMemoryRecord`/`CreateEvent`/`GetMemoryRecord`에 대해서도 namespace 조건 키가 적용되는지(블로그 예시는 Retrieve/List 및 CreateEvent만).
- 같은 namespace에 동시 다발 event가 들어올 때 consolidation의 일관성/충돌 처리.
- 팀 공유 memory(여러 actor가 기여하는 팀 namespace)를 built-in strategy로 만들 수 있는지 — template이 항상 `{actorId}`를 포함해야 하는지 여부(예시 `/` 및 `/strategy/{memoryStrategyId}/`는 actor 없음).
- guardrails 연동의 구체 동작(링크된 GitHub 샘플 미독).
