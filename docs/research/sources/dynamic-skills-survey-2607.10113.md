---
title: "Dynamic Agent Skills: A Lifecycle Survey and Taxonomy of Evolving Skill Libraries"
arxiv_id: "2607.10113"
version: v1 (2026-07-11, cs.AI); OpenReview 리뷰 완료 표기(forum cjU3YbcRr8)
authors: "Yubo Li"
affiliation: "Carnegie Mellon University (NIST award 60NANB24D231, CMU AIMSEC 지원)"
date: 2026-07-11
url: https://arxiv.org/html/2607.10113
type: survey (dynamic skill libraries; lifecycle, verification, governance, safety)
read_status: full
read_notes: "본문 §1–15 전부 읽음. 부록 A(코딩 프로토콜·증거 등급·Table 11 마스터 코딩 시트)는 프로토콜과 SkillClaw/AutoSkill/AgentDevel/SkillsVote/ASG-SI/ClawSafety/PSN/MetaClaw 행 위주로 확인, 참고문헌은 생략. Table 11 범례 중 operator 문자(K, W, B, C 등)의 전체 정의는 추출본에서 'P=Prune,' 이후가 잘려 확인 못 함. 그림 1–4는 캡션/본문 서술로만 확인. 서베이 특성상 SkillClaw·ClawSafety 원 논문의 세부는 이 문서에 없음."
---

# Dynamic Agent Skills Survey (2607.10113)

## 한 줄 요약

2023–2026(컷오프 2026-05-31) 124편을 감사해, "스킬 라이브러리"를 **라이프사이클 관리·검증·진화하는 아티팩트 저장소**로 재정의한 서베이. 8단계 라이프사이클(증거 수집 → 제안 → 검증/승인 → 조직/저장 → 검색/합성 → 유지/보수 → 증류/이식 → 거버넌스/출처), 7필드 스킬 레코드 `⟨C,π,T,R,φ,ν,≺⟩`, 10개 편집 연산자를 제시하고, 가장 강하게 뒷받침되는 패턴은 **"쓰기 시점의 규율(admission·verifier 품질·maintenance)"**이라고 결론. 안전은 8개 표면으로 정리하며 "공격 연구는 많고 방어가 통합된 동적 시스템은 거의 없다"고 진단.

## 문제 정의 / 위협 모델

- 질문: 에이전트 외부에 저장된 재사용 절차(스킬)가 **시간에 따라 어떻게 바뀌어야 하는가**. 정적 라이브러리(한 번 작성, 드물게 버전업)는 실패한다(§4): ① 작성 비용(가치는 사용 후에야 드러남) ② 정확성이 비정상적(도구·모델·런타임 드리프트로 문법상 유효하지만 운영상 틀린 스킬) ③ 규모가 커지면 선택이 저장보다 어려워짐 ④ **provenance**: 일반 버전관리는 누가/언제 고쳤는지는 남기지만 *어떤 궤적·verifier·배포 신호가 승인을 정당화했는지*는 안 남김 → 회귀 시 롤백·재승인·사용자 간 스킬 귀속/삭제 불가 ⑤ 배포 분포 비정상성.
- "skill"의 6가지 의미(§3.1, Table 1): 실행 코드 / NL 휴리스틱(교훈) / SKILL.md 패키지(L1 메타데이터·L2 지시·L3 코드/스키마) / 파라메트릭(LoRA·어댑터) / 메모리·궤적(경계 사례) / 능력 라벨(경계 사례). 속성 5개: 실행가능·제자리 편집·백본 이식·사람 검사 가능·검증 핸들.
- 스킬 vs 도구: 같은 함수라도 에이전트가 제안·궤적 기반 수정·승인 검증·lineage 저장·유지/이전하면 스킬. 즉 **ℒt→ℒt+1 전이에 참여하는가**가 기준.
- 위협 모델은 서베이 전체가 아니라 §11 안전 절에서 표면별로 정리(아래).

## 핵심 설계: 라이프사이클·스키마·연산자

**1) 스킬 레코드 (§3.2, Eq.1–2)**

