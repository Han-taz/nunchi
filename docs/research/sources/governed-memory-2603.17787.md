---
title: "Governed Memory: A Production Architecture for Multi-Agent Workflows"
arxiv_id: "2603.17787"
authors: "Hamed Taheri"
affiliation: "Personize.ai"
date: "2026-03-18 (v1)"
url: "https://arxiv.org/abs/2603.17787"
html: "https://arxiv.org/html/2603.17787"
code: "https://github.com/personizeai/governed-memory (논문 기재, 미확인)"
type: paper
read_status: full
read_note: "arXiv HTML v1 본문 + 부록 A–G 전체 읽음. 그림(Fig.1–4)은 캡션만 확인."
---

# Governed Memory (Personize.ai, 2603.17787)

## 한 줄 요약

같은 엔티티(고객·회사·딜)에 대해 수십 개의 에이전트 노드가 따로 읽고 쓰는 기업 환경을 위해, **오픈셋 원자 사실 + 스키마 강제 타입 속성의 이중 메모리**, **거버넌스 변수(조직 정책) 라우팅과 세션 델타 전달**, **orgId/CRM 키 기반 엔티티 격리 검색**, **스키마 수명주기(자동 개선) 피드백 루프**를 하나의 공유 레이어(MCP/SDK)로 묶은 프로덕션 아키텍처 보고서.

## 문제 정의 (저자가 주장하는 gap)

§1.1 "memory governance gap" — 단일 에이전트 메모리 시스템이 다루지 않는 5가지 구조적 문제:

1. **Memory silos across workflows** — enrichment/outbound/support/renewal 에이전트가 같은 엔티티에 작용하지만 맥락 공유 없음.
2. **Governance fragmentation** — 팀별 시스템 프롬프트에 복사된 브랜드/컴플라이언스 규칙; 법무 정책 변경이 "14개 에이전트 설정, 3개 팀"에 전파될 메커니즘·버전관리·단일 진실원이 없음.
3. **Unstructured memory as a downstream dead end** — 자유 텍스트 메모리는 필터/정렬/CRM 동기화/집계 불가.
4. **Context redundancy in autonomous multi-step execution** — 스텝마다 같은 정책 재주입 → 토큰 낭비·주의력 저하(Lost in the Middle 인용).
5. **Silent quality degradation** — 속성별 정확도 모니터링, 추출 confidence 추적, 스키마 drift 탐지 부재.
§1.2: RAG는 "retrieval primitive"이지 쓰기 거버넌스·조직 컨텍스트 라우팅·세션 인지 전달·스키마 강제·품질 피드백을 제공하지 않음. §2.2: Mem0/SimpleMem은 메모리 primitive이고 본 시스템은 그 위의 인프라 레이어라고 포지셔닝.

## 핵심 설계

### 전체 구조 (§3, Fig.1)

4개 레이어, 각각 독립 설정/비활성화 가능:

- L1 Dual Memory Store (§4) / L2 Governance Routing (§5) / L3 Governed Retrieval (§6) / L4 Schema Lifecycle & Quality Feedback (§7).
- 모든 연산은 **orgId 파티션**(하드 테넌트 격리), 조직 내부는 **CRM 키로 엔티티 스코프**. MCP 인터페이스 + SDK로 프레임워크 무관 접근.

### 데이터 모델 — `MemoryEntry` (부록 A)

- 공통: `id`, `text`(원자 사실 또는 정규화된 속성 문장), `orgId`(파티션 키), `recordId?`(엔티티 스코프: contact/company/deal), `type`("memory" | "property_value"), `keywords[]`, `persons[]`, `entities[]`, `location?`, `topic?`, `timestamp?`(ISO 8601 temporal anchor), `customAttributes`(map, 스키마 타입 값), `source`(provenance marker), `score?`(검색 시 채움), `createdAt`, `updatedAt`.
- 속성 전용(type=property_value): `propertyId`, `propertyName`, `systemName`, `propertyValue`(직렬화), `collectionId`(스키마 컬렉션 스코프), `confidence`(0.0–1.0).
- `provenance`(customAttributes 내부): `contentHash`(원문 앞 1000자 SHA-256), `contentLength`, `speaker?`, `extractionMethod`("single_extract"|"dual_extract"), `llmModel?`, `chunkIndex?`, `chunkTotal?`, `redactionApplied?`, `timestamp`(추출 시각).
- `CRMKeys`: `recordId?`, `email?`, `websiteUrl?`, `phoneNumber?`, `customIdentifiers?` — 엔티티 타입은 open-ended(contact, company, deal, vendor, partner, device, location, content asset).
- **주의**: 스코프는 org → entity 2단계뿐. 사용자/팀/역할 단위 메모리 가시성 필드는 없음. 팀 경계는 거버넌스 변수에만 존재(아래).

