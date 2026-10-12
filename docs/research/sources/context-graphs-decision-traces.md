---
title: "Context Graphs / Decision Traces — Foundation Capital 논제, ContextOS DecisionRecord, Neo4j agent-memory"
source_owner: "Foundation Capital (Jaya Gupta, Ashu Garg) / ContextOS (Piyush Kumar) / Neo4j Labs / 비판: Forrester 블로그, Andrew Antes, Labo LLM(2차 요약)"
urls:
  - https://foundationcapital.com/ideas/context-graphs-ais-trillion-dollar-opportunity
  - https://contextosai.com/blog/context-graphs-in-contextos
  - https://github.com/neo4j-labs/agent-memory
  - https://neo4j.com/labs/agent-memory/explanation/memory-types/
  - https://neo4j.com/labs/agent-memory/explanation/multi-agent-sharing/
  - https://forrester.com/blogs/context-graphs-are-a-convergence-not-an-invention
  - https://andrewantes.com/context-graphs-risk
  - https://labo-llm.fr/en/techniques/context-graphs-decision-traces
accessed: 2026-10-12
type: "VC 에세이(논제) + 벤더 블로그(설계) + 오픈소스 README/문서 + 애널리스트·개인 블로그 비판"
read_status: "Foundation Capital 에세이(2025-12-22) 전문, ContextOS 포스트(2026-04-18) 전문, Neo4j agent-memory README 전문 + 문서 2페이지(memory-types, multi-agent-sharing) 전문, Forrester 블로그·Andrew Antes 글은 extract로 수령(핵심 부분 확인). Labo LLM은 검색 결과 발췌만 — 그 안에 인용된 Blaschka/Gartner/Verdantix 원문은 미확인. Foundation Capital 후속 글 'Why context graphs are the missing layer for AI'는 검색 발췌만."
---

# Context Graphs / Decision Traces

## 한 줄 요약

