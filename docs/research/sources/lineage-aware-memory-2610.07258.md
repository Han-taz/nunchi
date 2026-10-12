---
title: "Lineage-Aware Memory Governance: A Derivation-Gated Framework for Privacy-Preserving Column-Level Access Control in Enterprise AI Agents"
arxiv_id: "2610.07258"
authors: "Venkata Sangaraju (Independent Researcher, 교신저자); Sudhir Vissa (SAGE7 AI, Georgetown, Texas)"
affiliation: "Independent / SAGE7 AI"
date: "2026-10-05 (v1, cs.CR); IEEE Access accepted manuscript, DOI 10.1109/ACCESS.2026.3730363"
url: "https://arxiv.org/abs/2610.07258"
html: "https://arxiv.org/html/2610.07258"
type: paper
read_status: full
read_note: "arXiv HTML 본문 §I–VIII + 참고문헌 전체 읽음. HTML에서 깨진 수식/필터 문자열('<' 포함)과 Algorithm 번호는 PDF 텍스트로 보완. 별도 Supplementary Material(전체 유도, Alg.2 walkthrough, per-seed 표, D4 명세, T1–T8 상세)은 arXiv 본문에 없어 읽지 못함."
---

# Lineage-Aware Memory Governance / Analytical Memory Unit (2610.07258)

## 한 줄 요약

부서별 분석 에이전트가 공유하는 캐시형 메모리에서, **값 자체엔 민감정보가 없지만 민감 컬럼을 거쳐 계산된 결과**가 권한 없는 부서에 재사용되는 누출을 막기 위해, 각 결과에 **(table, columns, filter) 단계열 lineage**를 붙인 **Analytical Memory Unit(AMU)**과 "요청 부서가 lineage의 모든 민감 컬럼 권한을 가질 때만 hit"하는 게이트, 그리고 **definition hash로 같은 이름 KPI의 정의 충돌 탐지**를 제안.

## 문제 정의

- §I 예시: Finance가 `customer_pii`(income 포함) ⋈ `transactions`로 "고가치 고객" 세그먼트(12,400 ID + count)를 만듦. 결과엔 raw PII도 민감 태그도 없음 → 콘텐츠 기반 거버넌스 메모리는 이를 캐시해 income 권한 없는 Marketing에게도 제공. **위반은 값이 아니라 계산 경로에만 보인다.**
- §I-A: MemGPT, Zep, A-MEM, Governed Memory, SSGM, Oracle AI Agent Memory 모두 owner/sensitivity class/role 등 **content·tag 수준** 통제. Ranger/Unity Catalog 같은 소스 계층 컬럼 보안은 *쿼리*를 막을 뿐, 정당하게 계산·캐시된 결과가 덜 권한 있는 요청자에게 서빙되는 시점엔 작동 안 함.
- 두 번째 독립 실패모드: **같은 이름 KPI를 부서마다 다른 로직**(예: churn 90일 vs 60일)으로 계산 → 공유 메모리가 한 팀 정의를 다른 팀에 조용히 전파(BI의 semantic drift; Open Semantic Interchange 이니셔티브는 사람용 BI 대상).
- 동기 수치(인용): Gartner — 2026 Q1 출시/업데이트 기업 앱 80%가 에이전트 내장(2024 33%); 기업 31%가 에이전트 프로덕션 운영(은행·보험 47%); IBM 2025 침해 평균 $4.44M(미국 $10.22M); AgentLeak — 에이전트 간 메시지 누출 68.8% vs 최종출력 27.2%, output-only 감사는 41.7% 누락.
- Table I: Content tag / Role ACL / Column lineage / Drift detect / Retrieval gate 5축 비교에서 Column lineage를 가진 기존 시스템 없음(Collaborative Memory = Content tag ~, Role ACL ✓, Column lineage ✗, Drift ✗, Retrieval gate ✓). 저자는 이 표가 "문서화된 설계 결정" 비교이지 성능 비교가 아니며, 대상 상당수가 미심사 preprint/벤더 블로그라고 명시.

## 핵심 설계

### AMU 스키마 (§III-A, Definition 1, Table II)