### Write path (§4, 부록 C Alg.2, 부록 D Alg.3)

1. (옵션) 추출 전 PII redaction → 2. 콘텐츠 타입별 overlap chunking(dialogue/transcript/document) → 3. chunk별 **임베딩 유사도 기반 속성 선택**(최소 점수 임계 + 최대 개수 cap; 수백 개 속성을 LLM에 다 주지 않음) → 4. **단일 LLM 호출로 dual extraction**: (a) confidence·update semantics(단일값 교체 vs temporal accumulation 플래그) 포함 타입 속성값, (b) 오픈셋 원자 사실 → 5. 추출 후 redaction 재스캔 → 6. cross-chunk dedup(속성은 최고 confidence, 사실은 정규화 텍스트) → 7. quality gate 계산 → 8. 배치 임베딩 + provenance 부착 → 9. 기존 저장소 대비 **write-side dedup(cosine ≥ 0.92면 skip)**.

- 오픈셋 추출 프롬프트 불변식 5개: completeness, self-containment, coreference resolution, temporal anchoring, atomicity.
- **Quality gates**(§4.2): coreference score(대명사 탐지), self-containment score(구문 패턴), temporal anchoring score(상대시간 패턴) — 휴리스틱, 배치 단위 조기 경보 신호.
- 타입 검증: text, number, date, boolean, options, array.
- **Background consolidation**(Alg.3, 부록 D): (1) cosine 0.95 이상 near-duplicate merge(쓰기 시 0.92보다 높게 → false merge 회피), (2) retention window 초과 stale prune; **sole-memory protection**(엔티티의 오픈셋 메모리가 0개가 되지 않도록 최신 1개 보존); 메모리 10개 미만 org는 skip; dry-run 모드; consolidation 1시간 후 compaction 옵션.

### Governance 변수 & 라우팅 (§5, 부록 C Alg.4–5, 부록 E)

- **Governance variable**(=guideline): name, description, tags, content, heading hierarchy, content-aware embedding.
- 생성/수정 시 병렬 enrichment 3개: (1) **HyPE**(Hypothetical Prompt Enrichment — 그럴듯한 에이전트 요청 synthetic query 생성, doc2query 계열), (2) **governance scope inference**(LLM이 always-on 여부 + trigger keyword 추론), (3) content-aware embedding.
- **Fast mode**(~850ms 평균, LLM 호출 없음): 임베딩 유사도 + 키워드 overlap(메타데이터·HyPE 쿼리 대상)의 가중 합 + always-on boost; critical/supplementary로 분할, 동적 cap. always-on은 무조건 포함.
- **Full mode**(~2–5s): Alg.4 임베딩 pre-filter(임베딩 없는 후보는 무조건 통과; 최소 점수 또는 top-K) → LLM 4단계 구조화 분석(Task Understanding → Quality Dimension Identification → Task Refinement → Selection & Prioritization; 변수별 priority, mode(full/section), reasoning). critical이 0개면 supplementary 상위 2개 **fallback promotion**. section 모드는 heading 경계로 섹션만 추출, heading 미발견 시 전체 전달.
- **Auto mode**(기본): 라이브러리 특성으로 fast/full 선택(기준 미공개).
- **Progressive context delivery**(§5.3): 세션 상태 레코드가 이미 전달된 변수(및 섹션)를 추적 → 이후 호출에서 제외, 델타만 주입. **supplementary 항목은 기록하지 않음**(나중에 critical로 승격 가능). 세션 TTL 24시간(§9.2).
- **정책 집행 지점(PEP)**: 부록 B — 거버넌스 변수 visibility(organization / private / adminsOnly), access level(readOnly / cloneable / editable)을 **API 레이어에서** 집행. 모든 연산은 timestamp·user id·operation metadata로 로깅. 저장소 레벨 하드 격리는 orgId 파티션 키.

### Read path (§6, Alg.6)

1. 쿼리 임베딩 → 2. org 파티션 내 벡터 검색 + **CRM 키 pre-filter**(엔티티 격리; 임베딩 구별성이 아니라 필터로 보장) → 3. 메타데이터 post-filter(persons, entities, location, timestamp range, memory type) → 4. (옵션) reflection loop → 5. id 기준 merge/dedup → 6. (옵션) 출처 표기 LLM 답변 합성.

