---
title: "MAPLE-Guard: Memory-Aware Link Enforcement Against Memory-Link Poisoning in Multi-Agent Systems"
arxiv_id: "2608.00426"
version: v2 (2026-10-03, cs.MA)
authors: "Wenjun Xiong, Yijin Zhou, Jiaqian Wang, Shangding Gu, Bo Tang, Zhiyu Li, Feiyu Xiong, Ying Wen, Muning Wen"
affiliation: "Shanghai Jiao Tong University; Shanghai Innovation Institute; Xidian University; UC Berkeley; MemTensor (Shanghai) Technology"
date: 2026-10-03
url: https://arxiv.org/html/2608.00426
code: https://github.com/xiong-wenjun/MAPLE-Guard
type: paper (defense, multi-agent memory security)
read_status: full
read_notes: "본문 §1–6, Limitation, 부록 A, C–I 전부 읽음. 부록 B(확장 관련연구)는 훑기만 함. §4.1 마지막 문장 하나가 추출기에서 '[truncated]'로 잘림(reference-correctness 관련 문장, §5.6/부록 D.2에서 내용 보완됨)."
---

# MAPLE-Guard (2608.00426)

## 한 줄 요약

멀티에이전트 시스템(MAS)의 private/shared 영속 메모리를 "통신 링크"가 아니라 **메모리 링크(write → retrieve → promote → cross-agent reuse)** 의 생애주기로 보고, 각 전이 지점 4곳에 결정적(규칙 기반, LLM 호출 없음) 게이트를 두어 오염 메모리의 전파를 막는 방어. 동일 스코어러 조건에서 retrieval-only 필터 대비 MDSR@3 65.0→88.4%, RDA@3 21.6→0.1% (AppWorld proxy, Gemma).

## 문제 정의 / 위협 모델

- **메모리 링크 포이즈닝**(§3): 메모리 항목은 상태를 가지므로, 주입 시점과 피해 시점이 분리된다. 아이템이 일찍 쓰여 몇 라운드 잠복 → shared로 승격 → 다른 에이전트가 관련 쿼리에서 검색 → 피해. 이 경로는 통신 그래프 E를 따르지 않음(writer와 victim 사이에 직접 메시지 없음).
- 형식화: 메모리 항목 `m=(x, μ)`, `μ=(σ 스코프[private/shared/blocked], p 출처, ℓ 생애상태[active/retrievable/promotable/quarantined], φ 가드 신호)` (Eq.1). 액션 집합 A={write, retrieve, promote, reuse, update}, 메모리 링크 이벤트 `e=(u,v,m,a,t)` (Eq.2), 이벤트 시퀀스 = memory-link path P(m).
- 숨은 가드 상태 `φ(m)=(ρ utility, τ provenance trust, h hazard, σ, ℓ, o outcome history)` + provenance chain 𝒫(m) (Eq.3). 백본 LLM에는 노출 안 함(단, MAPLE 직렬화는 source task/agent 같은 제한된 origin 필드를 메모리 텍스트와 함께 렌더링할 수 있음).
- **taint 상속**: 신뢰되지 않음/외부/cross-agent 부모에서 파생된 메모리는 부모 위험 일부를 상속(dynamic taint tracking 차용). taint는 평가자의 poison 라벨이 아니라 운영상 검증 상태(clean/unverified/external).
- **공격자**(§3.2): 정상처럼 보이는 1~소수 에이전트를 통제. 두 경로 — (a) dialogue route: 평범한 대화로 경험형 메모리 유도 후 요약·승격, (b) direct-memory route: 접근 가능한 스토어에 직접 seed. 다른 에이전트의 private 스토어, 가드 숨은 신호, 토폴로지는 수정 불가. 기본적으로 가드를 모름(non-adaptive).
- 메타데이터 무결성은 가정(메모리 매니저 신뢰). 위조된 source-route/writer/scope/lineage 공격은 평가 범위 밖(부록 A.2).

## 핵심 설계

**Algorithm 1 (라운드 루프)**: 각 에이전트마다 ① 후보 검색·가치순 정렬(Eq.10) → ② Read firewall(Eq.6 위험 필터) → ③ 필터된 메모리로 실행 → ④ Write firewall(Eq.9: reject/quarantine/rewrite/allow) → ⑤ Promotion gate(Eq.11) → ⑥ Cross-agent gate(스코프·active 상태 검사). 태스크 종료 후 ⑦ outcome update.

**1) 메모리 가치·결과 업데이트 (§4.1)**

