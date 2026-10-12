---
title: "Collaborative Memory: Multi-User Memory Sharing in LLM Agents with Dynamic Access Control"
arxiv_id: "2505.18279"
authors: "Alireza Rezazadeh, Zichao Li, Ange Lou, Yuying Zhao, Wei Wei, Yujia Bao"
affiliation: "Center for Advanced AI, Accenture"
date: "2025-05-23 (v1, cs.MA)"
venue: "ICML 2025로 전달받았으나 읽은 arXiv v1 본문에는 학회 표기가 없음 (확인 필요)"
url: "https://arxiv.org/abs/2505.18279"
html: "https://arxiv.org/html/2505.18279"
type: paper
read_status: full
read_note: "arXiv HTML v1 본문 §1–7 + 부록 A–E 전체 읽음. Fig.3–6/8/10/11의 플롯 수치는 이미지라 읽지 못함 — Scenario 1/2의 정량값은 본문 텍스트에 나온 것만 기재, Scenario 3은 부록 Table 19 원자료 사용."
---

# Collaborative Memory (Accenture, 2505.18279)

## 한 줄 요약

여러 사용자가 여러 에이전트를, 에이전트가 여러 리소스를 쓰는 환경에서 **시간에 따라 바뀌는 user→agent, agent→resource 이분 그래프**로 권한을 표현하고, 각 메모리 fragment에 **불변 provenance(생성 시각·기여 사용자·기여 에이전트·접근 리소스)**를 붙여 **읽기 시점의 현재 권한으로 재검사**하는 private/shared 2-tier 메모리 프레임워크.

## 문제 정의

- §1: MemGPT/MemTree/GraphRAG 등은 단일 사용자·단일 에이전트·전역 가시 메모리 가정. 협업형 엔터프라이즈 비서, 다중 사용자 생산성 플랫폼, 분산 워크플로에서는 사용자 간 메모리 공유가 중복 질의를 줄이지만 두 난제:
  1. **Information asymmetry** — 사용자마다 쓸 수 있는 에이전트가, 에이전트마다 쓸 수 있는 리소스가 다름 → 메모리가 이 비대칭을 집행해야.
  2. **Dynamic access patterns** — 역할 변경·정책·태스크에 따라 권한 부여/철회.
- §2: Memory Sharing(Gao & Zhang 2024)은 공용 풀이지만 사용자 수준 프라이버시/접근 제약 무시. RBAC/ABAC는 성숙했지만 provenance 인지 fragment 저장과 결합한 LLM 메모리 시스템 없음. 저자 주장: "fine-grained access asymmetry를 명시적으로 고려한 multi-agent, multi-user 메모리 공유의 첫 정식화".

## 핵심 설계

### 권한 모델 (§3.1)

- 집합 𝒰(사용자), 𝒜(에이전트), ℛ(리소스: 도구·API·정형 데이터).
- Eq.(1) 시각 t의 두 이분 그래프: G_UA(t) ⊆ 𝒰×𝒜 (u가 a를 호출 가능), G_AR(t) ⊆ 𝒜×ℛ (a가 r에 접근 가능). 온보딩·역할 변경·철회로 시간에 따라 변함.
- Eq.(2) 𝒜(u,t) = {a | (u,a) ∈ G_UA(t)}, ℛ(a,t) = {r | (a,r) ∈ G_AR(t)}.

### 메모리 단위와 tier (§3.2, §4)

- fragment m의 **불변 provenance**: 𝒯(m) 생성 시각, 𝒰(m) 기여 사용자, 𝒜(m) 기여 에이전트 집합, ℛ(m) 생성 중 접근한 리소스 집합.
- 구현상 fragment = **LLM이 생성한 key–value 쌍**(key: 간결한 질의/주제, value: 답/설명), 서브태스크 완료 후 대화 trace를 매핑해 생성(§4 Memory Encoder; 부록 Table 4/10/18 예시에 UUID Memory ID).
- ℳ = ℳ^private ∪ ℳ^shared. 사용자별 private store ℳ^private(u,t), 에이전트별 shared store ℳ^shared(a,t)(a가 모든 사용자를 위해 생성한 fragment).
- **Eq.(3) 접근 가능 집합**: ℳ(u,a,t) = { m ∈ ℳ | 𝒜(m) ⊆ 𝒜(u,t) ∧ ℛ(m) ⊆ ℛ(a,t) }
  - 즉 fragment를 만든 에이전트들을 *현재 사용자*가 모두 호출할 수 있고, fragment가 의존한 리소스들을 *현재 서빙 에이전트*가 모두 접근할 수 있어야 함.
  - 포함될 수 있는 것: (1) u가 𝒜(u,t)의 다른 에이전트와 한 이력, (2) a가 다른 사용자를 서빙하며 만든 fragment, (3) u가 호출 가능한 에이전트로 다른 사용자가 만든 fragment(a의 리소스 권한 조건부).
  - 현재 시각 t의 그래프로 평가 → 철회/부여가 소급 반영되는 **retrospective permission check**.

