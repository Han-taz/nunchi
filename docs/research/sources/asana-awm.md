---
title: "Asana Agentic Work Management(AWM) / AI Teammates — 공유 메모리와 권한 상속"
source_owner: "Asana (Engineering blog, 제품 페이지) / VentureBeat (Ben Dickson, Taryn Plumb)"
urls:
  - https://asana.com/inside-asana/ai-teammates-turn-work-into-reusable-information
  - https://asana.com/product/ai/ai-teammates
  - https://venturebeat.com/orchestration/asanas-ai-agents-share-memory-across-your-company-but-not-your-secrets
  - https://venturebeat.com/orchestration/shared-memory-is-the-missing-layer-in-ai-orchestration
accessed: 2026-10-12
type: "벤더 엔지니어링 블로그(1차) + 벤더 제품 페이지(1차, 마케팅) + 컨퍼런스 발언 보도(2차)"
read_status: "Asana 엔지니어링 블로그(2026-04-02, Anant Tibrewal) 전문, VentureBeat 기사 2건 전문 읽음. 제품 페이지는 memory/permission 관련 문장만 grep. help.asana.com 'AI features and admin controls' 문서, FedEx 케이스 스터디, VB Transform 영상은 미확인."
---

# Asana AWM / AI Teammates — 공유 메모리

## 한 줄 요약

Asana는 18년 된 Work Graph(task→project→portfolio→goal) 위에 AI Teammates를 "멀티플레이어 팀원"으로 올리고, 실행에서 추론(inferred)하거나 사용자가 명시(explicit)한 메모리를 Work Graph 객체에 "Memory Association"으로 연결해, **메모리 접근을 원 작업의 권한에 상속시키고 실행을 트리거한 사용자 기준으로 스코프**하며, 사용자가 메모리를 조회·삭제·추적할 수 있게 한다(벤더 설명).

## 핵심 설계/주장

### 기반: Work Graph

- VentureBeat(2026-08-03, VB Transform 2026 CPO Arnab Bose 대담): AWM은 18년 된 **Work Graph** 위에 구축. 구조는 "Pyramid of Clarity" — 최소 단위 task(assignee + due date) → project → portfolio → company-wide goal. "who does what, by when, and why"의 실시간 원장.
- Bose: 에이전트가 "particular individual's markdown file system"이 아니라 "shared ledger for the whole company"에서 작업.
- 에이전트는 "acting on behalf of someone"이 아니라 **팀원으로 현현**하며 "all of the same sharing permissions"을 상속(2026-02 VB 기사, Bose).

### 메모리 생성 (Asana 엔지니어링 블로그)

- **Inferred memory**: 실행 중/후에 지시·자원·행동·피드백에서 내구성 있는 것만 추출. 예: 피드백 "always copy the data model reviewer on these tasks", 프로젝트를 읽고 "Project X contains resources about the organization's marketing campaign best practices".
- **Explicit memory**: 사용자가 직접 지침 제공. 특히 **resource-linked memory** — 문서에 접근권을 준 뒤 그 문서의 역할을 설명(프로세스 문서 / 도메인 참조 문서 / 향후 작업을 형성할 템플릿). "the same source material can be used very differently depending on the user's intent."
- **Memory Association**: 메모리 생성 시 그 메모리가 다루는/관련된 Work Graph 객체(프로젝트, 업로드된 Google Doc 등)에 대한 참조를 생성. 메모리는 "a concrete object with content, metadata, and associations".
- VB(Bose): "Asana engineered a system of access controls to govern what triggers the creation of a memory versus the simple execution of a task." (메모리 생성 트리거 자체가 통제 대상)

### 회상: 2-lane retrieval

1. **Execution-start retrieval**: 작업 시작 시 pinned instructions(항상 적용), 현재 작업과 맞는 과거 학습, 검색/의미 유사도로 관련된 상위 지식을 먼저 받음.
2. **Contextual retrieval during execution**: 특정 task/project 등 객체를 읽을 때 그 객체에 연결된(associated) 메모리를 추가로 받음.

### 접근 통제 (핵심)

