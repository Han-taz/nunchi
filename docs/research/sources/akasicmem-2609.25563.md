---
title: "AkasicMEM: Governed Enterprise Memory for Agents"
arxiv_id: "2609.25563"
authors: "Jeongmin Bae, Yongjae Kim, Kyoung Hur, Donghyoung Han, Min-Soo Kim"
affiliation: "GraphAI, Seoul, Republic of Korea"
date: "2026-09-22 (v1, cs.DB)"
url: "https://arxiv.org/abs/2609.25563"
html: "https://arxiv.org/html/2609.25563"
type: paper
read_status: full
read_note: "HTML 본문 전체(§1–6, 참고문헌) 읽음. HTML 변환에서 §3.1의 't1<t2' 부분이 잘려 PDF 텍스트로 보완. Fig.1–3은 PDF 텍스트 추출로 라벨만 확인. 9쪽 vision/position 성격 논문으로 실험 섹션 자체가 없음."
---

# AkasicMEM (GraphAI, 2609.25563)

## 한 줄 요약

기업 소스(CRM·계약·내부문서)에서 파생된 에이전트 메모리가 **메모리 scope만으로 재사용되면 소스 권한을 우회해 유출된다**는 점을 짚고, 이를 막는 성질을 **authorization continuity**로 정의한 뒤 **transitive lineage(소스→메모리, 메모리→메모리) + 형성 시 정책 합성(교집합) + 검색 시 정책 재평가(lazy)**로 구현하는 설계를 벡터·그래프·관계형 통합 DB(AkasicDB) 위에 제시. **정량 실험 없음.**

## 문제 정의

- §1: Mem0/Letta 등은 개인 비서용. 기업에서는 실행 중 획득한 사실·결정 맥락·실행 결과를 태스크/에이전트 간 재사용하려 함(SAP 코딩 에이전트 조직 메모리, G-Memory 사례 인용). 이를 위해 두 요구가 필요:
  - **Source–memory integration**: 기업 소스(현재 비즈니스 상태·규칙)와 메모리(과거 태스크 지식)를 공통 데이터 관리/검색 아키텍처에서 함께 쓰되 소스와 파생 메모리의 구분은 유지.
  - **Memory governance**: 사용자·에이전트 간 공유 메모리에 접근 정책·수명주기·감사 적용. 공유 ≠ 전면 공개. **Memory scope** = 메모리가 검색·재사용될 수 있는 user/agent/thread/project/team/tenant 경계.
- 두 요구가 만나는 지점: 소스 파생 메모리가 다시 새 메모리를 낳는 동안 요청 principal과 소스 정책이 바뀐다. **scope 멤버십 ≠ 소스 정보 접근 권한**.
- §3.1 예시(Fig.1): t1에 Alice 권한으로 동작하는 공유 기업 에이전트가 소스 s에 접근해 m1 형성, m1에서 m2 파생; 둘 다 "공유 에이전트" scope. t2(t1<t2)에 Bob이 같은 에이전트 호출 → 소스 시스템은 Bob에게 s 접근 거부하지만 scope만 보면 m1/m2가 검색되어 **소스 제한이 메모리를 통해 우회**됨.
- §2.2 Table 1: 기존 시스템을 personal(Letta, Mem0, A-Mem, MIRIX, AgentCore Memory, Memory Bank) / source-integrated(Zep, Oracle Agent Memory) / shared(G-Memory, SAP Org Memory) / governed shared(MemClaw, Collaborative Memory, MAP-Graph)로 분류하고 5개 요구(source–memory integration, memory governance, transitive lineage, policy composition, policy re-evaluation)를 Core/Partial/–로 평가. AkasicMEM만 전부 Core라고 주장. 예: Collaborative Memory = governance Core, lineage Partial, composition Partial, re-evaluation Core; MAP-Graph = governance/lineage/composition Core, re-evaluation Partial; Zep = integration Partial, lineage Core.
- 관련: 정보 흐름 제어(IFC, Myers & Liskov 1997)의 연장이지만, 메모리는 계속 형성·재사용되고 파생 관계와 정책이 시간에 따라 변한다는 점이 다르다.

## 핵심 설계

### 수명주기 모델 (§2.1, §4.1, Fig.3)