Foundation Capital은 규칙(rules)이 아니라 **결정 흔적(decision traces: 예외·오버라이드·선례·승인·교차시스템 근거)** 을 실행 경로에서 포착해 엔티티·시간에 걸쳐 엮은 "context graph"가 "결정의 system of record"가 될 것이라 주장하고, ContextOS는 이를 **append-only·hash-chained DecisionRecord(원천) → 그래프(projection)** 로 구체화하며, Neo4j agent-memory는 short-term/long-term/**reasoning memory** 3계층으로 실행 기록을 저장하는 OSS 구현을 제공한다 — 비판자들은 충실도(fidelity)·엔티티 grounding·거버넌스 없는 "write-only log" 위험을 지적한다.

## 핵심 설계/주장

### 1. Foundation Capital — "AI's trillion-dollar opportunity: Context graphs" (2025-12-22)

- 출발점: Jamin Ball "Long Live Systems of Record"에 동의하되, 데이터가 이미 어딘가 있다는 가정은 "half the picture".
- 구분:
  - **Rules**: "what should happen in general" (예: "use official ARR for reporting")
  - **Decision traces**: "what happened in this specific case" (예: "we used X definition, under policy v3.2, with a VP exception, based on precedent Z, and here's what we changed")
- **Context graph** 정의: "not 'the model's chain-of-thought,' but a living record of decision traces stitched across entities and time so precedent becomes searchable." 무엇이 일어났는지뿐 아니라 "why it was allowed to happen".
- 기존 SoR이 못 담는 것: 사람 머릿속 예외 로직("healthcare에 10% 추가"), 과거 결정 선례, 교차시스템 종합(Salesforce ARR + Zendesk 에스컬레이션 + Slack 이탈 위험 → "escalated to Tier 3"만 남음), 시스템 밖 승인 체인(Zoom/Slack DM의 VP 승인).
- 예시: 갱신 에이전트가 20% 할인 제안, 정책 상한 10%(service-impact 예외 시 초과 가능), PagerDuty SEV-1 3건 + Zendesk "cancel unless fixed" + 지난 분기 VP 승인 선례 → Finance 승인 → CRM에는 "20% discount" 하나만 남음.
- 위치 논리: **systems of agents 스타트업은 실행 경로(execution/orchestration path)** 에 있어 커밋 시점에 포착 가능; 운영 인큐번트(Salesforce 등)는 current-state 저장·사일로, 웨어하우스(Snowflake/Databricks)는 ETL 이후 **read path**.
- 피드백 루프: 포착된 trace → 검색 가능한 선례 → 자동화 확대. human-in-the-loop로 시작(에이전트가 제안·근거 수집·승인 라우팅·기록).
- 스타트업 경로 3가지: SoR 통째 대체(Regie), 모듈 대체(Maximor), 신규 SoR 창출(PlayerZero). 에이전트 관측성(Arize) 필요.
- 신호: 높은 인력 투입, 예외가 많은 결정(deal desk, underwriting, compliance review, escalation), 시스템 교차점의 "glue" 조직(RevOps, DevOps, SecOps).
- (검색 발췌) 후속 글에서 Ashu Garg: 범용 context graph 하나가 아니라 "the best context graph companies will be verticalized".

### 2. ContextOS — "Context Graphs: Decision Lineage as a System of Record" (2026-04-18, Piyush Kumar)

- **2026 업데이트: "the graph is a projection, not the source"** — DecisionRecord가 원천(signed, replayable contract), 그래프는 재색인·보강 가능한 질의면. "If a node cannot answer 'which `trace_id` wrote me?', it is analysis data, not decision lineage."
- **DecisionRecord 필드**(예시 JSON): `record_id`, `decision_key`(예 `revops.renewal.execute`), `trace_id`, `subject_ids`, `evidence_refs`(KG 스냅샷·툴콜 참조), `policy_decisions`(`policy_decision_id`, `rule_ids`), `approvals`(`gate_id`, `approver`, `approval_mode_effective`, `evidence_snapshot_hash`, `decided_at`), `outputs`, `lineage`(`pack_version`, `snapshot_version`). **산문("the model decided X because Y") 없음** — 판정·증거·정책·승인·해시체인만.
- **append-only, trace_id별 hash-chain**; 변조 시 replay가 `tamper_detected` 반환.
- 그래프 노드: Account, Renewal, Ticket, Incident, PolicyVersion, Approval, AgentRun, EvidenceArtifact, Exception, Commit. 엣지: `USED_EVIDENCE`, `APPLIED_POLICY`, `INVOKED_EXCEPTION`, `APPROVED_BY`, `BASED_ON_PRECEDENT`, `WROTE_STATE_TO`, `RESULTED_IN` + 메타데이터(**event time, valid time, provenance, policy version refs, redaction labels, access constraints**).
- "Time is the load-bearing column" — 결정 시점 세계 스냅샷 없는 선례는 "anecdote".
- **4개 API**:
  - `EmitDecisionRecord` — 불변식 **"no commit without record"**(레코드 미저장 시 부작용 커밋 거부)
  - `QueryPrecedent` — 후보 결정과 제약을 주면 tenant·intent로 스코프된 유사 선례(승인 패턴, 증거 유형, 결과) 반환
  - `ReplayDecision` — 고정 입력(당시 evidence pack, 정책 버전, 승인·예외 경로, write set)으로 재구성, 판정이 저장 레코드와 **byte-match**해야
  - `AuditDecisionLineage` — "정책 X 이탈을 누가 승인했나", "어떤 예외가 나쁜 결과와 상관있나"
- 프로덕션 요건: 모든 레코드에 정책 번들 버전 고정, 증거 provenance(source, adapter, hash), redaction label·tenant scope를 trace/node/edge에, 런타임 서명키, 사람 승인은 status 필드가 아닌 1급 이벤트.
- 품질 지표: record emission 성공률, "no commit without record" 집행률, missing-evidence율, precedent hit rate, agent acceptance rate, policy-deviation explainability rate, 미해결 충돌 비율, record overhead p95, replay determinism rate. "If the dashboard does not have these on it… You have a logging pipeline."
- 준비 체크리스트: Source of truth / Provenance / Time model / Access control / Replay / **Outcome loop**(결과·정정·후속 StrategyRule이 바꾼 결정에 연결).

### 3. Neo4j Labs agent-memory (README + 문서)

- 상태: Neo4j Labs, Beta, 커뮤니티 지원(SLA·하위호환 보장 없음). Apache 2.0. Python `neo4j-agent-memory==0.7.0`, TypeScript `@neo4j-labs/agent-memory@0.5.0`, 호스티드 NAMS 또는 Bolt(self-hosted Neo4j/Aura).
- **3계층**:

  | Short-Term | Long-Term | Reasoning |
  |---|---|---|
  | 대화·메시지, 세션별 이력, vector+text 검색 | 엔티티·선호·사실, POLE+O 모델 지식그래프, 엔티티 해소·dedup | reasoning traces & tool usage, 기록된 결정 회상, 유사 task 검색 |

- 문서: reasoning memory는 "the task steps, tool calls, observations, and outcomes that an application or integration records. It is an execution record, not access to a model's private internal reasoning." 이름은 자동 만료/모델 학습을 뜻하지 않음 — "Persistence duration is a policy choice".
- 연결: Bolt에서 `:MENTIONS`(메시지→엔티티), `:INITIATED_BY`(trace→촉발 메시지), `:TOUCHED`(reasoning step→엔티티 감사 엣지), `TraceOutcome`. 이 관계는 앱이 실제로 기록해야 생김.
- 운영 기능: `adopt_existing_graph`, buffered writes, `consolidation.dedupe_entities`, eval harness(`client.eval.run`), MCP 서버(core 6 tools / extended 16 tools; HTTP 전송은 **인증 없음** 경고).
- **다중 에이전트 공유 문서의 명시적 경고**:
  - "A session identifier organizes records. It does not by itself make a conversation private from another caller with access to the same backend."
  - 테넌시 경계는 NAMS workspace / Bolt DB·자격증명. 그 안에서 conversation ID는 조직용일 뿐 "must not be described as private agent notebooks".
  - Bolt semantic message search는 `session_id` 인자를 받지만 필터로 적용하지 않음; 결과 페이지 후필터는 "does not create an access-control boundary".
  - 동시 작성자: 해소/dedup은 동시성 정책을 대체하지 못함 — "Decide which application owns an update, retain source evidence".
  - 공유 메모리는 모든 에이전트가 즉시 같은 컨텍스트를 갖게 보장하지 않음(다른 subset 질의, 캐시, 비동기 처리 전 읽기).

## 근거

- Foundation Capital: 정량 근거 없음(투자 논제). 사례 기업은 FC 포트폴리오/관심 기업일 수 있음(이해관계 명시 없음 — 확인 필요).
- ContextOS(vendor-reported, 익명 고객 일화): 규제 대응 감사 팩 **4일 → 15분**; 2분기에 service-impact 예외의 **40%** 가 두 개의 tickets-per-account 임계값에 군집 → 정책 리팩터로 예외량 **약 1/3 감소**. 고객·측정 방법 비공개.
- Neo4j agent-memory: 벤치마크 수치 없음(eval harness 제공만).
- 비판 측(검색 발췌·2차): Labo LLM 요약에 "27% of enterprise knowledge graphs are in production", "Glean took 6 years" 등이 인용되나 원 출처 미확인 → 사용 보류.

## 비판·한계

### 출처에 나온 비판

- **Forrester 블로그("Context Graphs Are A Convergence, Not An Invention")**: 발명이 아니라 수렴 — Atlassian Teamwork Graph(Jira에서 동기·결정 추출), Jeli(PagerDuty 인수, 사후 장애 결정 체인)가 이미 존재. EA가 40년간 쌓은 엔티티 계층(소유·역량) 없이 결정 trace만 쌓으면 "float unmoored"/환각. "**persistence is never the hard part — fidelity is.**" 거버넌스 없으면 "the context graph becomes a write-only log: everything goes in, nothing gets curated, and agents learn from stale precedents." 결정 trace 계층은 provenance·versioning·access control과 "is this trace still valid or has it been superseded?"가 필요. 전화·복도 대화 등 비디지털 결정은 "dark matter".
- **Andrew Antes("great on paper, risky in practice", 2026-01-07)**: 필수 결정 흔적을 모두 포착했는지 확신 불가(불완전 그래프, streetlight effect), 불완전성에서 오는 **교란(confounding)** — 강화된 경로가 실제 원인이 아닌 상관을 학습, trace가 진짜 근거를 반영하는지, 일시적 맥락을 영속화하는 것이 바람직한지.
- **Labo LLM 요약(2차, 원문 미확인)**: Todd Blaschka의 "Logic Gap"(what만 기록, why 아님) + failure triad(identity crisis, hallucinated judgment, context rot); Gartner(Afraz Jaffri) "용어 중복"; Verdantix "immature"; Jessica Talisman "rebranding" 지적.
- ContextOS 스스로: 그래프에 provenance 없으면 "analysis data", 지표 없으면 "logging pipeline" — 자기 경계 설정.

### 자체 평가

- **"decision trace"의 why는 실제로는 '구조화된 근거 참조'** 다: ContextOS가 산문을 배제한 것은 감사 정합성에는 맞지만, Blaschka/Antes가 말한 암묵적 이유(포착되지 않은 맥락)는 여전히 빠진다. 기록되는 것은 "참조된 증거·적용된 정책·승인" — 그것이 실제 인과인지 보장하지 않음.
- **선례 검색(QueryPrecedent)의 위험**: 잘못된/예외적 결정이 선례로 재사용되면 오류가 제도화된다. 선례에 결과(outcome)·사후 평가·폐기(superseded) 표시가 없으면 Tencent식 "틀린 기억의 전파" 문제가 결정 계층에서 재현됨. ContextOS의 Outcome loop가 이 방향이나 구체 메커니즘은 블로그 수준.
- **접근통제의 이중성**: 결정 trace는 민감도가 높다(M&A, 인사, 가격 예외). redaction label·tenant scope가 언급되나, 선례 검색이 "결과는 보여주되 근거 증거는 가리는" 부분 공개를 어떻게 하는지 불명.
- Neo4j는 경계를 정직하게 문서화했지만, 결국 **권한·쓰기 소유권은 앱 책임**으로 넘김 — 조직 메모리로 쓰려면 위에 정책 계층이 필요.
- byte-match replay는 LLM 비결정성 때문에 "판정 계산"이 결정적 정책 엔진일 때만 성립 — LLM 판단이 포함된 결정은 재현 대신 "당시 입력의 재구성"에 그칠 가능성.

## 팀/조직 메모리 설계에 주는 시사점

- **사실 메모리와 결정 메모리를 분리**: "무엇이 참인가"(Zep식 시간형 사실)와 "왜 그렇게 했나"(DecisionRecord)는 생명주기·권한·정정 방식이 다르다. 조직 메모리는 둘 다 필요.
- **원천은 append-only 레코드, 그래프/요약/임베딩은 재생성 가능한 projection**: 정정·재색인·스키마 변경이 원천을 훼손하지 않게 하고, 모든 파생 노드가 `trace_id`/출처를 역참조하게 강제.
- **"no commit without record" 같은 쓰기 불변식**을 공유 메모리 승격에도 적용: 팀 공유 자산으로 승격(=조직적 결정)할 때 승인자·근거·정책 버전이 기록되지 않으면 승격 불가.
- **선례에는 결과·유효성 상태를 필수로**: outcome, superseded/invalidated 표시, 결정 시점 스냅샷 버전 없이 선례를 에이전트에 노출하지 말 것(Forrester의 stale precedent 경고).
- **세션/대화 ID ≠ 권한 경계**(Neo4j): 테넌시는 저장 경계에서, 사용자·역할 권한은 검색 전에 앱/정책 계층에서 집행. 결과 후필터 금지.
- 메모리 품질 지표를 처음부터 계측: missing-evidence율, 미해결 충돌 비율, 선례 hit/수용률, 정정 지연 등.

## 다른 개념과의 연결

- **Zep/Graphiti**: Graphiti README도 자신을 "temporal context graph"라 칭함 — 같은 용어의 두 의미(사실 시간 이력 vs 결정 lineage). ContextOS의 edge 메타데이터(event time, valid time)는 Zep의 bi-temporal 모델과 정합(→ zep-graphiti-2501.13956.md).
- **Asana AWM**: Bose가 Work Graph를 "context graph"/"shared company brain"이라 부르고, 작업 완료 시 프로젝트·목표에 미친 영향을 기록 — 경량 decision trace. 권한 상속 설계는 ContextOS의 access constraints 요구와 맞물림(→ asana-awm.md).
- **Tencent Team Memory**: Skill 리뷰·공유 승격, 자산 version/status는 결정 레코드화 대상. Tencent에 없는 "왜 이 자산이 정본인가" 계층을 decision record가 채울 수 있음(→ tencent-team-memory.md).
- **Neo4j reasoning memory ↔ ContextOS DecisionRecord**: 전자는 범용 실행 기록(steps/tool calls/observations/outcomes), 후자는 정책·승인·증거 해시가 있는 감사 계약. 전자를 후자 수준으로 끌어올리려면 정책 버전·승인 이벤트·해시체인 추가 필요.
- **Governed Memory 논문(arXiv 2603.17787)**: VentureBeat가 인용한 공유 메모리 거버넌스 위험 — 별도 확인 대상.

## 확인 필요

- Foundation Capital 에세이에 언급된 Regie·Maximor·PlayerZero·Arize와 FC의 투자 관계(이해상충 여부).
- ContextOS 문서 `docs/implementation/decision-record`의 정식 스키마(필드 필수/선택, 서명 방식), "Promotion-Aware Memory" 포스트의 메모리 승격 규칙.
- ContextOS 고객 사례(4일→15분, 예외 1/3 감소)의 고객명·측정 방법.
- Todd Blaschka "Context Graph Hype: Why the Holy Grail is Leaking", Gartner(Afraz Jaffri), Verdantix 원문 — 현재는 Labo LLM 2차 요약으로만 확인.
- Neo4j agent-memory의 reasoning trace 스키마(`TraceOutcome` 필드)와 `how-to/multi-tenancy`, `explanation/resolution-deduplication` 문서의 review workflow 유무.
- Forrester 블로그 저자명·게시일(본문 추출에서 미확인; ServiceNow Context Engine 발표 주간 = 2026-04 무렵으로 추정되나 미검증).