- SoK-Skills의 정적 4-튜플 `⟨C 적용조건, π 정책, T 종료조건, R 재사용 인터페이스⟩`에 동적 필드 3개 추가 → `𝒮t = ⟨Ct, πt, Tt, Rt, φt, νt, ≺t⟩`.
  - `φ` 편집 필드: 결정적 `𝒮t × ut → 𝒮t+1` 또는 확률적 제안 커널 `q(𝒮′|𝒮t,ut)`. 개선 보장 없음 — 승인이 결정.
  - `ν: 𝒮 → {0,1}` 검증 필드: 단위테스트(LATM), grounded rollout(SkillWeaver, EvoSkill), 메타에이전트 검사(AgentFactory), 앙상블 judge(Trace2Skill), 정적 분석(SkillCraft), 기호 감사(ASG-SI), 미래 효용 베이지안 prior(CODE-SHARP).
  - `≺` lineage: 어느 버전이 어느 버전을 대체했는가. 롤백, A/B 성숙도, blast-radius 제한에 필수.
- "무조건 통과 verifier + 반복 Add"는 정적이 아니라 **필터 없는 append-only 저장소**.

**2) 라이브러리 전이 (§3.3, Eq.3–4)**

- `ℒt = {𝒮t(1..Nt)} ∪ ℳt` (ℳt: 호출 통계, 호출 그래프, 성숙도 라벨, verifier 캐시, 작성자 등 cross-skill 엣지).
- `ℒt+1 = 𝒯(ℒt, τt, rt) = Apply(u⃗t(τt, rt), ℒt)` — τ 진화 트리거(타이머, 태스크 경계, 실패 이벤트, 사용자 편집), r 학습 신호(태스크 보상, NL 비평, 자기 판단, **cross-user 집계**, 교사 신호).
- **10 연산자**: Add / Refine(인터페이스 유지 내용 수정) / Merge / Split / Prune(제거 또는 quarantine) / Distill(궤적→스킬) / Abstract(구체 절차→템플릿) / Compose / Rewrite(본문·인터페이스 변경) / Rerank(내용 불변, 검색 prior만 변경). 10개 전부 구현한 방법은 거의 없음 — 지원 부분집합이 분류 지문.
- 검증은 스킬별 필드지만 **라이브러리 수준 승인 게이트**로 작동: 편집 → 후보 𝒮* → 승인 정책 통과 시에만 ℒt+1 진입.
- 예시(§3.4 AutoRefine): τ=TaskEnd/Periodic, u⃗ = {(Refine, 모호 단계 패치), (Merge, 중복 루틴), (Prune, 저효용 스킬 quarantine)} → 통과 시 ≺에 대체/병합 기록, 실패 시 이전 버전 유지 또는 후일 검토 표시.

**3) 8단계 라이프사이클 (§5.1, Table 2)** — 설계 질문 / 대표 실패

1. 증거 수집: 무엇이 변경을 정당화하나 (궤적, 보상, 실패, 사용자 편집, cross-user 신호) — 잡음, 비정상 효용
2. 제안/생성 (Add, Abstract) — 과특화/과일반화
3. **검증·승인** (Refine, Rewrite): 후보가 mature / tentative / quarantined / rejected 중 무엇으로 들어가나 — 그럴듯하지만 틀린 스킬, **verifier hacking**
4. 조직/저장 (Split, Merge, Rerank): flat / 트리 / DAG / 호출 그래프 / 온톨로지 / 파라메트릭 — flat 검색 붕괴, 낡은 구조
5. 검색/합성 (Rerank, Compose) — **사용 ≠ 효용**, distractor 부하
6. 유지/보수 (Prune, Merge, Refine, Rewrite) — 무한 성장, 음의 전이
7. 증류/이식 (Distill, Abstract) — 파라메트릭 붕괴, 호환성 실패
8. **거버넌스/출처**: 감사·귀속·롤백 가능한가. 구현상 "승인 후보·verifier 결정·연산자 편집·롤백 이벤트에 대한 감사 로그" — 스킬 주입, 유출, 귀속 상실

- 워터폴이 아님(제안↔검증 루프, 주기적 증류). 거버넌스·증류는 래퍼/사이드 루프.

**4) 승인 경계 (§5.2)** — 가장 중요한 경계는 *후보*와 *승인된 라이브러리 상태* 사이. 실행 기반(SkillWeaver, EvoSkill, SkillFoundry)은 쓰기 시점에, 유지 중심(AutoRefine, AgentSkillOS)은 노화 중 재실행, 롤백형(PSN)은 최근 태스크 효용이 안정될 때까지 **승인을 잠정(tentative)**으로 취급. 승인 근거(궤적·validator·cross-user 신호·release audit)를 저장해야 이후 강등·수정·제거가 가능 — "lineage가 없으면 동적 스킬은 포맷만 세련된 append-only 메모리".

