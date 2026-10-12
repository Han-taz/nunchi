---
title: 팀·조직용 에이전트 메모리 — 최근 동향과 수렴하는 개념 (원문 정독 기반 종합)
date: 2026-10-12
scope: 개인 비서가 아니라 회사/팀(multi-principal, multi-agent) 환경의 에이전트 메모리 구조
sources: sources/ 디렉터리의 출처 노트 19개 (논문 11편, 업계 1차 자료 8묶음)
status: v1
---

# 팀·조직용 에이전트 메모리 — 수렴하는 개념 종합

## 0. 결론 요약

개인 비서 메모리의 핵심 질문은 "얼마나 잘 기억하나"(recall)였다. 팀/조직 메모리에서는 질문이 바뀌었다.

- 누가 무엇을 볼 수 있나 (권한)
- 어느 버전이 지금 유효한가 (시간, 정정)
- 어디서 와서 무엇으로 파생됐나 (출처, 계보)
- 오염되면 어떻게 막고 되돌리나 (게이트, 롤백)

원문을 읽어 보면 업계와 학계가 이 질문들에 대해 **같은 형태의 답**으로 모이고 있다. 다만 일부 영역은 아직 아무도 제대로 못 풀었다는 점도 분명해진다. 특히 정정 전파, 일관성, 삭제 의미론이 그렇다.

수렴 강도는 아래처럼 표시한다.

- ●●● 여러 독립 출처가 같은 형태로 수렴. 사실상 표준.
- ●●○ 방향은 같지만 구현과 의미론이 갈림.
- ●○○ 주장은 강하지만 근거가 약하거나 소수 출처에 그침.

## 1. 수렴하는 개념 9가지

### 1.1 범위(scope) 계층 + 기본 비공개 + 명시적 공유 — ●●●

거의 모든 시스템이 개인/에이전트 → 세션 → 프로젝트 → 팀 → 조직/테넌트 계층을 쓴다.

| 시스템 | 범위 표현 | 비고 |
|---|---|---|
| AWS AgentCore | `/org/{org}/team/{team}/actor/{actorId}/session/{sessionId}/` 형태의 namespace | 커스텀 변수는 리소스당 5개, 허용값/정규식 검증. 조회는 `namespace`(정확 일치)와 `namespacePath`(하위 트리) 두 방식 [aws-agentcore-memory] |
| Claude Managed Agents | 워크스페이스 단위 memory store를 세션당 최대 8개까지 연결 | 권장 패턴: 조직 store는 read_only, 사용자/팀 store는 read_write [claude-managed-agents-memory] |
| Tencent Team Memory | private / team / restricted / agent 4단계 (Panel API에는 문서화 안 된 `task` 값도 있음) | 새로 만든 Chat Memory와 Skill은 기본 private. private는 팀 관리자도 못 봄 [tencent-team-memory] |
| Databricks (현행 Beta) | `actor_id`(사용자 / 팀·조직 고정 키 / `{tenant}:{user}` 합성) + 선택적 session + path | 문서: "actor_id는 접근 제어가 아니다", **"보안 경계는 actor가 아니라 store"** [databricks-managed-memory] |
| Letta | 에이전트가 소유한 MemFS + 조직 소유 shared memory repository를 attach | 문서상 권한 모델은 attach 여부뿐 [letta-memfs] |
| Collaborative Memory (논문) | private / shared 2계층 + 시간에 따라 바뀌는 user–agent–resource 이분 그래프 | 읽기 시점에 현재 권한으로 재검사 [collaborative-memory-2505.18279] |

**원문 정독에서 새로 드러난 점**