### Read path (§3.3, §4, 부록 B)

- 사용자 u의 쿼리 q → 코디네이터가 𝒜(u,t) 중 관련 에이전트 부분집합 𝒜(u,t,q) 선택(접근 그래프상 허용된 에이전트만 후보; 부록 B.1).
- 각 에이전트: y_{u,a,t} = a(q, π^read_{u,a,t}(ℳ(u,a,t)), ℛ(a,t)).
- 검색: 서브쿼리 임베딩과 fragment key의 코사인 유사도로 user tier top-k_user + provenance 제약을 만족하는 cross-user tier top-k_cross (Scenario 1·3: k_user = k_cross = 10, Scenario 3은 유사도 임계 0.1; Scenario 2: 20/20).
- 실험에서 read policy는 **Simple**(허용 fragment를 그대로 반환). Transformation read(LLM이 redact/anonymize/paraphrase한 view로 투영)는 정의만 함.
- 최종 응답: aggregator LLM이 (subquery, response) 순서 목록을 합성. 코디네이터는 매 라운드 `{"agent": ID, "subquery": …}` 또는 `{"stop": true}` JSON 출력.

### Write path (§3.4, 부록 B.2)

- Eq.(4) π^{write/private}_{u,a,t}: (y, ℳ^private(u,t)) → ℳ^private(u,t+1); Eq.(5) π^{write/shared}: (y, ℳ^shared) → ℳ^shared(t+1). 사용자가 기여물 기밀 수준을 조정 가능(익명화·민감정보 redact·특정 콘텐츠 차단).
- 실험: **Transformation write policy**, 시스템 레벨 프롬프트 2개(부록 Table 1):
  - Private: "Extract key concepts from interactions that would be useful for the specific user… standalone memories… key-value pair…"
  - Shared: "Extract generally applicable knowledge… that would benefit any user… **Remove any user-specific details or personalized examples**…"
- 메모리 업데이트는 **중간 응답(에이전트별 y)**으로 수행(최종 응답 아님, 부록 B.1).
- 정책 세분성: π* ∈ {π_global, π_u(사용자별), π_a(에이전트별), π_t(시간별)} — read/write 독립 설정.

### 정책 집행 지점

- (1) 코디네이터의 에이전트 선택 단계(G_UA), (2) 에이전트의 리소스 호출(G_AR), (3) 메모리 검색 시 Eq.(3) provenance 필터, (4) 쓰기 시 LLM 변환(private/shared 분리). (1)–(3)은 결정적 집합 검사, (4)는 확률적 LLM.

### 구현

모든 LLM 구성요소(코디네이터, 도메인 에이전트, read/write 변환, aggregator) gpt-4o; 임베딩 text-embedding-3-large; OpenAI function calling; 리소스는 JSON schema가 있는 Python callable(예: knowledge-base search query → top_k_results).

## 실험/근거 (§5, 부록 C–E)

지표: Accuracy(정답 대비 정규화 정확도, LLM judge), Agent Utilization(쿼리당 호출 에이전트 수), Resource Utilization(쿼리당 KB/API 호출 수 — 지연은 변동이 커서 호출 수로 대체).

- **Scenario 1 — Fully collaborative** (MultiHop-RAG: 기사 609개(평균 2,046 토큰), 멀티홉 질문 2,556개 = inference 816 / comparison 856 / temporal 583 / null 301). 6개 도메인 KB(entertainment 114, business 81, sports 211, technology 172, health 10, science 21 문서) ↔ 6개 전문 에이전트 1:1, 사용자 5명 전원 전체 에이전트 접근(고정 그래프). KMeans 10 클러스터로 "global query" 겹침률 ρ ∈ {0, 25, 50, 75%}. Shared vs Isolated.
  - 결과(본문): 협업 메모리 정확도 평균 0.90 이상 유지, isolated는 겹침률 높을수록 "slightly lower"; **리소스 사용 50% 겹침에서 최대 61%, 75%에서 59% 감소**(isolated 대비). 그림 캡션은 두 방식의 정확도·에이전트 사용이 "similar"라고 씀.
  - 부록 C.4: inference는 둘 다 천장 근처, comparison은 공유 시 소폭 정확도 향상, temporal은 리소스 효율 이득이 가장 큼.