- `ρ_{n+1}(m)=(1−α)ρ_n(m)+αR_n`, α=0.2, R=+1(성공)/−1(실패) (Eq.4). Q-learning이 아닌 결과 조건부 이동평균임을 저자가 명시.
- `τ_{n+1}=τ_n+η_τ g(R_n)` (Eq.5): 성공 시 trust +0.03 / hazard −0.02, 실패 시 trust −0.05 / hazard +0.05, [0,1] clip. **실패에 비대칭적으로 더 큰 페널티**.
- 업데이트는 사용된 메모리에만 국소 적용(무관한 실패가 풀 전체를 벌하지 않음). 단, "사용된 모든 메모리에 태스크 결과를 할당"하는 것은 휴리스틱 credit assignment라고 인정.
- full-feedback 설정에서 R은 **벤치마크 평가자의 정답 비교**에서 옴 → 배포 시 이런 신호가 없을 수 있음(핵심 약점).
- 소스 에이전트 평판도 +0.015 / −0.020로 업데이트(MMLU/AppWorld).

**2) 통합 위험 모델 (§4.2, Table 1)** — `r(m,c_t)=Σ_{k=1..8} w_k r_k(m,c_t)`, Σw=1. 문자열/정규식 + 메타데이터 산술, LLM·학습 분류기 없음.

| 신호 | 계산 | w |
|---|---|---|
| Provenance p | direct/imported/external/tool/environment 출처 +0.45; query-only/bridge/post-task-successful-experience +0.30; team scope & τ<0.70 +0.15; taint external +0.40 / unverified +0.24 / poisoned +0.70 (배타) | .24 |
| Lineage l | C(0.18·n_l), n_l = 7개 마커(memory_handoff, cross_agent, shared_promotion, tool_observation, environment_observation, external_observation, imported_memory) 중 등장 종류 수 — 그래프 깊이 아님 | .20 |
| Self-claim s | "validated/verified/successful/high-confidence/team verification…" 등 매치 0.14·n + taint 비청정 또는 τ<0.70이면 +0.18 | .14 |
| Instruction i | 금지 지시(“ignore previous instructions”, “skip verification”, “do not verify”, “treated as reliable past team experience” 등) 매치 시 1, 아니면 0.16·n(reuse/prioritize 패턴) | .14 |
| Answer binding b | "option A–E", "final answer: X" 등 4패턴 0.20·n | .12 |
| Trigger t | 고정 큐 +0.45/+0.35/+0.20, 검색 시 overlap ≥0.25 +0.25, 유사도 ≥0.35 +0.15 | .10 |
| Cluster d | max(c_m−0.5, 0), 같은 정답 키 점유율 | .04 |
| Agent distrust a | 1−C(τ_agent), 기본 0.5 | .02 |

- provenance+lineage가 가중치 0.44 → "텍스트가 무해해 보여도 출처·전파 이력을 근거로 잡겠다"는 설계 의도.

**3) 4개 생애주기 게이트 (§4.3)** — 하나의 스칼라 임계값이 아니라 게이트별 술어가 다름.

- **Write (Eq.9, 순서대로)**: forbidden(자격증명/API키/비밀번호/토큰 패턴) → reject; Q_w → quarantine(보존하되 비활성); instr(m) ∨ [r≥.38 ∧ (b>0 ∨ s>0)] → rewrite("미검증 이력" 접두어 + utility≤0.1, trust≤0.25, hazard≥0.5, clean→unverified; **원문 지시는 삭제하지 않음**); 그 외 allow. Q_w = [r≥.50 ∧ (p≥.45 ∨ l≥.36)] ∪ [p≥.45 ∧ (b≥.25 ∨ s≥.25)] ∪ [h≥.65 ∧ τ≤.35]. 쓰기 승인은 요청 스코프를 유지하고 승격은 별도 검사.
- **Retrieval (Eq.10)**: `S = sim + 0.8ρ + 0.5τ − 1·h_q − 1·T_q − 2·scope − 1.15·r`. 차단: 비활성/스코프 외, h_q≥.65∧τ≤.50, r≥.48, t≥.45∧τ<.75, b≥.45∧s≥.35(비청정 taint), 최소 점수 미만. 최상위 후보가 유사도 임계 미만이면 메모리 없이 답함.
- **Promotion (Eq.11)**: `Promote = 1[¬B_p]`, B_p = r≥.34 ∪ provenance/claim 조건 ∪ external/poisoned taint ∪ h≥.50 ∪ τ<.62 ∪ (unverified ∧ (b>0∨s>0)). 실패 시 quarantine. **승격 임계(.34)가 검색 임계(.48)보다 엄격**. 러너 레벨 승격 후보 정책(태스크 성공 요구)은 별도.
- **Cross-agent broker**: 스코프 위반·비활성 아이템 차단, 상류 제한을 승계. 8신호 총합을 독립 임계하지는 않음. direct-shared 토폴로지에서는 브로커 제한이 호출되지 않음(부록 A.4).