- **범위(scope)와 권한(authorization)은 다르다.** Databricks는 actor로 나눈 범위가 접근 제어가 아니라고 명시한다. Neo4j agent-memory도 "세션/대화 ID는 접근 제어 경계가 아니다", "쿼리 후 필터링은 경계가 아니다"라고 경고한다. AkasicMEM은 같은 공유 에이전트 범위 안에서도 Alice의 권한으로 만든 메모리를 Bob이 꺼내는 누수를 핵심 사례로 든다. → 범위는 정리 수단이고, 강제는 store/DB/IAM 계층이 따로 해야 한다.
- **범위는 모델이 정하지 않는다.** Databricks: "Never let the model choose whose memory to read or write". 신원이 없는 요청은 공유 범위로 흘려보내지 말고 거부한다.
- **AWS의 함정:** 커스텀 namespace 변수가 빠지면 long-term 추출이 **조용히 건너뛰어지고** CreateEvent는 성공한다. `NamespaceResolutionFailure` 지표를 모니터링해야 한다.
- 이 계층 구조는 범위가 **정리(consolidation)의 경계**도 된다. AgentCore는 같은 namespace 안에서만 병합한다. 범위를 잘못 설계하면 지식 병합 단위도 함께 틀어진다.

### 1.2 메모리 = 파일/문서 + 불변 버전 기록 — ●●●

- **Claude:** store를 `/mnt/memory/<slug>/`로 마운트하고 전용 메모리 툴 없이 일반 파일 툴로 읽고 쓴다. 변경마다 불변 `memver_`가 생기고, memory를 지워도 store 쪽 버전은 남는다. redact는 되지만(현재 head 버전은 불가), restore 엔드포인트는 없어서 옛 버전 내용을 다시 써넣는 식으로 롤백한다. **버전 보관은 30일**이라 장기 감사에는 export가 필요하다.
- **Letta:** 2026-03에 서버 쪽 메모리 툴(`core_memory_replace` 등)을 폐기하고 git 기반 MemFS로 완전히 옮겼다. 편집은 commit/push가 돼야 메모리로 인정된다. 조직 shared repository도 쓰기마다 commit SHA를 돌려주고 `contentSha256` 선조건을 건다.
- **Tencent:** Skill에 버전이 있고 리뷰를 거쳐 팀에 공유한다. 반면 Chat Memory L1~L3 편집은 v2.0.1 예정이고, 지금 패널은 조회와 삭제만 된다.
- **ContextOS(결정 기록):** append-only + trace_id별 해시 체인.

**의미:** 감사(누가 언제 무엇을 바꿨나), 롤백, 사람의 리뷰가 가능한 형태로 수렴 중이다. 다만 "버전이 있다"는 것과 "정정이 전파된다"는 것은 별개다(→ 3장).

### 1.3 Progressive disclosure: 목록은 항상, 본문은 필요할 때 — ●●●

- Letta: 루트(또는 구버전/SDK에서는 `system/`) 파일은 매 턴 로드한다. 하위 디렉터리의 본문은 필요할 때 읽고, 그 전까지는 frontmatter의 description만 노출한다.
- Claude: 마운트별 설명(이름, 경로, 접근 모드, instructions 최대 4,096자)만 시스템 프롬프트에 자동 주입한다.
- Tencent: Wiki와 CodeGraph는 `/v3/tools/call`로 필요할 때 호출한다. Agent Loadout은 고정 바인딩 + ACL로 먼저 좁힌 뒤 검색한다.
- 스킬 생태계도 같은 원리다(→ 1.4).

### 1.4 절차 메모리 = 버전·검증·채택 관문을 거치는 skill — ●●○

- 2026 서베이(2602.06052, v4)는 skill을 **명시적이고 이식 가능하며 버전 관리되는 절차 메모리**로 본다(Voyager → Agent Skills, revise/merge/retire). 단서도 단다. 에이전트가 스스로 만든 skill은 사람이 다듬은 것보다 성능이 낮고, 커뮤니티 skill에는 취약점이 많다.
- Dynamic Skills 서베이(2607.10113)는 수명주기 8단계를 제시한다: evidence → proposal → **verification/admission** → storage → retrieval/composition → maintenance → distillation/portability → governance/provenance.
  - **채택 관문이 핵심 선택 메커니즘**이다. 관문은 tentative → quarantined → promoted → demoted/rolled back 단계로 바뀌는 중이다. 예: PSN은 최근 3개 작업 성공률이 20% 넘게 떨어지면 롤백한다. CoEvoSkills는 검증기를 빼면 통과율이 71.1% → 41.1%로 떨어진다.
  - 단순(flat) 검색은 라이브러리가 커질수록 나빠진다: skill 64개 92%, 128개 78%, 256개 64%.
  - **쓰였다고 도움이 된 건 아니다:** Kimi는 skill 사용률 66.87%인데 점수는 +0.60에 그쳤고, GPT 5.3 Codex는 −6.02였다(SkillFlow-Bench).
  - **보안:** skill 파일이 공격 성공률(ASR)이 가장 높은 인젝션 경로였다(평균 69.4%, ClawSafety). 레지스트리 skill 31,132개 중 26.1%에 취약 패턴이 있었다.