- "**memory in AI Teammates has to inherit the same access-control logic as the work it came from.**"
- "Every memory retrieval is scoped to whoever triggered the execution. The Teammate can only access a memory if that person has visibility into the work that produced it — the tasks, comments, documents, or projects involved."
- Association도 동일: 메모리가 참조하는 Asana 객체를 트리거 사용자가 볼 수 있을 때만 노출. "an AI Teammate never sees anything the person who kicked it off couldn't already see."
- VB에서 Bose의 사례: 임원이 비밀 M&A 프로젝트에서 같은 Teammate로 만든 메모리를, 그 프로젝트 접근권 없는 직원이 같은 Teammate를 돌릴 때 활용할 수 없어야 함.
- 제품 페이지: "Every AI Teammate has an identity, scoped permissions, spend controls, and an audit trail, and every action is checkpointable and reversible. They can only access what the triggering user already has permission to see."

### 투명성·정정

- 사용자는 Teammate가 가진 메모리를 **조회**하고 부정확/낡은 것을 **삭제**할 수 있음. 실행 시 **어떤 메모리가 컨텍스트로 전달됐고 어떤 메모리가 새로 생성됐는지** 표시 가능.
- 수정 경로: "edit the memory, remove it, refresh the source, or add better guidance." 예: 다른 팀원의 지난주 피드백에서 배운 서식 선호를 확인하고 수정/삭제.
- 2026-02 VB(Bose): 체크포인트에서 사람이 피드백·수정 요청, "very human-readable way"로 기록. 승인된 관리자는 상충 지시·이상 행동 시 pause/edit/redirect 가능; "The person with edit rights can delete those things that are conflicting and make it go back to its correct behavior."

### 기타 운영 설계 (VB 2026-08)

- 동적 모델 라우팅(복잡 작업은 Opus/OpenAI 프런티어 모델, 가벼운 작업은 저가 모델), 과금은 task 완료당 고정 비용.
- 작업 완료 시 메타데이터 기록: 완료가 프로젝트 상태를 개선했는지, 상위 목표를 어떻게 움직였는지.
- CoreWeave 사례: 결정적 AI Studio 워크플로 규칙 + 다수 AI Teammates로 제품 런칭(PRD 문서 → 프로젝트 구조 자동 생성 → 상태 감시 에이전트 / 인프라 비용 예측·승인 추천 에이전트).
- 2026-02 VB: 12개 사전 구축 에이전트(당시), 현 제품 페이지는 "30+ prebuilt AI Teammates". Bose는 "no standard protocol around shared knowledge and memory" — 파트너 연동이 "custom bespoke conversation"이라고 언급; 승인된 에이전트의 권위 있는 목록("active directory or universal directory of agents") 필요성 제기.

## 근거

- 정량 벤치마크·평가 수치 **없음**. 모든 설계 설명은 벤더 자기기술.
- 프로덕션 주장(vendor-reported): Bose — "several customers live and successful on it", FedEx 케이스 스터디 발행(미확인), CoreWeave 얼리어답터.
- 제품 페이지의 REWE "reporting overhead 6 hours 절감"(마케팅 문구, 메모리 효과와 직접 연결되지 않음).

## 비판·한계

### 출처에 나온 비판/긴장

- VentureBeat(Tencent 기사, 2026-08-07)는 Asana를 Team Memory의 가장 가까운 비교 대상으로 들며, Asana가 이미 "one agent's memory from leaking into a project another agent isn't cleared to see" 문제를 겪었다고 서술 — 즉 **누출 방지(읽기)** 는 다루지만, Tencent 기사가 제기한 정정·만료·충돌 문제에 대해 Asana가 별도 메커니즘을 설명한 바는 없다.
- Bose 스스로 공유 메모리·지식에 대한 표준 프로토콜 부재, OAuth 권한 부여에 대한 지식 노동자의 이해 부족을 과제로 인정.
- "frenemy" 문제: 기반 모델 공급자(Anthropic, OpenAI)가 경쟁 에이전트 제품도 출시.

### 자체 평가