**5) 검증 아키텍처 (§7.2, Table 4)** — 형식 / 시점(W 쓰기, I 호출, M 유지) / 승인 정책

- 실행 테스트·rollout: W, hard, 비용 高, 커버리지 좁음 (테스트 통과 ≠ 일반화 → 연산자 {Add, Refine, Prune}로 제한되는 경향)
- Judge-LLM 루브릭/메타에이전트: W+M, hard/Pareto, 중간 — evaluator drift, rubric hacking 취약
- 앙상블 투표: W+M, **maturity-gated**(trial로 진입, 사용 예산 후 승격)
- 기호/감사: W+M, graph integrity (ASG-SI, SkillOps)
- **롤백 검증(PSN)**: 잠정 승인 후 최근 3개 태스크 성공률이 20%↑ 하락하면 되돌림(Δ-success ≤20%)
- 경제/효용: I+eviction, 효용 임계 — 저렴·현실적이나 증거 쌓이기 전 해로운 스킬 승인 가능
- 보안 triage/red-team: W+I, quarantine/review
- 결론: 고용량 시스템은 **단계적 승인**(tentative / quarantined / promoted / demoted / rolled back)으로 이동.

**6) 2-시간척도 (§7.4, Table 5)**: 빠른 외부 루프(파일·절차 편집) + 느린 내부 루프(어댑터·가중치·공유 라이브러리로 증류). 핵심 변수는 **승격(promotion) 기준**: prevalence(저렴), reward(태스크 근거), coverage(다양성), stability(증류가 보존할지에 가장 가까움). 시끄러운 빠른 루프 → 실수까지 압축.

**7) 인프라·마켓 (§10.3, Table 8)**: pull-model(중앙 큐레이션 레지스트리; Skilldex, SkillsVote), **push-model(SkillClaw cross-user — Add는 빠르나 Merge/Prune 비용 큼, trade-off: velocity/provenance)**, hybrid(**AutoSkill dual review**, 사용자별 override), governed evolution(SkillsVote: skill-linked credit, evidence-gated evolution), package-manager(Skilldex: scoped install, conformance). 편집 파이프라인: inline(명시적 버전 저장소 필요) / log-and-apply(스테이징→검증→커밋) / shadow-execution(그림자 라이브러리 진화 후 증류 창에서 cut-over) / compile-and-serve.

## 실험/근거 (서베이가 인용한 수치 — 원 논문 미확인)

- 코퍼스: 124편(2023: 2, 2024: 0, 2025: 19, 2026: 103). 증거 등급 A(복수 통제 ablation 또는 깨끗한 ablation+독립 확인) / B(통제 연구 1개 또는 강한 벤치·배포 측정) / C(수렴하는 벤치 행동, 인과 ablation 없음) / D(아키텍처적 확인만).
- **7개 패턴 (Table 7)**:
  1. 승인 게이트 중요 — 큐레이션 스킬 > 미검증 자기생성 (A/B). EvoSkill Pareto 선택 OfficeQA +7.3, SealQA +12.1; **CoEvoSkills surrogate verifier 제거 시 SkillsBench 71.1%→41.1%**; SkillWeaver practice+verify 제거 시 가장 어려운 웹 태스크에서 무-라이브러리 기준선 아래로.
  2. skill-aware RL에서 verifier 품질이 결정적 (B). CODE-SHARP 24.30→41.02%; Agentic-Proposing 문제 유효성 68.7→82.3%.
  3. flat 검색은 ~100개 근처에서 저하 (B/C). Single-Agent-Skills: 16–32개 96–98%, 64개 92%, 128개 78%, 256개 64%. SkillRouter 80K, SRA 26,262개, Wild-Skills 34K.
  4. 약한 백본의 상대 이득이 큼 (C).
  5. 집중 라이브러리 > 포괄 라이브러리 (B/C). SWE-Skills-Bench: 공개 SWE 스킬 49개·~565 태스크에서 평균 +1.2%, 39개 무개선, 3개 회귀.
  6. 중대형 규모에선 유지보수가 하중을 받음 (B). **AutoRefine 유지 off: TravelPlanner 35.6→31.1%, 저장소 4.5× 성장, 활용률 0.71→0.08**; SkillOps 유지 제거 ALFWorld 79.5→71.9%.
  7. 쓰기 시점 추상화 > 읽기 시점만 (B/C). SimpleMem 쓰기 시점 압축 제거 LoCoMo F1 43.24→31.29.