- **Scenario 2 — Asymmetric** (GPT-4o 합성 비즈니스 프로젝트 쿼리 200개 = easy 100 / hard 100). 역할: Market Researcher, Financial Analyst, Logistics Lead, Strategy Director. 에이전트: market/finance/logistics/decision. 리소스는 GPT-4o 시뮬레이션: market_kb, finance_forecaster, logistics_comparator, strategic_computation.
  - User→Agent(Table 5): Market Researcher → market_agent; Financial Analyst → finance, decision; Logistics Lead → logistics, finance; Strategy Director → 전부.
  - Agent→Resource(Table 6): market → market_kb, strategic_computation; finance → finance_forecaster, strategic_computation; logistics → logistics_comparator, strategic_computation; decision → 4개 전부.
  - 하위 사용자 3명이 분해된 서브태스크 수행, Director는 메인 쿼리를 받아 종합.
  - 결과: 정답 없음 → 리소스 사용량만. 사용자별 히스토그램(Fig.4)에서 공유 시 호출 감소라고 서술 — **본문에 수치 없음**.
- **Scenario 3 — Dynamic** (SciQAG 중 5개 WoS 카테고리, 문서 100개(평균 3,609 토큰), 쿼리 100개 = 사용자 5명 × 카테고리 5 × 4). 에이전트 5↔리소스 5 1:1 고정, user–agent 간선만 변화. 부여 단계 t0–t4 간선 5→10→15→20→25(완전 연결), 철회 단계 t5–t8 20→15→10→5. Bernoulli p=0.2로 간선 추가/제거, 이전 단계 그래프 위에 누적. 같은 100 쿼리 반복, 메모리는 단계 간 누적.
  - Table 19(원자료, 평균±):

| t | 조건 | Accuracy | #Resources | #Agent | #User Mem | #Cross Mem |
|---|---|---|---|---|---|---|
| t0 | Grant | 0.27±0.01 | 0.46 | 0.51 | 2.94 | 3.25 |
| t1 | Grant | 0.40±0.02 | 0.34 | 0.74 | 5.85 | 7.09 |
| t2 | Grant | 0.54±0.03 | 0.60 | 1.14 | 9.81 | 11.40 |
| t3 | Grant | 0.56±0.03 | 0.57 | 1.29 | 11.11 | 12.90 |
| t4 | Grant | 0.61±0.03 | 0.48 | 1.31 | 11.27 | 13.10 |
| t5 | Revoke | 0.56±0.03 | 0.21 | 1.19 | 11.57 | 11.90 |
| t6 | Revoke | 0.47±0.02 | 0.30 | 1.08 | 10.77 | 10.80 |
| t7 | Revoke | 0.49±0.02 | 0.23 | 1.07 | 10.75 | 10.75 |
| t8 | Revoke | 0.37±0.02 | 0.06 | 0.68 | 6.75 | 6.75 |

- 해석(저자): 정확도는 권한 부여 시 상승·철회 시 하락; 리소스 호출은 시간이 갈수록 감소(메모리 재사용); 접근 행렬(Fig.6/11)에서 사용자는 허용된 에이전트/리소스만 사용 → "strict adherence".
- 베이스라인은 isolated memory(공유 끔)뿐. 외부 메모리 시스템과 비교 없음.

## 한계

### 저자가 밝힌 한계 (§6)

- 규제/프라이버시로 실데이터 수집 어려움 → 기존 벤치마크·합성 쿼리·시뮬레이션 다중 사용자 환경.
- 사용자·에이전트 수가 적당한 통제 환경; 동시성 빈번·역할 급변하는 대규모 기업 환경 미탐구.
- LLM 확률성 → 집행 메커니즘에도 불구하고 가끔 hallucination이나 **policy breach** 가능.
- 프로덕션의 리소스 사용 평가는 API 지연 변동으로 어려워 호출 수로 단순화.

### 내가 본 약점

- **"provable adherence"를 주장하지만 논문에 정리·증명이 없다.** Eq.(3) 집합 필터의 정의상 성질 + 접근 행렬 그림이 근거의 전부. 유출(leakage)을 직접 측정한 지표·adversarial 테스트 없음.
- **Eq.(3)이 𝒰(m)(기여 사용자)을 검사하지 않음**: 공유 tier에서는 다른 사용자의 fragment가 에이전트/리소스 조건만 맞으면 노출. 사용자 프라이버시는 전적으로 shared write 프롬프트("Remove any user-specific details")라는 **확률적 LLM 변환**에 의존 — 즉 결정적 PEP가 아님.
- **provenance가 1-hop**: fragment가 다른 fragment를 읽고 만든 답에서 나왔을 때, 읽은 fragment의 𝒜/ℛ가 새 fragment의 provenance로 합쳐지는지 정의 없음(에이전트가 메모리에서 읽은 정보로 답하면 ℛ(m)이 비어 보일 수 있음 → 리소스 제약 우회 가능성). AkasicMEM이 Table 1에서 lineage/composition을 "Partial"로 평가한 지점과 일치.
- 권한 축이 "에이전트 호출 가능 여부"와 "리소스 접근 가능 여부"뿐 — 같은 리소스 내 문서/레코드/행 단위 권한, 사용자-리소스 직접 권한은 모델에 없음(사용자 권한이 에이전트를 통해 간접화).
- Scenario 2는 정답도 수치도 없음; Scenario 1은 그래프가 완전 연결이라 접근 통제를 시험하지 않음; Scenario 3은 리소스 1:1 고정에 user–agent만 변화. Table 19의 #Resources가 단조 감소가 아니라(t2 0.60, t3 0.57) 노이즈가 큼.
- 충돌/중복/temporal validity, 삭제(철회된 사용자 데이터의 실제 삭제) 메커니즘 없음 — 철회는 *가시성*만 바꿈.
- 공유 tier가 "에이전트별 store"로 정의되어 팀/프로젝트 같은 조직 단위 scope 개념이 없다.