- 4 dynamics: **formation, retrieval, evolution, forgetting** — forgetting을 evolution에서 분리(보존기간 만료·계약 종료·소스 철회는 각자 트리거와 의무가 있는 별도 연산).
- 1급 연산: Formation = **Select**(보존 가치 판단) + **Store**(객체화); Retrieval = **Retrieve**(후보 탐색) + **Validate**(현재 맥락에서 사용 가능 여부); Evolution = **Revise**; Forgetting = **Invalidate**(사용 배제) / **Erase**(콘텐츠 삭제하되 lineage 그래프의 identity는 유지).
- 본 논문은 **Store, Retrieve, Validate**만 다룸. Select/Revise/Invalidate/Erase는 §5 논의로 미룸.
- 삭제 관련: 메모리 레코드만 지우고 파생물을 남기면 "deletion이 아니라 retrieval edit"(Ding et al., Yao et al. 인용).

### 데이터 객체 (§4.1)

- **Governed source object**: 원천 시스템(system of record)과 연결하는 안정 identity, 공동 검색용 콘텐츠, 등록된 authorization state.
- **Memory object**: persistent identity, 콘텐츠 + 벡터 표현, 할당된 memory scope, 형성 시 계산된 **composed authorization policy**(Eq.2의 캐시).
- **Lineage graph**: 정점 = 소스와 메모리, 간선 = 직접 파생 관계 𝒟ᵗ.
- **Authorization graph**: principal, 계층적 조직 단위, 권한 scope, principal–scope 관계.
- **Decision records**: 모든 declassification 및 모든 retrieval 결정과 그 근거.
- 요청 principal = 사용자 또는 "사용자 권한으로 동작하는 에이전트".

### 형식 모델 (§3.2)

- 𝒮ᵗ, ℳᵗ: 시각 t까지 등록된 소스/메모리 집합 — **누적적, 절대 빠지지 않음**(forgetting은 콘텐츠·임베딩·검색 자격을 지워도 identity는 lineage 정점으로 남음).
- Eq.(1): 𝒟ᵗ ⊆ (𝒮ᵗ ∪ ℳᵗ) × ℳᵗ, 그리고 t ≤ t′이면 𝒟ᵗ ⊆ 𝒟ᵗ′ (단조 증가). (x, m) ∈ 𝒟ᵗ는 x가 m 형성에 직접 기여. 다중 입력 {s1, s2, m1} → m2는 간선 3개.
- anc^t(m): 𝒟ᵗ를 역방향으로 도달 가능한 소스·메모리.
- **Authorization continuity** 정의: 소스·부모 메모리에서 상속된 제한이 반복 파생, 요청 principal 변경, 정책 상태 변경을 거쳐도 파생 메모리 접근에 계속 적용되는 성질. 3개 요구:
  1. **Transitive lineage** — 간선은 형성 시 기록, 의존 메모리가 살아있는 한 보존(기여 소스/메모리가 erase된 후에도) → 임의 깊이에서 anc 계산 가능 + 감사 가능한 형성 이력.
  2. **Policy composition** — 새 메모리 정책 = 의도된 scope ∧ lineage상 모든 제한의 결합. **임의 정책이나 형성 principal 자신의 권한으로 대체 금지.**
  3. **Policy re-evaluation** — 검색 시 현재 principal·현재 정책 상태로 재평가; 형성 시 결정 재사용 금지; **narrowing(철회)과 widening(부여) 모두 반영**.
- R^t(x): 소스면 원천 시스템이 *현재* 허용하는 principal 집합, 메모리면 형성 시 할당된 scope의 principal 집합. 둘 다 시각 t의 authorization graph로 평가 → 조직 변경이 정책 재작성 없이 반영. **삭제/등록해제된 소스는 아무도 허용하지 않음** → 명시적 declassification 전까지 파생 메모리 보류.
- **Eq.(2) 유효 권한**: 𝒜ᵗ(m) = Rᵗ(m) ∩ ⋂_{x ∈ anc^t(m)} Rᵗ(x).
- **Declassification**은 유일한 허용 예외: 특정 조상의 제한을 m의 교집합에서 제거; 𝒜ᵗ(m)을 편집하는 게 아니라 "기록된 제외"로 저장.

### Write path — Governed Store (§4.2)