- AMU = ⟨metric, v, d, τ, L⟩
  - `metric_name`: KPI 이름(예: churn_rate)
  - `value` v ∈ ℝ, `owner_dept` d(생산 부서), `epoch` τ(정수, TTL eviction)
  - `lineage` L = (s1,…,sk), 각 단계 sᵢ = (tableᵢ, Cᵢ, φ): 접근한 컬럼 집합 Cᵢ, 필터 로직 문자열 φ
  - `sensitivity_tags` = S(a), `definition_hash` = H(a) — 생성 시 1회 계산·캐시
- Eq.(1) **S(a) = (⋃ᵢ Cᵢ) ∩ 𝒮** (𝒮 = 조직의 민감 컬럼 레지스트리)
- Eq.(2) **H(a) = SHA256( sort(tables) ‖ sort(⋃ᵢ Cᵢ) ‖ φ )[0:12]** — 계산 방식 지문
- Fig.1 예: churn_rate = 0.114 (Finance, epoch 17), customers{customer_id, signup_date} + transactions + customer_pii{last_txn_date, income}, filter `last_txn_date < now()−90d AND income > 20000` → S(a) = {income}.
- P(d) = 부서 d의 허용 컬럼 집합.
- 저장 오버헤드: k개 (table/column) 튜플 + 필터 문자열 + 12자 해시 ≈ bare value의 4–8×(2–4 테이블 조인 기준 200–600 bytes), §IV-A.

### Read path — Algorithm 1: Lineage-Gated Retrieve (§III-B)

입력: store, metric, dept, fresh(호출자가 P(d) 범위 안에서 이미 계산한 결과)

```text
candidates <- store[metric]; permitted <- P(dept); blocked <- False
for a in REVERSE(candidates):          # 최신순 — "가장 최신의 안전한 값" 정책
    if S(a) ⊄ permitted: blocked <- True; continue   # 값은 반환·부분반환·로깅 안 함
    return (reused=True, value=a.value, leaked=False, blocked=False)
store[metric].append(fresh)
return (reused=False, value=fresh.value, leaked=False, blocked=blocked)
```

- 비용: 후보당 O(|𝒮|) 집합 차, 최악 O(n·|𝒮|) ≈ O(n), 최선 O(1). (metric, S(a)) 인덱스로 최악 O(1)도 가능하지만 최신 우선 보장을 포기하므로 채택 안 함; n은 (부서, lineage 변형)당 1개라 실제 n ≤ 5.
- **주의**: fresh는 게이트 *호출 전에* 계산되어 입력으로 들어감(Case 2 전제). 즉 알고리즘 그대로면 캐시 hit이어도 fresh 계산이 이미 발생 — 재사용률 지표의 의미가 "서빙 출처"이지 "계산 회피"인지 본문으로는 모호(아래 약점).

### Write path — Algorithm 2: Conflict Detection

```text
for e in store[a.metric]:
    if e.dept != a.dept and H(e) != H(a): conflict <- True; break
store[a.metric].append(a)   # 항상 저장; 충돌은 surfacing만, 차단 안 함
return conflict
```

- 해시 비교라 쌍당 O(1). 동일 부서 내 정의 변경은 충돌로 보지 않음.

### 정책 집행 지점 / 구현 (§III-C, Fig.2)

- **DB 드라이버(cursor) 래핑**: 실행되는 모든 SQL 문자열을 lineage 추출기(SQLGlot)로 → 에이전트 협조 불필요.
- **Fail-closed**: lineage 추출 실패 시 S(a) ← 𝒮(최대 민감), 부서 권한 집합 조회 불가 시 거부.
- epoch: TTL eviction + 정책 기반 무효화 — 𝒮나 P(d)가 바뀌면 캐시된 S(a)를 다음 검색 때 lazy 재계산(Corollary 3, T3).
- Table V 주석: 게이트는 𝒮에 속한 컬럼만 집행. **비민감이지만 차단 의도인 컬럼은 현재 집행 안 됨.**

### 형식 분석 (§IV)

- Assumption 1(Complete Lineage): 모든 AMU의 lineage가 계산의 모든 table·column·filter를 기록.
- **Theorem 1**: Assumption 1 하에서 Alg.1은 c ∈ 𝒮, c ∉ P(d)인 민감 컬럼에서 파생된 결과를 d에 반환하지 않음. 증명은 두 return 경로(캐시 서빙: S(a) ⊆ P(d) 확인됨 / fallback: fresh가 P(d) 내 계산이라는 전제)에 대한 case analysis. 저자 스스로 "조건부 설계 정확성, 실험적 주장 아님".
- Corollary 2: 저장소에 위험 AMU가 아무리 많아도 보장 유지. Corollary 3: 정책 버전별 보장 — 𝒮1→𝒮2 전환 후 재계산 전엔 새 민감 컬럼이 stale 태그에 없을 수 있음.