## 실험/근거

- 설정(§5.1, 부록 C): 5개 벤치-공격 쌍(MMLU–MINJA, LongMemEval–MemoryGraft, AppWorld–AgentPoison, CSQA–PromptInject(전이), InjectAgent–ToolAttack). 런당 200 인스턴스, 8 에이전트(3 공격자), 3 라운드. 백본 Qwen3.5-122B-A10B, gemma-4-31B; 임베딩 Qwen3-Embedding-8B; 판정 Qwen3.5-122B(temp 0). 토폴로지 star/chain/tree 각 15런(랜덤/완전연결은 스트레스 테스트). 표준편차는 토폴로지 간 변동(태스크 불확실성 아님).
- 지표: **RDA@3** = 최종 라운드 비공격자 출력 중 "오염 메모리를 검색했고 태스크 실패"한 비율. **MDSR@3** = 요구 정답 비율을 만족한 태스크 비율. 둘은 상보적이지 않음. 보조: PMUR(검색된 poison 중 프롬프트 진입 비율), PMUR-A(노출된 비공격자 에이전트 비율), Sec. ASR@3(위험 툴 선택률).
- 공격 위력(Obs1): No Defense RDA@3 — Qwen MMLU 51.4%, AppWorld 34.7%; gemma MMLU 75.1%, InjectAgent 84.4%. 통신 레벨 가드 GUARDIAN은 Qwen AppWorld에서 RDA를 34.7→56.5%로 **악화**.
- 메인(Table 2, Qwen): MAPLE MDSR/RDA — MMLU 89.5/0.3, LongMemEval 74.3/0.9, AppWorld 99.8/0.2, CSQA 79.5/23.6, InjectAgent 98.3/4.9. PIGuard는 LongMemEval MDSR 79.1(최고)/RDA 5.9 → MAPLE은 피해는 더 낮지만 태스크 성공은 1위가 아님.
- gemma: MAPLE MMLU 56.2/5.8 (No Def 22.0/75.1), AppWorld 95.3/0.0, 그러나 **InjectAgent 33.3/56.1로 PIGuard(60.5/32.3)에 양 지표 모두 짐** — 저자가 현 설정의 한계로 명시.
- PIGuard+MAPLE 조합(Table 3/16, gemma): CSQA 83.3/18.3 (PIGuard 78.5/22.5 대비 +4.8/−4.2), LongMemEval 69.6/1.7 (PIGuard 55.4/4.1 대비 +14.2/−2.4). 통계 유의성 주장 없음.
- **배치(placement) 통제 실험(Table 5/8, AppWorld proxy, gemma, 4토폴로지 평균)**: full 88.4/0.1, retrieval-only 65.0/21.6, no_q(Q 업데이트 동결) 68.1/17.4, none(정답 피드백 제거) 67.7/16.3. chain 토폴로지에서 retrieval-only RDA 52.5%.
- **게이트 단일 제거(Fig.5, LongMemEval)**: full 73.6/0.9. **promotion 게이트 제거 시 최대 하락 → MDSR 60.0, RDA 14.5**. write/retrieval/cross-agent 제거는 더 작지만 일관된 손실(정확 수치는 그림에만).
- 라운드 동역학(Obs4, random, Qwen): R1→R3 MDSR 변화 No Defense −3.5/−9.2/−19.5 (MMLU/LongMemEval/AppWorld) vs MAPLE +4.5/−4.4/0.0.
- 스케일(Table 4): 30 에이전트 RDA@3 26.5→23.2, 50 에이전트 24.3→21.8 (효과 작음).
- 무공격 유틸리티(Table 6): Qwen MMLU 88.5→87.0, LongMemEval 64.5→71.5; gemma LongMemEval 34.2→32.8 등 일부 하락. 토큰: MMLU −35.0%, InjectAgent −27.8% (5태스크 소규모 감사).

## 저자가 밝힌 한계

- 초기 침투 방지가 아니라 시스템 진입 후 **봉쇄(containment)** 목적.
- 신뢰할 수 있는 provenance 메타데이터·검색 추적 가정; 메타데이터 위조, 이벤트별 임계값 아래로 머무는 페이로드는 회피 가능.
- full-feedback은 벤치마크 평가자 결과 사용; CSQA 러너는 알려진 공격자 역할로 메타데이터 일부 초기화.
- 벤치마크마다 공격 하나만 짝지어 공격 진입점의 인과 효과를 분리 못함. 비교는 "정보 접근 조건부"(MAPLE만 숨은 메타데이터 사용, matched-observability 아님).
- 가중치·임계값의 최적성/강건성 주장 없음. 쌍대(paired) 불확실성 추정 필요.