- **Reflection loop**: 최대 라운드 기본 2; 매 라운드 LLM이 증거 완결성 판단(temperature 0.1), 불완전하면 follow-up 쿼리 1–2개 생성(temperature 0.3); 라운드당 LLM 1회 + 검색 0–2회.
- **Entity context injection endpoint**(§6.3): CRM 키로 엔티티 해석 → Properties / Observations 섹션 블록, 토큰 예산 하에서 **스키마 속성 우선, 오픈셋은 최신순**.
- **충돌 처리**(§8.8): 검색 시 지수 recency decay(half-life = 38일)로 최신 사실 우선. 명시적 supersede/invalidation 필드는 없음.

### Redaction (부록 B, Alg.1)

2단계(추출 전 typed placeholder 치환 → LLM이 원값을 못 봄 / 추출 후 재스캔). 4 tier: Secrets(API key, private key, password; 패턴), Financial PII(카드·IBAN; regex+Luhn), Identity PII(SSN; regex+검증), Contact PII(email, phone, IP; 포맷). 전략: redact / mask(끝 4자리 유지) / hash(SHA-256 prefix, 연결 가능·비가역). tier별 audit 레코드 `{tier, entityType, count}`.

### Schema lifecycle (§7, Alg.7, 부록 G)

- AI-assisted authoring(자연어 → 타입 속성 정의), interactive enhancement(per-property/bulk).
- Rubric 평가(§7.2–7.4는 **내부/얼리액세스 API 한정**): 프리셋 default/sales/support/research, 각 100점(예: Sales = Personalization 30, Value Prop 25, CTA 20, Tone 25). 편향 완화: rubric-first prompting, trace-grounded evaluation, cross-model evaluation.
- Execution logging: conversation summary, tool usage log, memory recall log(usage flag 포함), memory creation log, governance context log(helpfulness rating) — "회상했는데 안 썼나 vs 회상 못 했나" 구분.
- 자동 스키마 개선 3단계: extraction replay → per-property 분류(extracted / missed / low-confidence / inaccurate / unavailable) + 개선 지시 → 속성별 병렬 최적화(change annotation).

## 실험/근거 (§8, 부록 F)

설정: 임베디드 ground truth가 있는 **합성 데이터**, seed 42, 프로덕션 API에서 실행. N=10→50/타입으로 늘리며 N≥30에서 안정화 확인했다고 주장. 데이터셋(Table 1): 주 코퍼스 250샘플/5타입(샘플당 사실 8–12, 속성 5–8), multi-source 엔티티 5소스(고유 사실 40, cross-source dupe 8), 격리 프로파일 100 엔티티, recall 쿼리 500, 거버넌스 변수 쌍 5(15 태스크), 충돌 쌍 30(15 카테고리).

| 실험 | 결과(보고값 그대로) |
|---|---|
| E1 추출 | Fact recall 99.6% 전체(call notes/documents/emails/transcripts 100%, chats 98%). 저자 스스로 "upper-bound demonstration"이라 명시 |
| E9 quality gate ablation (40샘플) | defect rate 6.3% vs 8.4%(상대 25%↓), temporal accuracy 95.2% vs 88.4%, SNR 1.1:1 → 4.2:1, decision precision 94.5% |
| E12 이중 모달 (20샘플) | 둘 다 34%, 오픈셋만 38%, 스키마만 12%, 둘 다 놓침 16%, combined recall 82.8% |
| E3/E13 라우팅 | 25 변수/5 카테고리, 20 태스크 타입: precision 92%, recall 88%. 잘 작성된 변수가 20–50pp 더 발견됨; brand/product/support 3/5 카테고리에서 부실 작성 변수 discovery 0% |
| E10 reflection (10 hard multi-hop) | 완결성: 없음 37.1% / API-managed 1R 40.4% / manual multi-hop 1R 61.2% / 2R 62.8%; 지연 9.4s/10.4s/6.5s/10.0s |
| E11 엔티티 격리 | 100 엔티티(유사 산업·역할·이름·딜 규모), 500 쿼리×5 타입 → 3,800 결과에서 true leakage 0; flag 2.74%(104건) 전부 이름 토큰 공유 false positive |
| E14 의미 충돌 (30쌍) | stale 74–270일 vs fresh 0–57일; conflict detection(fresh 포함) 83.3%, full stale suppression 33.3%, incorrect stale 3.3%; both_present 15건은 모두 fresh 먼저 제시 |
| E8 end-to-end (10 prospect×3 run, sales rubric) | No memory 79.5 / Raw memory 85.2(+5.7) / Open-set+governance 86.4(+6.9) / Full governed 85.9(+6.4) |
| E15 adversarial governance (50 시나리오) | compliance 100%, guardrail activation 96%(48/50), 정책 유출 0 |
| LoCoMo (1,542 Q) | overall 74.8%(human 87.9%), single-hop 78.7, multi-hop 51.7, temporal 64.6, open-ended 83.6. 채점: text-match 우선, LLM-judge fallback(정답 1,153 중 950=82.4%가 text-match) |
| E2 메모리 밀도 | 0개 69.3 / 3개 86.0 / 7개 88.0 / 12개 84.4 / 20개 85.2 / 30개 88.3 → "~7개에서 포화" |
| E4 progressive delivery | 5스텝 31,167 → 15,484 토큰(50.3% 절감); 재진입 스텝 49.7–89.6%, 새 도메인 스텝 0% |
| E6 write dedup | 5 소스 → 33 저장, 162 skip(83.1%), false positive 0 |