### 위협 모델 (§V, Table IV)

주체 = honest-but-potentially-over-privileged 부서 에이전트.

| ID | 위협 | 상태 | 통제 |
|---|---|---|---|
| T1 | 캐시 결과 통한 민감 컬럼 누출 | Addressed | lineage gate |
| T2 | KPI 정의 drift | Addressed | conflict detector |
| T3 | 정책 갱신 후 stale 민감 데이터 | Partial | TTL + lazy S(a) 재계산 |
| T4 | 추론 공격(소스 이름 없는 파생 feature, 예: income 기반 risk score) | No | 피처 엔지니어링 수동 검토 |
| T5 | 악의적/불완전 lineage 조작 | Partial | 자동 추출(SQLGlot/LINEAGEX) |
| T6 | 다회 검색 집계 추론 | No | DP 레이어(미래) |
| T7 | 저장소 내부자 위협 | No | 신뢰 인프라, 감사 로깅 |
| T8 | lineage 대상 prompt injection / timing side-channel | Partial | 자동 추출, constant-time gate(옵션) |

추가로 T1–T8 밖: cross-metric correlation(허용 AMU 여러 개로 c 삼각측량), 부서 공모(out-of-band 결합).

## 실험/근거 (§VI)

- 순수 Python **합성 이산사건 시뮬레이터**(LLM·네트워크·옵티마이저 교란 제거, ground-truth lineage 완전 인지). 비교: No Memory(누출 0·재사용 0) / Naive Shared Memory(content-gated, 기존 시스템 대표) / Lineage-Aware. 30 seed 평균±모표준편차, bootstrap 95% CI, Mann-Whitney U.
- **Exp 1–2** (합성 5테이블, 3부서, 𝒮={ssn, email, income} / TPC-H 8테이블, |𝒮|=9), Table VI:
  - Leak rate: Naive 18.8±3.7% / 25.5±4.5% → LA 0.0%(†정리 결과이지 실험 발견 아님)
  - Reuse rate: Naive 95.8% / 95.8% → LA 82.6±2.3% / 81.5±4.8% (13–14pp 감소 ≈ 100요청당 13회 추가 쿼리)
  - Conflict recall: Naive 0% → LA 100%
  - 모든 차이 p < 0.001, effect size d ≈ 7.2–8.0. 민감 변형 비율(5개 metric 중 2개) 고정에 |𝒮| 3배 + 조인 밀도↑ → 누출률 18.8→25.5%("우연히 민감 컬럼을 건드리는 경로 수에 비례" 가설, 2×2×2 factorial을 최우선 후속 과제로).
- **Exp 3** lineage 완전성 ρ(각 단계 컬럼 중 정확히 보고된 비율), shadow store로 실제 누출 측정: ρ=0.50에서 합성 16.3±3.3%, TPC-H 10.3±4.7%(거의 무보호); 합성 ρ≥0.75, TPC-H ρ≥0.90에서 측정 누출 0 → **ρ ≥ 0.9를 최소 배포 목표**로 권고. 조인 깊이가 완전성 요구를 증폭.
- **Exp 4** 퍼지 충돌 탐지 43쌍(True Conflict 15, Threshold Variant 15, Logic-Operator AND→OR 8, Column-Subset 5), Table VII:
  - D1 exact hash: P 0.651, R 1.000, F1 0.789, LO 8/8
  - D2 Jaccard τ=0.70: P 0.676, R 0.821, F1 0.742, LO 3/8
  - D3 column-graph: P 1.000, R 0.714, F1 0.833, LO 0/8 (원래 10쌍에선 F1 1.00이었음 → 작은 데이터셋이 성능 과대평가)
  - 제안만 하고 미평가: D4 = D3 + filter-logic 구조.