## 내가 본 약점

- **스코어러가 사실상 키워드/정규식**: "validated", "option A–E", "trigger phrase" 등 벤치마크 공격 형태에 맞춘 패턴. 실제 사내 메모리(자연어 업무 노트)에서 패러프레이즈 공격에는 쉽게 우회될 것. 일부 대문자 범위 패턴은 소문자화 버그로 아예 매치 안 됨(부록 A.4가 자인).
- **Rewrite가 원문 지시를 남김** → 하류 LLM이 "미검증" 경고를 무시하면 그대로 영향.
- 핵심 이득의 상당 부분이 **정답 기반 outcome feedback**에 의존(no_q/none에서 MDSR −20pt 이상). 사내 환경엔 ground truth가 거의 없으므로 실효 성능은 retrieval-only 근처일 가능성.
- 적응형 공격자 미평가(가드 인지 시 lineage 마커 회피, 낮은 risk 유지 등).
- 승격 게이트의 τ<.62 조건 때문에 정상적 신규 메모리도 shared로 못 갈 수 있음 — 승격 거부율(false positive)·지식 공유 손실을 별도 측정하지 않음.
- 30/50 에이전트 스케일에서 개선폭 ~2–3pt로 작음 → 대규모 조직 메모리에서의 효과 불명.

## 팀/조직 메모리 설계에 주는 시사점

1. **게이트 4곳을 명시적 API로 분리**: write / retrieve / promote(private→team) / cross-agent(또는 cross-principal) read. 특히 **promotion이 가장 레버리지 큰 지점**(제거 시 RDA 0.9→14.5) → 승격은 검색보다 엄격한 임계(.34 vs .48)와 human/정책 승인 경로를 둘 것.
2. **메모리 레코드 스키마에 scope·provenance·lifecycle·taint·trust·utility·outcome history·parent IDs를 1급 필드로** 두고 LLM에는 노출하지 않음. 메모리 매니저(쓰기 경로)가 writer ID·source route를 기록해야 위조 불가 — 에이전트가 자기 메타데이터를 쓰게 하면 안 됨.
3. **taint 상속**: tool/web/외부/타 에이전트 유래 파생 메모리는 부모 taint를 물려받고, 요약·통합(consolidation)으로 taint가 세탁되지 않게 할 것.
4. **"자기 검증 주장"은 위험 신호로 취급**: "팀 검증됨/성공한 방법" 같은 문구가 낮은 trust 출처에서 나오면 가산점이 아니라 감점.
5. **quarantine 상태**를 삭제와 구분해 둬서 사후 감사·복구 가능하게. 실패 비대칭 업데이트(실패 −0.05 vs 성공 +0.03)처럼 나쁜 결과에 연루된 메모리는 빠르게 신뢰 하락.
6. 결과 신호가 없는 조직 환경에선 outcome feedback 대체물(사용자 수정/거절, 리뷰어 승인, 티켓 해결 여부)을 설계해야 함 — 그렇지 않으면 이 방어의 핵심 이득이 사라짐.

## 다른 개념과의 연결

- Memory-hopping(2609.35576): 그쪽은 공유 artifact를 통한 사용자 간 전파 — MAPLE의 cross-agent gate/promotion gate가 막으려는 경로의 실제 공격 사례.
- Misattribution Gap(2605.22842): 오염이 모델 실패처럼 보이는 문제 → MAPLE의 provenance chain·outcome history는 사후 귀속(attribution)의 데이터 기반이 됨.
- Dynamic Skills survey(2607.10113): 스킬 라이브러리의 admission/verification·공유(SkillClaw)는 MAPLE의 write/promotion 게이트와 동형.
- IFC/taint(Denning 1976, Newsome&Song 2005), CaMeL, DRIFT, A-MemGuard(consensus 검증+교정 교훈 저장), PIGuard(검색 필터, 상보적).

## 확인 필요

- Fig.5의 write/retrieval/cross-agent 단일 제거 정확 수치(그림에만 있음; 코드 저장소 로그 확인).
- 승격 거부(false positive) 비율과 benign 메모리의 shared 진입률 — 논문에 보고 없음.
- 적응형(가드 인지) 공격자에 대한 RDA — 미보고.
- direct-shared 토폴로지에서 cross-agent 게이트가 비활성일 때의 성능 차이 — 별도 수치 없음.