- **사용 ≠ 효용 (SkillFlow-Bench, 166 태스크/20 패밀리)**: Claude Opus 4.6 62.65→71.08%, Kimi K2.5는 스킬 사용 66.87%에도 +0.60pt, GPT 5.3 Codex는 −6.02pt.
- **안전 표면 수치 (Table 9, §11.1)**:
  - 스킬 내장 프롬프트 인젝션: **ClawSafety — OpenClaw 개인 에이전트에서 악성 스킬 파일이 최고 ASR 벡터, 백본 평균 69.4%**; Skill-Inject 202 쌍, 맥락 ASR ~40–80%; SkillJect 최적화 후 95.1%(naive 10.9%).
  - 공급망: AgentSkills-Wild 31,132개 중 26.1% 취약 패턴, 실행 스크립트 스킬이 지시형보다 2.12× 취약; Malicious-Skills-Wild 98,380개 중 157개 행동 확인 악성(632 취약점), 공개 후 93.6% 제거; Supply-Chain-Poisoning 1,070개, 우회율 11.6–33.5%, 정적+정렬 필터 둘 다 회피 2.5%; BadSkill(번들 모델 백도어) ASR 97.5–99.5%.
  - 유해하지만 정상 형식: HarmfulSkillBench 98,440개 중 4,858개 유해.
  - 자격증명 유출: 17,022개 샘플 중 520개(1,708 이슈), 76.3%가 NL+코드 공동 분석 필요, **디버그 로그 73.5%**(stdout이 LLM에 재주입).
  - 스캐너 한계: SkillScan precision 86.7%/recall 82.5%; SkillSieve F1 0.800, 86% 무API 필터, 스킬당 ~$0.006; Malicious-or-Not — 스캐너 플래그 2,887 조합 중 저장소 맥락 반영 시 0.52%만 악성 저장소 잔존(과탐).
  - 도메인 릴리스: MedSkillAudit 75개 중 57.3%가 Limited Release 미달, 자동감사-전문가 ICC 0.449.

## 저자가 밝힌 한계 (§13)

- 2026-05-31 컷오프, 비망라적(snowballing, arXiv 편중, PRISMA 흐름 없음) — false negative 가능성.
- 증거 이질적; 결론 대부분이 인과가 아니라 아키텍처적; 공유 하네스가 없어 교차 논문 리더보드·통합 효과크기 없음.
- "skill" 정의 불안정; 라이프사이클 프레임은 순수 파라메트릭·메모리 전용·체화 시스템에 잘 안 맞음.
- 연산자 어휘는 의도적으로 거칠며 closure·결합법칙·편집 의존성(Refine이 Prune을 유발 등)을 모델링하지 않음.

## 내가 본 약점

- **단일 저자 서베이**인데 124편을 공통 스키마로 코딩 — 코딩 신뢰도(inter-rater) 미보고. 증거 등급이 저자 판단.
- **멀티-principal(사용자·팀·조직) 관점이 얇음**: SkillClaw·AutoSkill·SkillsVote를 "cross-user family"로 묶지만, 누가 승격을 승인하는지, 사용자 간 데이터 유출, 지배적 사용자 편향("dominant-user bias")을 잔여 실패로 이름만 붙이고 메커니즘 분석은 없음.
- 안전 절은 공격·측정 위주 목록. 방어가 라이프사이클 게이트와 어떻게 결합되는지는 "필요한 8개 primitive" 수준의 처방에 그침(그것도 저자 스스로 "통합된 방어 시스템 거의 없음" 인정).
- 수치는 대부분 원 논문 그대로 인용(서로 다른 하네스) — 인용 시 원문 확인 필요.
- **메모리 오염 공격(MINJA, AgentPoison, 메모리 홉핑 등)과의 연결이 약함**: 메모리/궤적을 경계 사례로 빼면서, NL 교훈형 스킬이 사실상 절차적 메모리라는 점에서 오는 오염 경로(검증이 "downstream success"로 간접적)를 별도로 다루지 않음.

## 팀/조직 메모리 설계에 주는 시사점