- **Exp 5** 런타임(2,000 반복, n∈{1,5,10,20,50}, 4코어 Apple Silicon VM 3.8GB, Ubuntu 22.04, CPython 3.10.12, Docker): gate predicate 0.09μs; 충돌 탐지 0.28μs(n=1)→1.63μs(n=50); retrieve 최악 0.66→13.82μs(21×, O(n)), 기대 0.66/0.64μs(O(1)). n≤5 실워크로드 최악 1.74μs.
- **Exp 6** 실에이전트: Northwind DB, 4부서(Finance, Sales, Operations, HR), 𝒮={unitprice, freight, homephone, birthdate}, LangChain + Ollama 에이전트, sqlglot을 cursor 앞에 삽입. 3 시나리오(안전 재사용 / 차단+충돌 / 민감 컬럼 없는 metric의 vacuous reuse). **9 round-trip**: 누출 0, fresh SQL 5회(그중 2회는 게이트 차단 후), 캐시 서빙 4회, 게이트 차단 2회 = 자동 탐지된 정의 충돌 2건과 정확히 일치. 캐시 hit 0.009ms. 저자 표현 "feasibility demonstration, not evidence of production viability"; "real (and demo-mode canned) SQL" — 일부는 고정 SQL.

## 한계

### 저자가 밝힌 한계 (§I-B, §V, §VII-B)

- 보장은 lineage 완전성(Assumption 1)에 조건부; 실측 누출 제거에 ρ 75–90% 필요.
- **T4(이름 없는 파생 feature 추론)가 프로덕션에서 가장 중요한 미해결 gap**. T6/T7 및 cross-metric correlation·부서 공모도 범위 밖.
- 18.8–25.5% 누출률은 워크로드 믹스의 성질이지 보편 기저율 아님.
- 43쌍 퍼지 데이터셋은 작음; 런타임은 단일 하드웨어.
- SQLGlot 정적 AST 한계: (1) view — 정의 SQL이 없으면 view 이름만 lineage에 남아 `v_customer_summary` 뒤의 민감 컬럼 누락, (2) stored procedure/UDF(`CALL compute_churn(...)`) 불투명, (3) 깊은 CTE/서브쿼리 aliasing + 카탈로그 없는 `SELECT *`. fail-closed라 피해는 과잉 차단으로 제한된다고 주장하나 catalog-aware 확장은 미구현.
- 향후: adversarial lineage 테스트, 비SQL lineage(벡터 스토어·REST/GraphQL·in-process), 실제 20–50 테이블 웨어하우스 수주 배포, D4 평가, 코드 공개(현재 "요청 시 제공").

### 내가 본 약점

- **적용 범위가 좁다**: 메모리 단위가 "SQL로 계산된 스칼라 KPI 값". 자연어 사실·요약·결정·대화 메모리에는 컬럼 lineage가 정의되지 않음. 팀 메모리 전반이 아니라 *분석 결과 캐시*의 거버넌스.
- **실험 대부분이 정리를 재확인**: LA 0% 누출은 저자도 인정하듯 정의상 결과. 실증적 내용은 naive 누출률(시뮬레이터 워크로드에 의해 결정)과 재사용 비용뿐. Exp 6는 9회, 일부 canned SQL.
- **"fail-closed라 view 누락은 과잉 차단으로 끝난다"는 주장은 부정확해 보임**: view 이름이 정상 파싱되면 추출은 *실패하지 않고* 불완전한 lineage를 산출 → fail-closed 트리거가 안 걸리고 Assumption 1이 조용히 깨짐(저자 본문도 앞 문단에서 "quietly violates Assumption 1"이라 씀). 두 서술이 충돌.
- **권한 모델이 부서 단위 정적 컬럼 집합 P(d)**: 사용자 개인, 행 단위(row-level) 보안, 목적 제한, 시간 조건 없음. 행 필터 φ는 해시에만 쓰이고 권한 판정에 쓰이지 않음 → "자기 지역 고객만" 같은 row-level 정책 위반은 못 잡음.
- **Alg.1 인터페이스상 fresh가 먼저 계산돼야 함** → "재사용"이 계산 절감을 의미하는지 불분명. 실제로는 hit 실패 시에만 계산하는 lazy 콜백이어야 할 것.
- 충돌 탐지 D1의 precision 0.651은 threshold 재조정마다 경보 → 실운영 시 경보 피로. 의미적으로 동일한 SQL의 문법적 차이(컬럼 순서는 sort로 해결되나 φ 문자열 포맷 차이)도 해시를 바꿈.
- AMU 간 파생(AMU를 입력으로 또 다른 AMU 계산)의 transitive 처리가 명시되지 않음 — lineage가 base table까지 펼쳐지는지 불명.