- **트리거 사용자 기준 스코프의 부작용**: 같은 Teammate라도 누가 실행하느냐에 따라 보이는 메모리가 달라져 행동이 비결정적으로 보일 수 있다. 또한 "메모리를 만든 근거 작업"이 여러 객체에 걸칠 때 교집합/합집합 중 어떤 규칙인지 블로그에 명시되지 않음.
- **파생 메모리 누출 경로**: 추론된 메모리가 원 객체의 텍스트를 일반화("이 고객사는 할인에 민감")해 association 없이 저장되면 권한 상속이 깨질 수 있음 — association 강제 여부/누락 시 기본 동작 불명.
- **정정 = 삭제/편집 중심, 시간성 없음**: 만료(TTL), 유효기간, 충돌 자동 탐지, 버전 이력에 대한 언급 없음. "다른 팀원의 피드백에서 배운 선호"처럼 **다수 주체의 상충 피드백** 해소 규칙(누구의 피드백이 우선?)이 기술되지 않음.
- 폐쇄형 플랫폼이라 Work Graph 밖(Slack, 이메일, 회의)에서 일어난 결정은 association 대상이 되기 어렵다.
- 메모리 품질/효용의 정량 평가 부재.

## 팀/조직 메모리 설계에 주는 시사점

- **권한 상속(provenance-bound ACL)**: 메모리의 접근권을 별도 라벨이 아니라 "그 메모리를 만든 원천 객체들의 권한"에서 파생시키는 모델은 다중 주체 조직에서 가장 강한 누출 방지 원칙. 이를 위해 모든 메모리에 원천 객체 참조(association)를 필수로 둬야 한다.
- **실행 주체 = 권한 주체**: 에이전트 고유 권한이 아니라 "트리거한 사람의 가시성 ∩ 메모리 원천 가시성"으로 회상 범위를 정하는 것이 confused-deputy 문제를 줄인다.
- **메모리 생성 트리거도 통제 대상**: 어떤 행위가 메모리를 만들 수 있는지(실행만 vs 학습)를 정책화.
- **2-lane 회상**(시작 시 pinned/관련 메모리 + 객체 접근 시 연관 메모리)은 컨텍스트 예산과 관련성의 균형 패턴으로 재사용 가치가 높다.
- **실행별 메모리 사용/생성 내역 노출**은 디버깅·신뢰의 필수 UX — "why did the AI do that?"을 특정 메모리로 환원.
- 다수 주체 피드백 충돌, 만료, 정본성은 별도로 설계해야 할 공백(Zep식 bi-temporal 또는 decision record와 결합 검토).

## 다른 개념과의 연결

- **Tencent Team Memory**: 자산별 visibility 라벨(private/team/restricted/agent) vs Asana의 원천 권한 상속. Tencent는 이식성/오픈소스, Asana는 Work Graph 결합(→ tencent-team-memory.md).
- **Context graph / decision traces**: Bose가 Work Graph를 "context graph"/"shared company brain"이라 부름. 작업 완료 메타데이터(상태·목표에 미친 영향) 기록은 decision trace의 경량 버전(→ context-graphs-decision-traces.md). Forrester는 Atlassian Teamwork Graph를 유사 사례로 언급.
- **Zep/Graphiti**: Asana 메모리에는 없는 시간 유효성·무효화 모델 보완 가능(→ zep-graphiti-2501.13956.md).
- **Neo4j agent-memory**: "conversation ID는 권한 경계가 아니다"라는 Neo4j 경고와, Asana의 "검색 자체를 트리거 사용자 권한으로 스코프" 설계가 같은 교훈.

## 확인 필요

- help.asana.com "Asana AI features and admin controls" 문서: 관리자가 메모리 생성/보존/삭제 정책을 조직 단위로 설정할 수 있는지, 감사 로그에 메모리 사용이 기록되는지.
- 메모리가 여러 원천 객체에 association될 때 접근 규칙이 "모두 볼 수 있어야(AND)"인지 "하나라도(OR)"인지.
- association이 없는(전역) 메모리 — pinned instructions 등 — 의 가시성 규칙.
- 메모리 편집 이력/버전 관리 및 다른 팀원이 만든 메모리를 누가 편집·삭제할 권한을 가지는지.
- FedEx 케이스 스터디 원문과 메모리 관련 정량 효과 유무.