## 팀/조직 메모리 설계에 주는 시사점

- **fragment마다 불변 provenance(누가·어느 에이전트로·어느 리소스를 써서·언제)를 쓰기 시점에 박고, 권한은 읽기 시점의 현재 그래프로 평가**하라 — 권한 철회/부여가 저장 데이터 수정 없이 소급 반영된다(retrospective check). 팀 메모리의 최소 요건.
- **권한을 user→agent, agent→resource 두 층으로 분리 모델링**하면 "팀 에이전트"·"공유 에이전트"가 사용자 권한을 세탁하는 경로를 표현할 수 있다. 다만 사용자→리소스 직접 권한(소스 ACL)도 같이 봐야 함(→ AkasicMEM).
- **private/shared 쓰기 정책을 분리**하고 shared 쓰기에는 일반화·익명화 변환을 적용 — 단 LLM 변환은 보조 수단이며, 결정적 필터(contributing user, 소스 ACL)를 대체하면 안 된다.
- **read/write 정책 세분성(global/user/agent/time)**을 처음부터 설계 축으로 — 같은 메모리를 역할별로 다른 투영 view로 보여주는 transformation read는 필드 마스킹의 LLM 버전.
- 효율 근거: 사용자 간 질의 겹침 50–75%에서 리소스 호출 59–61% 감소 → 팀 메모리 ROI 지표로 "중복 도구 호출 감소"를 쓸 수 있다.
- 평가 설계: 권한 부여→철회 타임라인에서 정확도·리소스 사용·메모리 가시 수를 같이 추적하는 Scenario 3 방식은 재사용 가치가 있으나, **leakage(불허 fragment 노출률)를 별도 지표로** 추가해야 함.

## 다른 개념과의 연결

- **Scope hierarchy**: private(사용자) / shared(에이전트별) 2-tier + 정책 세분성 global/user/agent/time. 팀·프로젝트·테넌트 scope 없음.
- **Provenance/lineage**: 𝒯(m), 𝒰(m), 𝒜(m), ℛ(m) 1-hop 불변 provenance. AkasicMEM의 transitive lineage, AMU의 column lineage보다 얕음.
- **Authorization continuity**: Eq.(3) 읽기 시점 재평가 = AkasicMEM의 policy re-evaluation(Table 1에서 Core로 인정), 그러나 메모리→메모리 파생과 정책 합성은 Partial.
- **ABAC/RBAC**: ABAC의 정책 모듈성 + 시간가변 이분 그래프.
- **Temporal invalidation**: 권한 축만 시간가변. 사실 validity·supersession 없음.
- **Write gates**: π^write/private, π^write/shared LLM 변환(redact/anonymize/paraphrase/block).
- **Decision traces**: "full auditability of memory operations"를 주장하나 감사 로그 스키마는 미서술; 부록의 write→read 예시(Memory ID, generated-at query, used-at query)가 사실상 trace 예시.
- **AMU 논문의 비판**: fragment를 원자 단위로 판정하므로 허용 fragment가 금지 컬럼 파생값을 품을 수 있음(2610.07258 §II).
- **Distributed Cognition**(Hutchins) — 동기 프레임.

## 확인 필요

- ICML 2025 채택 여부 및 카메라레디 버전에서 정리/증명 추가 여부(읽은 arXiv v1에는 학회 표기·증명 없음).
- 코드/데이터 공개 여부(부록 B.1 "will publicly release").
- 에이전트가 메모리에서 읽은 fragment로 생성한 새 fragment의 𝒜(m)/ℛ(m)에 읽은 fragment의 provenance가 합쳐지는지(구현 수준).
- Scenario 1/2의 정확도·리소스 사용 그림 수치(이미지라 미확인).
- Table 19의 ± 값이 몇 회 반복 실행 기준인지(본문 미기재).
- 본문 §5.3의 "until the graph reaches 5 edges"와 부록의 단계별 5/10/15/20/25 간선 서술 간 표현 차이 — 부록 기준으로 기재함.