- 모든 기여 소스·기존 메모리로부터 새 메모리로의 직접 lineage 간선 기록.
- scope 할당 + Eq.(2)로 유효 권한 계산(lineage로 입력과 제한 식별, authorization graph로 조직 scope 해석) → composed policy로 저장(캐시).
- 교집합은 과잉 제한(over-restriction)을 낳음 → **조상별 declassification**: (a) 자동 — NLI로 조상의 제한 정보가 파생 메모리에 남았는지 추정, (b) 수동 — 권한 있는 인간 리뷰어 승인. 어느 경로든 **lineage 간선은 유지**, 결정과 근거는 감사용 기록. 이후 파생 메모리는 제외를 상속(단, 다른 lineage 경로로 같은 조상에 의존하면 상속 안 됨). 재합성이나 조상 정책 변경으로도 declassification은 되돌려지지 않음.
- AkasicDB에서 벡터 표현, lineage 간선, composed policy, declassification 레코드를 **한 트랜잭션**에 기록 → 새 메모리는 lineage·정책과 함께만 가시화(§4.4).

### Read path — Governed Retrieve + Validate (§4.3)

- Retrieve와 Validate를 **하나의 governed query**로 실행: 의미 후보 선택 + 메타데이터 필터 + lineage traversal + 현재 정책 평가 → 요청 principal p ∈ 𝒜ᵗ(m)인 것만 반환.
- **Lazy retrieval-time revalidation**: 소스/메모리 정책 변경 시 lineage를 따라 하류 메모리에 **stale 플래그만** 표시(eager 재계산 안 함; 대부분 검색되지 않으므로). 플래그된 메모리가 후보가 되면 Eq.(2) 재계산(현재 제한 + 기록된 declassification 반영) 후 캐시 교체, p ∈ 𝒜ᵗ(m)일 때만 제공.
- 플래그된 후보를 **배치로 주기적 재검증**(그룹화·병렬화로 최적화 가능).
- **PEP 위치**: DB 내부. "candidates that fail the current policy are filtered out before any content reaches the agent or application layer"(§4.4).
- 외부 system of record의 권한 변경은 등록 정책 상태로 동기화돼야 하며, 그 동기화 지연이 Eq.(2)의 반영 지연을 bound함(§4.4) — 저자가 명시한 통합 요구사항.

### 실행 기반 (§4.4)

AkasicDB = 관계형 테이블 + 그래프 토폴로지 + 벡터 인덱스를 공통 트랜잭션·단일 쿼리 플랜으로(Chimera, VLDB 2024의 graph–relational traversal-join 통합 처리기에 벡터 검색 추가). 소스·메모리 메타데이터·정책·결정 레코드 = 관계형, lineage·authorization = 그래프, 임베딩 = 벡터 인덱스. 분리 시스템이면 정책/lineage 업데이트와 메모리 사이의 비일관 뷰가 생길 수 있다는 논거. 저자 스스로 "통합 실행이 검색·traversal·정책 평가 비용을 없애진 않는다"고 명시.

## 실험/근거

- **실험 없음.** 성능·누출률·오버헤드 측정치가 전혀 없다. 근거는 형식 정의(Eq.1–2), 예시(Fig.1), 관련 시스템 비교표(Table 1)뿐.
- §5.3에서 *제안하는* 평가 설계:
  - 기존 벤치마크(LoCoMo, LongMemEval 등)는 소스 없음·principal 1명·정책 변경 없음 → principal 간 유출 시스템도 동일 점수. Collaborative Memory·MAP-Graph 평가는 principal/권한을 추가하나 리소스가 메모리 레이어 내부에 있고 파생 깊이·정책 변경이 고정.
  - 필요 구성: 소스·principal·권한 관계가 있는 합성 조직 + 메모리를 형성·파생하는 태스크 스트림 + 철회·정정·삭제 같은 거버넌스 이벤트 타임라인.
  - 지표: **leakage**(제공된 메모리의 lineage 내 어떤 소스의 현재 정책이 배제하는 serve 비율; 파생 깊이·정책 변경 후 경과시간별), 전파 불완전성, 검증 불가 forgetting; 유용성 비용 = **over-restriction**(현재 정책상 허용인데 보류된 비율), 검색 관련성, downstream utility, freshness, trust calibration(거버넌스 on/off 비교); 오버헤드 = principal 수, authorization graph 깊이, 파생 깊이, 메모리 양에 따른 formation/retrieval/propagation 비용.
  - 난점: 유출은 의미적(paraphrase도 유출) → 판정 비교 또는 adversarial 재구성 probing 필요; 지표 간 trade-off(전부 보류하면 유출 0); 결정 검증에는 버전된 정책 상태 필요.

