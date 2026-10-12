---
title: "Zep: A Temporal Knowledge Graph Architecture for Agent Memory (arXiv 2501.13956) + Graphiti"
source_owner: "Zep AI (Rasmussen, Paliychuk, Beauvais, Ryan, Chalef) / getzep/graphiti"
urls:
  - https://arxiv.org/abs/2501.13956
  - https://arxiv.org/html/2501.13956
  - https://github.com/getzep/graphiti
accessed: 2026-10-12
type: "벤더 저자 기술 논문(arXiv preprint v1, 2025-01-20, 비동료심사) + 오픈소스 README"
read_status: "arXiv HTML 본문 전체(부록 프롬프트 포함) 읽음 — 단 HTML 변환상 §2.2.2 Facts 첫 문장 일부 누락. Graphiti README 주요 섹션(개념·Zep vs Graphiti·GraphRAG 비교·백엔드·MCP) 읽음. Graphiti 코드, mcp_server README, 이후 논문 버전(v2+) 미확인."
---

# Zep / Graphiti — 시간형(bi-temporal) 지식그래프 메모리

## 한 줄 요약

Zep은 원본 에피소드(비손실) → 의미 엔티티/사실 → 커뮤니티의 3계층 그래프에, 사실(edge)마다 **4개 타임스탬프(t'_created, t'_expired / t_valid, t_invalid)** 를 붙이고 LLM으로 모순을 탐지해 **삭제 대신 무효화**하는 시간형 지식그래프(엔진: Graphiti)로, DMR 94.8%(vs MemGPT 93.4%), LongMemEval 최대 +18.5%·지연 약 90% 감소를 보고한다(벤더 자체 평가).

## 핵심 설계/주장

### 그래프 정의: G = (N, E, φ), 3계층 서브그래프

| 서브그래프 | 노드 | 엣지 | 역할 |
|---|---|---|---|
| **Episode subgraph G_e** | episode: 원시 입력(message / text / JSON) | episodic edge: episode → 참조된 semantic entity | 비손실 원본 저장소, 추출의 근거 |
| **Semantic entity subgraph G_s** | entity: 추출·해소(resolve)된 엔티티 | entity(semantic) edge: 엔티티 간 관계 = **fact** | 의미 기억 |
| **Community subgraph G_c** | community: 강하게 연결된 엔티티 클러스터 + 요약 | community edge: community → 멤버 엔티티 | 상위 요약/전역 이해 |

- 심리학의 episodic vs semantic memory 구분을 차용, AriGraph·GraphRAG에서 영향.
- episode ↔ 파생 semantic edge 간 **양방향 인덱스**: 사실을 출처로 역추적(인용), episode에서 관련 사실 조회. (논문은 이 기능을 실험하지 않았다고 명시)

### Episode 처리

- message는 짧은 텍스트 + 발화자(actor) + **reference timestamp t_ref**(전송 시각). t_ref로 "next Thursday", "two weeks ago" 같은 상대 시간을 절대화.
- **Bi-temporal 모델**: 타임라인 **T** = 사건의 실제 시간 순서, **T'** = Zep 데이터 수집(트랜잭션) 순서. T'는 DB 감사용, T는 대화 데이터의 동적 특성 모델링용.

### 엔티티 추출·해소

- 현재 메시지 + 직전 n=4 메시지(2턴)를 컨텍스트로 NER. 발화자는 자동으로 엔티티. reflexion 영감의 reflection으로 환각 감소·커버리지 향상. 엔티티 요약 생성.
- 엔티티 이름을 1024차원 임베딩 → cosine 후보 + 이름/요약 full-text 후보 → LLM 엔티티 해소 프롬프트로 중복 판정, 중복 시 이름·요약 갱신.
- 그래프 쓰기는 LLM 생성 쿼리가 아니라 **사전 정의된 Cypher 쿼리**로(스키마 일관성·환각 방지).

### 사실(fact) 추출·중복 제거