## 팀/조직 메모리 설계에 주는 시사점

- **"요청자가 이 결과를 직접 만들 수 있었는가?"를 읽기 게이트 질문으로**: 콘텐츠/소유자 태그 대신 파생 입력에 대한 권한 포함관계(S(a) ⊆ P(d))로 판정. 정형 데이터에서 파생된 팀 메모리(지표, 세그먼트, 리포트 수치)에 바로 적용 가능.
- **lineage는 에이전트 자기신고가 아니라 실행 계층에서 캡처**: DB cursor/툴 호출 래퍼에서 결정론적으로 추출. 자기신고는 ρ<0.9에서 보호가 급락(ρ=0.5면 사실상 무보호).
- **추출 실패·권한 조회 실패는 최대 민감/거부로(fail-closed)**, 단 "불완전하지만 실패는 아닌" lineage(view, 프로시저)를 탐지할 카탈로그 기반 검증이 별도로 필요.
- **민감 태그와 정의 해시를 쓰기 시점에 캐시**하고 정책(𝒮, P(d)) 버전이 바뀌면 lazy 재계산 — AkasicMEM의 stale-flag 패턴과 동형.
- **같은 이름 다른 정의 탐지를 메모리 레이어 기본 기능으로**: 쓰기는 막지 않고 surfacing만(정의 충돌은 거버넌스 이슈이지 보안 차단 대상이 아님). exact hash는 과경보, column-graph는 AND→OR 누락 → 구조적 필터 비교 포함한 복합 탐지기 필요.
- **비용 예산화**: 거버넌스는 지연이 아니라 재사용률(13–14pp)로 비용을 낸다 — 팀 메모리 KPI에 "governance-induced recompute rate"를 둘 만함.

## 다른 개념과의 연결

- **Provenance/lineage**: column-level, (table, C, φ) 단계열. AkasicMEM의 일반 객체 lineage 그래프(소스·메모리 정점)를 정형 SQL에 특화한 변형. W3C PROV, LINEAGEX와 계보 공유.
- **Authorization continuity**: S(a) ⊆ P(d)는 AkasicMEM Eq.(2) 교집합 모델의 컬럼 버전(소스 권한이 파생 결과에 상속). 다만 AkasicMEM과 달리 declassification 경로 없음, 메모리→메모리 파생 명시 없음.
- **Scope hierarchy**: 부서(d) 단일 레벨. owner_dept는 재사용 범위 제한에 쓰이지 않음(모든 부서가 후보, 게이트만 판정).
- **Temporal invalidation**: epoch(TTL) + 정책 변경 시 lazy 재계산(Corollary 3). 데이터 신선도(소스 갱신 시 캐시 무효화)는 다루지 않음.
- **Write gates**: 쓰기는 항상 허용(충돌은 경보만). 게이트는 읽기 측에만.
- **Decision traces**: blocked_count/reuse_rate 카운터 수준. 차단된 후보 값은 로깅하지 않는다는 원칙(§III-B).
- **Semantic layer / metric governance**: definition_hash = 에이전트가 생성한 쿼리에 대한 metric drift 탐지(OSI가 커버하지 않는 영역).
- **Collaborative Memory와 대비**: 저자는 Collaborative Memory가 fragment를 원자 단위로 권한 판정하므로 허용된 fragment에 금지 컬럼 파생값이 숨을 수 있다고 비판(§II).

## 확인 필요

- Supplementary Material 내용(Alg.2 walkthrough, D4 명세, T1–T8 상세, per-seed 표, 2×2×2 factorial 명세) — arXiv 본문에 없어 미확인.
- 코드 공개 여부("upon acceptance" 공개 약속; IEEE Access 게재 후 저장소 존재?).
- Exp 6의 9 round-trip 중 LLM 생성 SQL과 canned SQL의 비율.
- Alg.1의 fresh가 실제 구현에서도 사전 계산인지, lazy 콜백인지(재사용률의 의미에 영향).
- AMU를 입력으로 한 2차 AMU의 lineage가 base column까지 전개되는지.
- 시뮬레이터에서 요청 분포/민감 변형 비율 등 워크로드 파라미터의 정확한 값(본문엔 "2 of 5 metrics"만).