베이스라인: 내부 ablation(조건 A–D 등)이 대부분. LoCoMo에서 Mem0 64–67%, Zep 42–66%, OpenAI memory ~53%를 "참고"로 언급하나 저자 스스로 채점 방식이 달라 직접 비교 불가라고 씀.

## 한계

### 저자가 밝힌 한계 (§9.1–9.2, §8.2)

- Quality gate는 패턴 휴리스틱, 인간 판단 대비 calibration 없음.
- 자기평가는 LLM-as-judge 편향을 완화할 뿐 제거하지 못함.
- dedup 임계(0.92/0.95)는 경험적 튜닝; 적응형이 더 견고할 것.
- Redaction은 regex 기반 — 난독화/문맥의존 PII 누락 가능.
- **다중 에이전트 동시 쓰기 충돌은 미검증**(E14는 순차 쓰기만) — 공유 레이어에서 현실적 시나리오이나 open problem.
- Progressive delivery는 이전 전달 컨텍스트가 계속 유효하다고 가정; 24h TTL로 제한할 뿐.
- 합성 데이터 결과는 상한; 프로덕션은 "comparable but modestly lower"(수치 미제시).
- API-managed reflection은 일반 follow-up만 생성 → manual multi-hop과 큰 격차.

### 내가 본 약점

- **조직 내부 권한 모델이 없음**: 메모리 가시성은 org와 entity(CRM 키)뿐. "영업팀 에이전트는 지원 티켓 메모를 보면 안 된다" 같은 팀/역할/사용자 단위 read 제한, 출처(source) 권한 상속이 데이터 모델에 없다. 거버넌스 변수의 visibility(organization/private/adminsOnly)만 존재. 즉 "governance"는 주로 *정책 콘텐츠 전달*이지 *메모리 접근 통제*가 아님.
- E11 "zero leakage"는 CRM 키 pre-filter가 정확히 적용되면 정의상 0이 되는 구조적 결과에 가깝다(필터 오설정·엔티티 병합 오류·잘못된 recordId 쓰기 같은 실제 실패 모드는 테스트 안 됨).
- 숫자 불일치: 초록 "zero cross-entity leakage across 500 adversarial queries" vs 결론 "across 3,800 adversarial queries"(실제 3,800은 *결과* 수). 초록의 "N=250" 프레이밍이 모든 실험에 해당하지 않음(E9 40, E12 20, E10 10, E8 10).
- E15 "100% compliance"의 시나리오 구성·판정 기준이 본문에 없음 → 재현/해석 어려움.
- E8에서 Full governed(85.9)가 C(86.4)보다 낮음 — 스키마 레이어의 가치는 "downstream"이라고 주장하지만 이를 측정한 실험은 없음.
- 충돌 해결이 recency decay(half-life 38일)뿐 — 명시적 supersede/valid_to/invalidation 없음 → strict stale suppression 33.3%. 기업 메모리에서 "지금 사실이 무엇인가"를 보장하지 못함.
- 메모리 쓰기 권한(어떤 에이전트가 어떤 엔티티/속성을 쓸 수 있는지) 통제가 서술되지 않음. provenance에 `llmModel`, `extractionMethod`는 있으나 **어떤 에이전트/사용자/워크플로가 썼는지(writer principal) 필드가 MemoryEntry에 명시되지 않음**(`source` 문자열 하나뿐).
- 메모리→메모리 파생(consolidation merge 결과)의 lineage가 기록되는지 불명.