- 사실은 key predicate(관계 타입, 예: LOVES, WORKS_FOR)와 상세 fact 텍스트. 같은 사실을 여러 엔티티 쌍에 추출해 **hyper-edge** 구현.
- 사실 임베딩 후 중복 제거 — 하이브리드 검색을 **같은 엔티티 쌍 사이의 엣지로 제한**(오결합 방지 + 탐색공간 축소).

### 시간 추출과 엣지 무효화 (핵심)

- 엣지마다 4개 타임스탬프:
  - `t'_created`, `t'_expired` ∈ T' — 시스템에 사실이 생성/무효화된 시점
  - `t_valid`, `t_invalid` ∈ T — 사실이 실제로 참이었던 기간
- 새 엣지가 들어오면 LLM이 의미적으로 관련된 기존 엣지와 비교해 모순 탐지. **시간적으로 겹치는 모순**이면 기존 엣지의 `t_invalid`를 새 엣지의 `t_valid`로 설정.
- "Following the transactional timeline T′, Graphiti consistently prioritizes new information when determining edge invalidation." → **최신 우선(last-write-wins on T')** 규칙.
- 시간 추출 프롬프트 규칙: ISO 8601, 현재형이면 t_ref를 valid_at으로, 관계 자체의 형성/변경과 직접 관련된 날짜만, 관련 이벤트에서 추론 금지, 날짜만 있으면 00:00:00, 연도만 있으면 1월 1일, 타임존 미상이면 Z.

### 커뮤니티

- GraphRAG 방식 기반이나 Leiden 대신 **label propagation** — 동적 확장이 쉬움. 새 엔티티는 이웃 다수의 커뮤니티에 배정 후 요약 갱신(재귀 1단계). 점점 전체 재계산 결과와 괴리되므로 **주기적 refresh 필요**.
- 커뮤니티 요약은 map-reduce식 반복 요약, 핵심어를 담은 community name을 임베딩해 검색.

### 검색 파이프라인 f(α) = χ(ρ(φ(α))) = β

- **Search φ**: cosine semantic(φ_cos), Okapi BM25(φ_bm25; 둘 다 Neo4j의 Lucene 구현), breadth-first search(φ_bfs; n-hop 확장, 최근 episode를 seed로 사용 가능). 검색 필드: 엣지=fact, 엔티티=name, 커뮤니티=community name. 결과는 (semantic edges, entity nodes, community nodes) 3-튜플.
- **Reranker ρ**: RRF, MMR, episode-mentions reranker(대화에서 자주 언급된 사실 우선), node distance reranker(지정 centroid 노드로부터의 그래프 거리), cross-encoder(가장 비쌈).
- **Constructor χ**: edge → fact + t_valid/t_invalid, entity → name + summary, community → summary. 컨텍스트 템플릿: `FACT (Date range: from - to)` 형식의 `<FACTS>`와 `<ENTITIES>`.

### Graphiti README (현행)

- "context graph" = 엔티티·관계·사실의 시간형 그래프, 각 사실에 validity window, 모든 것이 episode로 추적. 구성: Entities(진화하는 요약), Facts/Relationships(triplet + validity window), Episodes(provenance, "ground truth stream"), Custom Types(Pydantic 기반 prescribed ontology; learned ontology도 지원).
- "When information changes, old facts are invalidated — not deleted. Query what's true now, or what was true at any point in time."
- 증분 구성(배치 재계산 없음), 하이브리드 검색(임베딩+BM25+그래프 탐색, LLM 요약 비의존).
- 백엔드: Neo4j 5.26 / FalkorDB 1.1.2 / Amazon Neptune(+OpenSearch Serverless) / Kuzu 0.11.2(**deprecated**).
- Zep(상용) vs Graphiti(OSS): Zep은 "Manages vast numbers of per-user/entity context graphs with governance", 독자 Context Graph Engine, "sub-200ms" 검색, 사용자/스레드 관리, SLA. Graphiti는 개별 그래프 구축·질의, self-host.
- GraphRAG 비교(README 자체 표): 배치 vs 증분, "Explicit bi-temporal tracking with automatic fact invalidation", 질의 지연 "Typically sub-second" vs "Seconds to tens of seconds".
- MCP 서버: episode 관리(add/retrieve/delete), 엔티티·관계, 의미/하이브리드 검색, **group management**(관련 데이터 조직), 그래프 유지보수.

## 근거 (모두 vendor-reported, 저자 = Zep 직원)

- 실험 설정: 임베딩·리랭킹 BGE-m3, 그래프 구성 gpt-4o-mini-2024-07-18, 응답 gpt-4o-mini / gpt-4o-2024-11-20, DMR 비교용 gpt-4-turbo-2024-04-09. 상위 20개 edge/entity 검색(LME), DMR은 top 10.
- **DMR**(500 대화, 각 5세션·세션당 최대 12메시지):
  - gpt-4-turbo: Recursive Summarization† 35.3%, Conversation Summaries 78.6%, MemGPT† 93.4%, Full-conversation 94.4%, **Zep 94.8%**
  - gpt-4o-mini: Conversation Summaries 88.0%, Full-conversation 98.0%, **Zep 98.2%** (†MemGPT 논문 보고치)
  - 저자 스스로: 대화당 60메시지라 컨텍스트에 다 들어가며, DMR은 단일 턴 사실 검색·모호한 질문 등으로 "inadequate"하다고 평가.
- **LongMemEval_s**(평균 약 115k 토큰, GPT-4o judge):

  | Memory | Model | Score | Latency | IQR | Avg ctx tokens |
  |---|---|---|---|---|---|
  | Full-context | gpt-4o-mini | 55.4% | 31.3 s | 8.76 s | 115k |
  | Zep | gpt-4o-mini | 63.8% | 3.20 s | 1.31 s | 1.6k |
  | Full-context | gpt-4o | 60.2% | 28.9 s | 6.01 s | 115k |
  | Zep | gpt-4o | 71.2% | 2.58 s | 0.684 s | 1.6k |

  - 개선율(상대): gpt-4o-mini +15.2%, gpt-4o +18.5%; 지연 약 90% 감소.
  - 질문 유형별(gpt-4o): single-session-preference 20.0→56.7%(+184%), temporal-reasoning 45.1→62.4%(+38.4%), multi-session 44.3→57.9%(+30.7%), knowledge-update 78.2→83.3%(+6.52%), single-session-user 81.4→92.9%(+14.1%), **single-session-assistant 94.6→80.4%(−17.7%)**.
  - gpt-4o-mini: knowledge-update 76.9→74.4%(−3.36%), single-session-assistant 81.8→75.0%(−9.06%).
- 측정 환경: 2024-12~2025-01, 보스턴 가정용 노트북 → AWS us-west-2 Zep 서비스(baseline에는 없는 네트워크 지연 포함).
- MemGPT는 LongMemEval에서 기존 히스토리 직접 수집 미지원으로 평가 실패(저자 보고).

## 비판·한계

### 출처 자체가 밝힌 한계

- DMR 개선폭은 미미하고 benchmark 자체가 부적절(저자 인정).
- single-session-assistant 하락, 약한 모델에서 knowledge-update 하락 → "less capable models' understanding of Zep's temporal data" 개선 필요.
- 커뮤니티 동적 갱신은 근사 → 주기적 전체 refresh 필요.
- 구조화 비즈니스 데이터와 대화 결합 능력을 평가할 벤치마크 부재; 출처 역추적(양방향 인덱스)은 실험되지 않음.
- 형식 온톨로지 없이 LLM 생성 그래프 — 도메인 온톨로지는 향후 과제(현행 Graphiti는 Pydantic custom types로 일부 해소).

### 자체 평가

- **"최신 정보 우선" 무효화는 단일 사용자 대화에는 타당하지만 다중 주체 조직에는 위험**: 권한·신뢰도가 낮은 주체(또는 오염된 에이전트)의 최신 진술이 정본 사실을 무효화할 수 있다. 출처 신뢰도/권한 기반 우선순위, 사람 승인 게이트가 필요.
- **LLM 모순 판정 의존**: 모순 탐지 정확도, 오탐(정상 사실을 무효화)·미탐 비율이 보고되지 않음. 무효화는 비손실이라 복구 가능하나 누가 언제 복구하는지 워크플로 없음.
- **ACL/멀티테넌시가 논문 범위 밖**: 논문에는 권한 모델이 없고, README의 "group management"·Zep의 "governance"는 상세 미기술. 팀 메모리로 쓰려면 그룹(네임스페이스) 경계와 엣지 단위 가시성을 별도로 설계해야 한다.
- 벤치 비교 대상이 full-context와 요약 baseline뿐(다른 메모리 시스템과의 LME 비교 없음), 저자=벤더, 단일 실행 수치로 분산/신뢰구간 없음.
- "valid time"은 LLM이 대화에서 추출한 값이므로 오류 가능 — T(현실 시간)의 정확도는 추출 품질에 종속.

## 팀/조직 메모리 설계에 주는 시사점

- **4-타임스탬프(bi-temporal) 엣지**는 조직 메모리의 "정정·만료" 문제에 대한 가장 구체적인 레퍼런스: "언제 참이었나(t_valid/t_invalid)"와 "시스템이 언제 알게/폐기했나(t'_created/t'_expired)"를 분리하면 감사("그 시점에 에이전트가 무엇을 믿었나")가 가능.
- **삭제 대신 무효화 + 원본 episode 보존**: 잘못된 공유 기억을 철회해도 이력·근거가 남아 재현·감사 가능. Tencent/Asana의 "삭제" 중심 정정과 대비.
- **무효화 정책을 주체 인지형으로 확장**: "T' 최신 우선" 대신 (출처 권한, 소유자, 신뢰도, 승인 여부)를 고려한 conflict policy와, 고위험 사실은 사람 승인 후 무효화.
- **출처 양방향 링크**(fact ↔ episode)는 권한 상속(Asana식)의 기술적 기반 — 사실의 가시성을 원천 episode의 가시성에서 파생시킬 수 있다.
- **사전 정의 Cypher/스키마 쓰기**(LLM이 쿼리를 생성하지 않음)는 공유 저장소 무결성 보호에 유효.
- 회상 출력에 유효기간을 함께 넣는 컨텍스트 템플릿(`FACT (Date range)`)은 에이전트가 낡은 사실을 스스로 할인하게 하는 간단한 장치.

## 다른 개념과의 연결

- **Tencent Team Memory**: 계층(L0 원본→L3 persona) 구조는 유사하나 시간 유효성·무효화가 없음 → Zep 모델로 보완 가능.
- **Context graphs / decision traces**: Graphiti README가 스스로를 "temporal context graph"라 부름. 단 Zep의 context graph는 **사실의 시간 이력**이고, Foundation Capital/ContextOS의 context graph는 **결정의 근거(lineage)** — ContextOS는 edge에 event time·valid time·provenance를 요구해 Zep 시간 모델과 맞물림(→ context-graphs-decision-traces.md).
- **Neo4j agent-memory**: 같은 Neo4j 생태계, long-term memory(POLE+O 엔티티)와 유사하나 Neo4j 쪽은 reasoning trace 계층 추가.
- **GraphRAG / LightRAG / AriGraph / MemGPT**: 직접 비교·차용 대상.
- **Asana**: Memory Association(메모리→Work Graph 객체)은 Zep의 episodic edge(사실→원본)와 기능적으로 대응.

## 확인 필요

- arXiv 이후 버전(v2 이상) 존재 여부와 수치 변경, 실험 노트북 공개 위치.
- Graphiti 코드에서 `group_id`(그룹/네임스페이스) 구현 방식과 그룹 간 격리 수준(쿼리 레벨 필터인지 DB 분리인지).
- 엣지 무효화 시 사람 승인/수동 override API 존재 여부, 무효화된 엣지의 복구 API.
- Zep 상용판 "governance"의 구체 기능(권한, 감사 로그, 보존 정책).
- 모순 탐지 정확도에 대한 독립 평가(제3자 재현) 존재 여부.
- §2.2.2 Facts 원문 첫 문장(HTML 변환 누락분) — PDF로 확인.