- 수렴은 강하지만, 팀 간 skill 공유 메커니즘(SkillClaw의 push, AutoSkill의 이중 리뷰)은 서베이에서 분류 수준으로만 다뤄진다.

### 1.5 시간 의미론: 지우지 않고 무효화 — ●●○

- Zep/Graphiti: 시간축 두 개(T = 사건 시간, T' = 수집 시간). 엣지마다 타임스탬프 4개(`t'_created`, `t'_expired`, `t_valid`, `t_invalid`)를 둔다. LLM이 모순을 판정하고, 시간이 겹치면 옛 엣지의 `t_invalid`를 새 엣지의 `t_valid`로 닫는다. **T'에서 더 새로운 정보가 항상 이긴다.**
- Governed Memory는 충돌을 최신성 감쇠(반감기 38일)로만 처리한다. 그 결과 충돌 감지는 83.3%인데 **오래된 주장을 엄격히 억제하는 비율은 33.3%**에 그친다.
- **팀 환경의 함정:** "최신이 이긴다"는 다수 주체 조직에서 위험하다. 신뢰도 낮은 출처의 최신 발언이 공식 사실을 무효화할 수 있다. 조직 메모리에는 시간뿐 아니라 **출처의 권위(authority)**가 충돌 해결 규칙에 들어가야 한다. 이 부분은 아직 어느 시스템도 정식화하지 않았다.

### 1.6 출처/계보와 권한 연속성(authorization continuity) — ●●○ (학계 강함, 업계는 Asana식 상속)

팀 메모리 고유의 가장 중요한 개념이다. 원문을 보면 접근 방식이 셋으로 갈린다.

1. **원천 권한 상속 (Asana):** 메모리는 "만들어진 원천 작업과 같은 접근 제어 로직을 상속"한다. 모든 검색은 실행을 시킨 사용자로 범위가 정해진다. 메모리마다 Work Graph 객체를 가리키는 Memory Associations가 붙는다. 이미 권한 그래프를 가진 플랫폼이라 가능한 방식이다.
2. **계보 교집합 (AkasicMEM):** 실효 권한을 A(m) = R(m) ∩ ⋂ R(조상 x)로 정의한다. 원천의 R은 **원천 시스템의 현재 정책**이다. 계보 그래프는 늘어나기만 하고, 메모리를 지워도 노드 정체성은 남긴다. 정책이 바뀌면 하위 메모리를 stale로 표시하고, 다음에 후보로 올라올 때 다시 계산한다. 정책 검사는 DB 안에서 하나의 쿼리로 끝나서 내용이 에이전트에 닿기 전에 걸러진다. **실험은 없다(설계 논문).**
3. **컬럼 단위 계보 게이트 (AMU, 2610.07258):** 캐시된 분석 결과마다 계보 L = (table, columns, filter) 단계를 기록한다. S(a) ⊆ P(dept)일 때만 재사용을 허용하고, 추출에 실패하면 최대 민감으로 취급한다(fail-closed). 누수 0%는 **계보가 완전하다는 전제의 정리**이고, 계보 완전도 ρ가 0.9 미만이면 보장이 무너진다(ρ=0.5에서 누수 16.3% / 10.3%). 재사용률은 13~14%p 손해를 본다.

보조 근거:

- Collaborative Memory: 조각마다 불변 출처 정보(시간, 사용자, 에이전트, 리소스)를 붙이고 읽을 때 현재 그래프로 재검사한다. 단, 출처는 **한 단계뿐**이라 파생에 파생을 거친 계보는 안 다룬다. "provable"이라고 주장하지만 **정리와 증명이 없다.** shared 계층의 사용자 정보 제거는 LLM 재작성에 의존해 확률적이다.
- Governed Memory: 실제 범위는 `orgId` 하드 파티션 + CRM 엔티티 키 둘뿐이다. **팀/역할/사용자 가시성 필드도, 작성 주체 필드도 없다.** 누수 0이라는 주장은 초록(500 쿼리)과 본문(3,800 결과)이 맞지 않는다.

**종합:** 방향은 "권한은 메모리에서 새로 만들지 말고 원천에서 끌고 오고, 파생될 때도 끊기지 않게 한다"로 모인다. 다만 업계 구현은 Asana처럼 기존 권한 그래프가 있는 곳에 한정되고, 학계 구현은 증명 전제(계보 완전성)나 정량 평가가 약하다.

### 1.7 결정 기록 / context graph — ●○○ (주장 강함, 근거 약함)

- Foundation Capital(2025-12-22)은 규칙("일반적으로 어떻게 해야 하나")과 결정 기록(예외, override, 선례, 승인, 시스템을 넘나드는 맥락)을 구분한다. 근거로 내세우는 건 "에이전트는 실행 경로에 있고 데이터 웨어하우스는 ETL 뒤 읽기 경로만 본다"는 구조적 주장이다. **정량 근거는 없다.**
- ContextOS: DecisionRecord가 원본이고 그래프는 거기서 만든 사본(projection)이다. API 4개: `EmitDecisionRecord`("기록 없이는 커밋 없음"), `QueryPrecedent`, `ReplayDecision`(저장된 기록과 바이트 단위로 일치해야 함), `AuditDecisionLineage`. 근거는 고객명과 방법이 없는 벤더 일화뿐이다.
- Neo4j agent-memory: short-term / long-term(POLE+O 엔티티 그래프) / **reasoning memory**(단계, 툴 호출, 관찰, 결과) 3층. "모델 내부 추론에 접근하는 게 아님"을 명시한다.
- 비판(Forrester): "persistence is never the hard part — fidelity is". 엔티티 정합과 거버넌스가 없으면 그래프는 "쓰기만 하는 로그"가 되고 오래된 선례를 학습한다.
- **실무 시사점:** 설계 패턴 자체(append-only 결정 기록을 원본으로, 그래프는 재생성 가능한 사본으로)는 감사와 재현 측면에서 타당하다. "조 단위 시장"류 주장은 걸러서 본다.

### 1.8 생애주기 게이트: 쓰기 / 조회 / 승격 / 다른 에이전트 재사용 — ●●○

- **MAPLE-Guard:** 메모리 링크를 write → retrieve → promote → cross-agent reuse로 모델링하고 전이 4곳에 LLM 없는 결정적 게이트를 둔다. 메타데이터(scope, provenance, lifecycle, taint, trust, utility)는 LLM에게 보이지 않는다.
  - **승격 게이트를 빼면 성능이 가장 크게 떨어진다**(LongMemEval MDSR 73.6 → 60.0, RDA 0.9 → 14.5). 승격 임계값(위험 0.34, trust < 0.62면 차단)이 조회 임계값(0.48)보다 엄격하다.
  - 조회 시점에만 필터링하면 65.0 / 21.6으로, 전체(88.4 / 0.1)보다 훨씬 나쁘다.
  - 단서: 위험 점수가 대부분 키워드 패턴이고, 적응형 공격자는 평가 안 했고, 성능 상당 부분이 정답 라벨 피드백에 의존한다.
- **Memory-hopping (2609.35576):** 공유 메모리도 통신 채널도 없는 독립 어시스턴트들이 **일반 공유 파일**(artifact → MEMORY.md → 새 artifact)만으로 감염된다. 30-에이전트 환경에서 60~100%가 감염되고 최장 8홉까지 간다. 감염 상위 20%가 전파의 69%를 일으킨다. **메모리 쓰기 분류기**(지시가 사용자가 아닌 다른 주체에게서 왔나?)는 오탐을 24 → 4로 줄이고 recall 1.0을 유지했지만, 지시가 없는 거짓 믿음은 5개 중 1개만 잡았다. 사고 대응에는 메모리 롤백 + artifact 계보 추적이 필요하다.
- **Misattribution Gap (2605.22842):** 정책처럼 꾸민 문서 하나가 공유 벡터 스토어에서 권위로 재등장한다(Trust Laundering). 분류기 4개 모두 탐지하지 못했고, 로그 기반 귀인 도구는 메모리 공격 64건 전부를 "모델 문제"로 판정했다. 방어책 MP-IFC(store 메타데이터에 'external' 라벨 유지)는 97.3%를 차단했다. **⚠ 신뢰도 주의:** 하위 에이전트 정독에서 초록과 본문 수치 불일치(510 vs 508 체크포인트 등), 동어반복에 가까운 증명, 표 합계 불일치가 지적됐다. 방향성 참고용으로만 쓴다.
- Claude 문서: 공유 참조 자료는 read_only로 두라고 권장한다. (이전 검색 스니펫의 docs.anthropic.com 판에는 "신뢰할 수 없는 입력을 처리하면 프롬프트 인젝션이 store에 악성 내용을 쓸 수 있다"는 경고가 있었다. 하위 에이전트가 읽은 docs.claude.com 현행 판에는 명시적 경고가 없었다고 보고됨 → 문서 판 차이, 확인 필요.)

**종합:** "private → shared 승격"을 핵심 검문 지점으로 삼는 설계가 가장 근거가 좋다. 그리고 출처/오염 라벨(taint)이 **요약이나 정리 과정에서 세탁되지 않아야** 한다. 요약을 거친 라벨 세탁은 Misattribution 논문이 남긴 미해결 과제로 직접 명시돼 있다.

### 1.9 오프라인 정리(dreaming / reflection / defrag) — ●●●

- Claude Dreams: 입력은 store 1개 + 세션 1~100개, 출력은 **새 store**이고 원본은 절대 수정하지 않는다. 비동기 작업이며 instructions로 방향을 줄 수 있다.
- Letta: dreaming(트리거: 꺼짐 / 스텝 수 / 압축 이벤트), memory doctor, defrag(먼저 백업한 뒤 15~25개 집중 파일로 재정리). 모두 git worktree에서 실행 후 merge한다. "적용 전 리뷰"는 사용자 승인이 아니라 두 번째 에이전트의 리뷰다.
- AgentCore episodic: extraction → consolidation → reflection. **reflection은 여러 actor에 걸칠 수 있어서** 문서가 프라이버시 경고를 한다.
- Governed Memory: 쓰기 시 cosine ≥ 0.92면 건너뛰고, 백그라운드에서 ≥ 0.95면 병합한다.

**팀 관점 핵심:** 정리 작업 자체가 범위를 넘나드는 정보 흐름이 될 수 있다(AgentCore 경고). AkasicMEM은 "정리된 메모리일수록 유용하지만 조상이 많아져 권한이 더 좁아지는" 역설을 미해결로 남긴다. Claude처럼 **원본을 고치지 않고 새 store를 출력하는** 방식이 감사와 롤백 측면에서 가장 안전하다.

## 2. 첫 답변에서 정정할 내용

| 첫 답변 | 원문 확인 결과 |
|---|---|
| Databricks는 Unity Catalog securable로 관리 | **legacy로 곧 종료 예정.** 현행 Beta는 Lakebase 기반 workspace store, 검색은 BM25뿐. 항목/actor 단위 ACL은 없고 store가 경계다. |
| Claude는 여러 에이전트가 동시에 써도 서로 덮어쓰지 않음 | 블로그 주장이다. API update는 `content_sha256` 선조건(낙관적 잠금)이 있지만, 에이전트가 파일 툴로 쓸 때도 같은 보호가 되는지는 문서에 없다. store 한도는 10,000 memories, 버전 보관 30일. |
| Governed Memory: 적대적 쿼리 500개에서 교차 엔티티 누수 0 | 초록(500)과 본문(3,800 결과) 불일치. 팀/역할/사용자 범위가 아예 없다. 전체 시스템(85.9)이 일부만 쓴 구성(86.4)보다 낮게 나왔다. |
| Collaborative Memory: 정책 준수를 증명 | 정리와 증명이 없다. 출처는 한 단계뿐이다. |
| 2602.06052 서베이 저자 Zhao, Wang, Zou | v1("Rethinking Memory Mechanisms…")과 v4(2026-08-04) 사이에 제목과 저자 구성이 바뀌었다. v4의 1저자는 Wei-Chieh Huang 외 약 60명이다. |
| Tencent 4단계 가시성 | Panel API에는 문서화 안 된 `task` 값도 있다. 이미 퍼진 틀린 사실에 대한 정정, 만료, 충돌 해결 절차가 없다는 건 ROADMAP에서 사실상 인정한다(편집은 v2.0.1 예정). |
| 2603.10062가 일관성을 제일 시급하다고 지적 | 맞다. 다만 본문 약 2쪽짜리 position paper로 실험이 없다. 접근 제어를 에이전트 간 관계로만 다루고, 사람 주체, 삭제, 감사는 범위 밖이다. |

## 3. 아직 아무도 못 푼 문제 (연구 기회)

1. **정정 전파.** 틀린 사실이 다른 에이전트의 파생 메모리나 산출물로 이미 퍼졌을 때 이를 추적해 되돌리는 절차. 계보는 AkasicMEM, MAPLE-Guard, memory-hopping 모두 필요하다고 말하지만, 정정을 하위로 전파하는 실제 메커니즘은 없다.
2. **다중 에이전트 일관성 모델.** 쓰기가 언제 다른 에이전트에게 보이나(visibility/ordering), 읽는 시점의 충돌은 어떻게 해결하나. 정식 정의도, 위반 감지 방법도 없다(2603.10062). 실무 대용품은 git worktree + merge(Letta), SHA 선조건(Claude, Letta) 정도다.
3. **권위를 반영한 충돌 해결.** "최신이 이긴다"(Zep), "최신성 감쇠"(Governed Memory)를 넘어 출처 신뢰도와 역할 권위를 반영하는 규칙.
4. **삭제의 의미론.** GateMem(2,218 체크포인트, 4개 도메인)에서 효용 / 접근 제어 / 망각을 동시에 잘하는 방법이 없었다.
   - 전용 메모리 시스템(A-Mem, Mem0, ReMem)이 단순 baseline을 못 이겼다. Mem0는 삭제된 지시를 그대로 확인해줬고, 여러 시스템이 answer_redacted라고 라벨을 달고도 본문에서 보호 대상 정보를 드러냈다.
   - Long-Context가 대체로 MGS 최고였다(GPT-5.4 4개 도메인 단순 평균 64.8, 하위 에이전트 계산). 다만 에피소드가 짧고(약 5k 토큰), 정책을 자연어 프롬프트로만 주입했으며, ACL이나 tombstone을 쓴 baseline이 하나도 없다. → **결정적 ACL + tombstone baseline이 빠져 있다는 게 그 자체로 연구 공백이다.**
   - AkasicMEM은 "지워도 계보 노드는 남긴다"를 택했다. 삭제 요청과 감사 보존 사이의 긴장은 미해결이다.
5. **평가 체계.** 2602.06052 서베이가 정리한 벤치마크 중 다수 주체 접근 제어나 삭제 요청 준수를 시험하는 것은 없다. GateMem이 거의 유일하고, 그것도 "사람 여럿이 어시스턴트 하나를 공유"하는 설정이지 에이전트 여럿이 동시에 쓰는 설정이 아니다.
6. **공유 메모리 표준 프로토콜.** MCP는 컨텍스트 입출력만 다룬다. 메모리 접근 프로토콜(권한, 범위, 단위)이 없다(2603.10062). Asana CPO도 "표준이 없어서 매번 맞춤 협의"라고 말한다.
7. **정리와 권한의 역설.** 정리된 메모리일수록 조상이 많아져 권한이 좁아지고 쓸모가 줄어든다(AkasicMEM §5). 정리는 범위를 넘는 정보 흐름이 된다(AgentCore 경고).

## 4. 수렴형 참조 아키텍처 (팀/조직용, 초안)

```text
[원천 시스템: 문서/티켓/CRM/코드 — 각자 권한 그래프 보유]
        │ (출처 엣지 기록, 원천 정책 참조)
        ▼
┌──────────────── 메모리 계층 ────────────────┐
│ 1) 결정 기록 (append-only, trace_id 해시체인) │ ← 원본. 그래프/인덱스는 재생성 가능한 사본
│ 2) 사실/엔티티 (bi-temporal, 무효화+권위 규칙) │
│ 3) 절차 (skill: tentative→quarantine→promote) │
│ 4) 작업 메모리 (세션/에이전트 private)         │
└──────────────────────────────────────────────┘
  범위: org / team / project / actor / session — 신뢰 컨텍스트가 주입, 모델이 지정 금지
  강제: store·DB·IAM 계층 (프롬프트 필터 아님), 조회 시 계보 기반 재평가
  게이트: write / retrieve / promote(private→shared, 가장 엄격) / cross-agent reuse
  라벨: provenance·taint는 요약·정리에서 세탁 금지 (보수적 전파)
  정리: 원본 불변, 새 store 출력(Claude Dreams형) + 리뷰 후 교체
  감사: 불변 버전, redact, export(보관 기한 대비), 정정 이벤트를 하위 파생물에 전파
```

## 5. 설계 체크리스트 (연구/설계 리뷰용)

- [ ] 범위 키를 누가 넣나? 모델이 아니라 인증된 호출 컨텍스트여야 한다. 신원이 없으면 거부한다.
- [ ] 범위와 권한이 분리돼 있나? actor/session ID를 경계로 착각하고 있지 않나?
- [ ] 강제가 DB/store/IAM 계층에서 일어나나? 프롬프트나 사후 필터에 의존하지 않나?
- [ ] 파생 메모리의 권한이 원천 권한을 이어받나(계보 교집합)? 원천 권한이 바뀌면 다시 평가되나?
- [ ] private → shared 승격에 별도의 엄격한 게이트가 있나?
- [ ] 외부/비신뢰 출처 라벨이 요약, 정리, skill 추출을 거쳐도 유지되나?
- [ ] 사실 충돌 규칙에 시간 외에 출처 권위가 들어가나?
- [ ] 정정이 일어났을 때 하위 파생물과 산출물을 찾아낼 수 있나(역방향 계보)?
- [ ] 삭제 요청 시 내용 제거, 감사 보존, 재구성 방지를 각각 어떻게 처리하나?
- [ ] 정리 작업이 범위를 넘나? 원본 불변인가?
- [ ] 버전 보관 기한(예: Claude 30일)을 넘는 감사 요구에 export 경로가 있나?
- [ ] 평가에 recall뿐 아니라 접근 제어 / 망각 / 오염 저항 / 다중 에이전트 일관성 지표가 들어가나?

## 6. 출처 신뢰도 메모

- **정량 근거가 있는 논문:** GateMem(사람 검증 κ 0.937~1.0), MAPLE-Guard, memory-hopping, AMU(합성 시뮬레이터, 실제 에이전트 테스트는 9회뿐), Collaborative Memory(시나리오 2는 수치 없음), Zep(벤더 저자).
- **설계/입장 논문(실험 없음):** AkasicMEM, 2603.10062.
- **수치 불일치나 주장 과잉이 지적된 논문:** Governed Memory(초록과 본문 불일치), Misattribution Gap(여러 불일치), Collaborative Memory("provable" 주장).
- **벤더 문서/블로그:** 기능 명세(한도, API)는 신뢰할 수 있고 성능 주장은 자체 보고다(Tencent PersonaMem 48 → 76% 등).
- **context graph 담론:** VC/벤더 주장이 중심이고 정량 근거가 없다.

개별 근거와 섹션 번호는 `sources/` 아래 각 노트에 있다.