## 한계

### 저자가 밝힌 한계 / 미해결 (§5)

- **Validity under source change**: 소스가 정정·철회되면 파생 메모리는 권한상 여전히 허용되지만 거짓일 수 있음 → lineage가 policy뿐 아니라 validity도 실어야 함. scope 변경은 기계적으로 합성되지만 콘텐츠 변경은 판단 필요(요약은 소스 한 사실 정정에 영향 없을 수 있음). 수정은 overwrite 아닌 새 버전으로. 기여자 신뢰도 하락에도 같은 메커니즘.
- **Retention/deletion via lineage**: 다대일 파생이라 한 소스 삭제가 곧 파생 삭제는 아님(declassification과 같은 판단); 벡터 검색 시스템에서 삭제 검증은 의미적으로 근접한 메모리 probing 필요; 파생 메모리는 가장 엄격한 보존기간 상속; 공격적 삭제는 유용성 파괴.
- **Auditability**: 현재는 결정과 근거 기록까지. 과거 결정 재현에는 당시 authorization graph·소스 정책이 필요 → **정책 버전 관리 필요**(미구현). 이미 제공된 메모리는 회수 불가하나 lineage+결정 기록으로 누구에게 언제 노출됐는지 보고 가능. 감사자 접근 자체가 권한 문제.
- **Select 범위 밖**, formation/retrieval은 "deliberately conservative".
- **Consolidation 긴장**: 많은 소스에서 통합된 메모리는 모든 제한을 흡수해 *유용할수록 더 제한됨* — 통합을 governed formation에 넣는 것은 진행 중.
- 검색이 실제 유용성(사용 이력)을 고려 안 함; usefulness 기반 invalidation 트리거 없음.
- **NLI 자동 declassification은 필요조건이지 충분조건 아님**: 문장 단위로 독립이어도 aggregate로 소스를 드러낼 수 있음 → 자동 경로는 인간 승인의 screen으로 기대.
- **Outcome feedback 미구현**; 피드백 기록 자체가 파생 정보라 감사 기록처럼 content-free·scoped로 다뤄야 함.
- 외부 소스 권한 동기화 지연이 반영 지연을 bound.

### 내가 본 약점

- **검증이 전무**: 오버헤드(교집합 계산, lineage traversal, 배치 재검증)가 실제로 얼마인지, 과잉 제한이 유용성을 얼마나 깎는지 숫자가 없다. Table 1의 Core/Partial 평가는 저자 자기 판정.
- **Lazy 재검증의 일관성 창**: 정책 변경 → 플래그 → 다음 검색 시 재계산이라면 플래그 전파는 즉시인가? 플래그 전파 자체가 하류 전체 traversal이므로 eager 재계산과 비용 차이가 "재계산 vs 플래그 쓰기" 정도. 또한 "periodically revalidates flagged candidates in batches" 문구는 재검증 전 serve 가능성을 시사할 수 있어 모호함(같은 절에서 "stale policies are revalidated before use"라고도 함).
- **에이전트 컨텍스트 내 파생 추적의 현실성**: lineage 간선은 "기여한 입력"을 정확히 아는 전제. LLM이 컨텍스트 창에 있던 모든 검색 결과를 기여 입력으로 기록해야 안전한데(과잉 제한↑), 실제 사용된 것만 기록하면 유출 경로. 어느 쪽인지 정의 없음(AMU 논문의 "lineage completeness" 문제와 동일).
- **R^t(m) = 형성 시 scope의 principal 집합**: scope를 누가 정하는지(Select 단계, 형성 principal인지 시스템인지) 불명. §5.2에서 "observer at formation"을 선호한다고만.
- 교집합 모델은 **조합 권한(AND)만** 표현. "A 또는 B 소속이면 열람" 같은 OR, 목적 기반(purpose), 속성 기반(ABAC) 정책, 필드 단위 마스킹은 다루지 않음.
- 쓰기 권한(누가 어떤 scope에 메모리를 쓸 수 있는가), 메모리 poisoning 방어는 문제로만 언급(§2.1)되고 설계에 없음.
- AkasicDB 의존 — 일반 스택(Postgres+pgvector+별도 그래프)에서의 이식성 논의는 "분리하면 비일관"이라는 논거뿐.

## 팀/조직 메모리 설계에 주는 시사점