1. **메모리/스킬 레코드에 `ν`(승인 근거)와 `≺`(lineage)를 1급 필드로**: 단순 git 이력이 아니라 "어떤 궤적·검증·누구의 승인으로 들어왔나"를 저장해야 회귀 시 강등/롤백, 사용자 탈퇴 시 해당 사용자 유래 항목의 삭제·redaction이 가능. 파생(Merge/Distill/Abstract) 시 부모 lineage를 모두 보존.
2. **상태 기계형 승인**: private → candidate(tentative) → shared(mature) → demoted/quarantined/rolled-back. 공유 승격은 잠정 승인 + 롤백 조건(PSN식 "최근 N 태스크 성공률 X% 하락 시 자동 되돌림")으로. 바로 shared에 쓰는 경로 금지.
3. **게이트 위치는 3곳(W/I/M)**: 쓰기 시점(스캐너+출처), 호출 시점(요청 조건부 위험 판단, STARS식 — 같은 스킬도 요청 맥락에 따라 위험도 다름), 유지 시점(주기적 재검증, verifier drift 대응). 쓰기 게이트만으로는 부족.
4. **Prune/Merge 같은 음의 연산자와 유지 스케줄이 필수**: 공유 메모리는 커질수록 distractor가 늘어 효용이 떨어짐(AutoRefine 유지 off 시 활용률 0.71→0.08, flat 검색 128개에서 78%). 팀 공유 저장소는 범위(팀/프로젝트)별로 나누고(focused library) 계층 라우팅을 둘 것.
5. **"사용됨"을 "유용함"으로 오해하지 말 것**: 공유 승격·순위의 신호로 검색/사용 빈도를 쓰면 안 되고, 사용 시 vs 미사용 시 결과 차이(SkillGen식 net interventional effect, SkillsVote식 skill-linked credit)를 측정해야 함.
6. **절차형 공유 지식(SKILL.md, AGENTS.md, 팀 규칙)은 일반 사실 메모리보다 높은 신뢰 경로이므로 더 엄격한 게이트**: ClawSafety에서 스킬 파일이 최고 ASR 벡터(69.4%). 패키지 manifest(권한·네트워크 엔드포인트·허용 도구)와 stdout/네트워크 격리(자격증명 유출 73.5%가 디버그 로그)를 함께.

## 다른 개념과의 연결

- MAPLE-Guard(2608.00426): 그쪽의 write / retrieve / promote / cross-agent 4게이트 ≈ 이 서베이의 W/I/M 승인 + 승격(promotion). MAPLE의 quarantine 상태·taint 상속은 `ν`·`≺`의 구체 구현. 승격이 가장 레버리지 큰 게이트라는 MAPLE 결과와 "승인이 선택 메커니즘"이라는 서베이 결론이 일치.
- Memory-hopping(2609.35576): AGENTS.md "ritual" 주입 = 스킬/절차 메모리 오염. 서베이의 "스킬 내장 인젝션" 표면과 같은 구조이며, 서베이가 다루지 않은 **artifact 경유 사용자 간 전파**를 보완.
- Misattribution Gap(2605.22842): 정책 형식 문서가 "규범"으로 채택되는 경로는 NL 휴리스틱형 스킬의 Add와 동형. CCT(반사실 제거)는 lineage `≺`가 있는 라이브러리에서 롤백 대상 특정에 그대로 쓸 수 있음. MP-IFC의 영속 라벨 = 이 서베이가 말하는 operator-granular provenance의 최소형.
- 서베이 내부: SkillClaw(push형 cross-user 진화), AutoSkill(dual review, 사용자별 override), SkillsVote(governed evolution), AgentDevel(release engineering + lineage), ASG-SI(audited skill graph), PSN(롤백 게이트), ClawSafety, STARS, SkillSieve, Malicious-or-Not.

## 확인 필요

- SkillClaw(Ma et al., 2026b) 원 논문: cross-user 집계의 구체 방식(어떤 신호로 공유 스킬을 Refine/Merge하나), 사용자 간 프라이버시·지배적 사용자 편향 수치 — 서베이엔 "cross-user OpenClaw interactions to evolve shared skills over deployment rounds"와 Table 11 행(ExecLib, MD, fast, User 트리거, XUser 신호, flat 저장)만 있음.
- AutoSkill(Yang et al., 2026c) "dual review"의 검토 주체(사람/LLM)와 per-user override 메커니즘.
- ClawSafety(Wei et al., 2026) 69.4% ASR의 백본 목록·방어 조건 — 서베이는 평균만 인용.
- Table 11 범례 중 operator 약어 K, W, B, C의 정의(추출본에서 잘림; W=Rewrite, C=Compose 추정이나 미확인).
- 2026-05-31 이후 논문(예: MAPLE-Guard, Memory-hopping)은 서베이 범위 밖 — 이 서베이 업데이트판 존재 여부.