## 팀/조직 메모리 설계에 주는 시사점

- **이중 표현을 기본으로**: 같은 추출 패스에서 자유 텍스트 사실(long-tail, E12에서 38%가 여기에만 존재)과 타입 속성(필터·집계·CRM 동기화용)을 동시에 만든다. 팀 메모리에서 "결정 상태/담당자/마감" 같은 것은 속성으로, 맥락은 사실로.
- **정책(가이드라인)을 메모리와 분리된 1급 객체로 버전 관리하고 라우팅**: 팀별 시스템 프롬프트 복붙 대신 governance variable + always-on 플래그 + trigger keyword + HyPE 쿼리. 정책 작성 품질이 발견율을 20–50pp 좌우하므로 작성 도구/린트가 운영상 필요.
- **세션 단위 delivered-set 추적**으로 반복 주입을 제거하되, supplementary는 기록하지 않아 승격 가능하게 — 장기 자율 루프에서 50% 토큰 절감 근거.
- **격리는 임베딩이 아니라 하드 필터(파티션 키 + 엔티티 키)로**. 단, 이 논문 수준(org/entity)으로는 부족하므로 팀/역할/소스 권한 차원을 추가해야 함(→ AkasicMEM, Collaborative Memory).
- **write gate를 저비용 휴리스틱으로라도 두고 운영 지표로 삼기**: coreference/self-containment/temporal anchoring 점수, 쓰기 dedup 0.92 vs consolidation 0.95의 비대칭(쓰기는 중복 방지 쪽, 병합은 보수적으로), sole-memory protection, dry-run.
- **실행 trace 로깅(recall log + usage flag + governance context log)**을 평가와 묶어 "회상 실패 vs 활용 실패"를 구분 — decision trace 설계의 출발점으로 쓸 만함.

## 다른 개념과의 연결

- **Scope hierarchy**: org(하드 파티션) → entity(CRM 키) 2단계. 사용자/팀/프로젝트 계층 없음. AkasicMEM의 user/agent/thread/project/team/tenant scope와 대비.
- **Provenance/lineage**: source 콘텐츠 해시·청크 위치·모델·redaction 여부까지는 기록(문서→메모리 1-hop 추적). 메모리→메모리 파생, writer principal은 없음 → AkasicMEM의 transitive lineage, AMU의 column lineage보다 얕음.
- **Authorization continuity**: 다루지 않음. 출처 권한 변경이 파생 메모리에 반영되는 메커니즘 없음(AkasicMEM Table 1에서는 본 논문을 별도 평가하지 않았고, AMU 논문 Table I은 Governed Memory를 Content tag ✓, Role ACL ✓, Column lineage ✗, Retrieval gate ✓로 분류).
- **Temporal invalidation**: `timestamp` temporal anchor + recency decay(half-life 38일) + retention window prune. supersession/validity interval 없음(Zep 계열 bi-temporal과 대비).
- **Write gates**: quality gates(휴리스틱), 2단계 redaction, write-side dedup, 속성 타입 검증 + confidence + update 플래그(replace vs accumulate).
- **Decision traces**: §7.3 execution logging(tool usage, memory recall/creation, governance context + helpfulness)이 사실상 에이전트 결정 trace. 단 평가 용도이고 메모리로 재사용되지는 않음.
- **Context engineering**: progressive delivery = 세션 수준 컨텍스트 캐시 무효화 문제.

## 확인 필요

- GitHub `personizeai/governed-memory`에 실제로 데이터셋/ground truth/알고리즘 상세가 공개돼 있는지, E15 adversarial 시나리오 정의가 포함되는지.
- fast-mode 가중 합의 실제 가중치, critical/supplementary 동적 cap 규칙, auto mode 선택 기준 — 본문/부록에 수치 없음.
- 거버넌스 변수 visibility(private/adminsOnly)가 *라우팅 결과*에도 적용되는지(즉 요청 사용자 권한으로 라우팅 후보가 필터링되는지) — 부록 B는 "API 레이어 집행"이라고만 씀.
- 속성값의 update 플래그(replace vs temporal accumulation)가 저장 시 과거 값을 보존하는지(버전 이력) 여부.
- consolidation merge 시 원본 메모리 id/provenance가 병합 결과에 남는지.
- "Production deployments exhibit comparable but modestly lower recall"의 실제 수치.