- **scope와 authorization을 분리하라**: scope는 "어디서 재사용 의도인가"(user/agent/thread/project/team/tenant), authorization은 "누가 볼 수 있는가 = scope ∩ 모든 조상 소스의 현재 ACL". 공유 에이전트·팀 에이전트를 둘 때 scope만으로 거르면 Alice→Bob 유출이 구조적으로 발생한다.
- **lineage 간선을 1급 데이터로, 삭제 후에도 tombstone 정점 유지**: (source|memory) → memory 간선을 append-only로 기록하고, erase는 콘텐츠·임베딩만 지움. 감사·권한 재계산·삭제 전파·validity 전파가 모두 이 그래프 위에서 돈다.
- **composed policy는 캐시, 정답은 검색 시점 재평가**: 정책 변경 시 하류에 stale 플래그 → 후보로 뽑힐 때 재계산. "형성 시점 권한 스냅샷"을 영구 ACL로 쓰지 말 것(widening도 반영돼야 함).
- **삭제/등록해제된 소스 = 아무도 허용 안 함(fail-closed)** + 명시적 declassification(조상 단위, 기록된 예외, NLI는 screen, 인간 승인)으로만 완화. 교훈·절차형 메모리를 기밀 프로젝트 밖으로 꺼내는 공식 경로로 설계.
- **PEP는 저장소/쿼리 계층에**: 벡터 검색 결과를 앱에서 사후 필터하지 말고 같은 쿼리 플랜·트랜잭션 안에서 권한 필터 → 메모리·lineage·정책이 원자적으로 가시화.
- **결정 기록(serve/withhold + 근거 + 정책 버전)**을 남겨 "누구에게 언제 무엇이 노출됐는가"를 사후 보고 가능하게. 반복적으로 관련 있지만 필터되는 메모리는 declassification 리뷰 후보라는 신호로 활용(§5.2 아이디어).

## 다른 개념과의 연결

- **Scope hierarchy**: user/agent/thread/project/team/tenant scope + authorization graph의 계층적 조직 단위. scope는 의도, authorization은 상속 제한.
- **Provenance/lineage**: transitive, 다중 입력, 메모리→메모리 포함, append-only(𝒟ᵗ 단조). AMU(컬럼 단위 SQL lineage)는 같은 아이디어의 정형 데이터 특화판; Collaborative Memory의 provenance(𝒜(m), ℛ(m))는 1-hop.
- **Authorization continuity**: 이 논문의 핵심 용어. IFC(Myers & Liskov) 계보; Collaborative Memory의 retrospective permission check를 다단 파생으로 확장한 것.
- **Temporal invalidation**: 권한 축은 lazy 재평가로 처리; 사실 validity 축은 §5.1에서 "lineage로 validity 전파 + 새 버전 기록"을 제안만 함. 정책 버전 관리도 미래 과제.
- **Write gates**: Select(관찰자 판단 선호), 형성 시 정책 합성이 사실상 쓰기 게이트. poisoning 방어는 없음.
- **Decision traces**: decision records(declassification, retrieval 결정 + basis)가 감사 trace. 피드백 기록도 scoped 파생 정보로 취급해야 한다는 지적.
- **Forgetting/unlearning**: erase ≠ identity 삭제, 삭제 검증은 의미적 probing, 가장 엄격한 retention 상속.
- **MemClaw의 3 실패모드**(stale read, 충돌 메모리 동시 활성, 추적 불가) — §5 서두에서 lineage로 처리해야 할 대상으로 언급.

## 확인 필요

- AkasicMEM/AkasicDB 구현이 공개됐는지, 실측 오버헤드나 유출 평가가 후속 논문/데모(SIGMOD Companion 2026 AkasicDB 데모)에 있는지.
- lineage 간선의 "기여" 판정 기준 — 에이전트 컨텍스트에 들어간 모든 검색 결과인지, LLM이 인용한 것만인지. 본문에 정의 없음.
- §4.3 "periodically revalidates flagged candidates in batches"가 serve 전 동기 재검증인지 백그라운드 배치인지(문장 간 모순 가능성).
- R^t(m)의 scope를 누가/어떻게 할당하는지(Select 단계 소관이라 범위 밖으로 처리됨).
- Table 1의 MemClaw(2606.24535), MAP-Graph(2608.10509), Oracle Agent Memory(2607.13157) 평가가 각 원문과 일치하는지.
- NLI declassification에 사용하는 모델·임계값 — 명시 안 됨.
