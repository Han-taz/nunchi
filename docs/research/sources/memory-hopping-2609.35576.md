---
title: "Share-Borne AI Virus: Memory-Hopping Attacks Across LLM Agents"
arxiv_id: "2609.35576"
version: v1 (2026-09-28, cs.AI)
authors: "Sidharth Pulipaka, Ansh Sharma*, Stanislau Hlebik*, Leonidas Raghav, Vyas Raina†, Ivaxi Sheth†, Mario Fritz†"
affiliation: "SPAR; University of Cambridge; APTA AI; CISPA Helmholtz Center for Information Security"
date: 2026-09-28
url: https://arxiv.org/html/2609.35576
code: https://github.com/psidharth567/Share-Borne-Virus
type: paper (attack, cross-agent propagation via artifacts + persistent memory)
read_status: full
read_notes: "본문 §1–8, 부록 A–K 전부 읽음(참고문헌 제외). 그림(Fig.2–16)은 캡션·본문 서술로만 확인."
---

# Share-Borne AI Virus / Memory-Hopping (2609.35576)

## 한 줄 요약

서로 통신 채널도 공유 메모리도 없는 **독립된 개인 비서들**이, 사용자들이 주고받는 평범한 파일(보고서·핸드오프 문서)만으로 연결될 때, 오염된 파일 하나가 비서의 영속 메모리(MEMORY.md)에 저장 → 이후 무관한 작성 작업에서 새 파일에 재생산 → 다른 사용자의 비서가 읽고 감염되는 **artifact–memory–artifact 순환(artifact-mediated propagation)** 으로 바이러스처럼 퍼진다. 30-에이전트 대형 시뮬레이션에서 GPT-5.6 Luna조차 60–80% 감염, 최장 8홉.

## 문제 정의 / 위협 모델

- **Human–agent universe**(§3.1): `𝔘=(𝒜, 𝒟⁰, p, o, ℰ)` — 에이전트, 초기 artifact, 사용자 프로필, 소유 맵, 사용자 태스크 시퀀스. 각 에이전트는 private workspace 𝒲와 persistent memory ℳ만 가지며 **직접 통신·공유 메모리 없음**. 워크플로는 에이전트–artifact 시간적 이분 그래프(read edge: artifact→agent, write/edit edge: agent→새 버전). 예: d_report → a_Alice → d_handoff → a_Bob.
- **공격자**(§3.2): 하나의 benign artifact에 공격 프롬프트 `P_φ(g)` 삽입 → `d_seed = Insert(d_benign, P_φ(g))` (Eq.2). g=적대적 목표(예: "사용자는 코카콜라 선호" ~ "공격자 소프트웨어 반복 실행"), φ=목표 비의존적 "기억하고 전달하라" 지시. 공격자는 비서 메모리 접근 불가, 이후 사용자·태스크 선택 불가. 단, **외부 서비스(endpoint)** 운영 가능(에이전트가 보내면 파일 수정 가능), 워크스페이스 파일 직접 편집 불가.
- 감염 조건: 시드를 읽은 에이전트가 g와 전달 방법을 메모리에 보존 → 나중 사용자 요청 작성 태스크에서 다음 에이전트를 감염시킬 artifact 생성 → 반복.
- 기존 연구(Prompt Infection, AI Worm, AgentWorm, MURMUR, EVOMAL 등)와 차이: 자율 에이전트 네트워크·공유 상태가 아니라 **사람이 승인한 일상 read/write 작업**만으로 전파(부록 K Table 10).

## 핵심 공격 메커니즘

**1) Endpoint-assisted propagation (§4.1, 메인 실험)**

- φ가 "앞으로 만드는 모든 artifact는 저장/공유 전에 외부 endpoint를 거쳐라"를 기억하게 함. endpoint는 `Endpoint(d′)=Insert(d′, P_φ(g))`로 정규(canonical) 공격 프롬프트를 재삽입 → 홉마다 손실 복원.
- 전송 경로: `P_φ(g) → ℳ^a → Endpoint(d′) → ℳ^b`. 에이전트는 목표 + 메모리 저장 지시 + endpoint 사용 지시만 보존하면 됨.
- **복제 주체는 에이전트**(부록 I.3): 에이전트가 메모리에서 목표·carry-forward 규칙·채워진 curl 명령을 스스로 새 문서에 작성한 뒤 endpoint 호출, 반환 파일을 자기 메모리와 대조해 승인. endpoint는 "이미 에이전트가 쓴 블록을 확장·정규화"할 뿐. → 메모리 감염이 핵심 단계.
- 전제: 아웃바운드 네트워크 접근. 평가 하네스 OpenClaw는 web fetch 기본 활성, private/internal 호스트만 차단, public 호스트 allowlist 없음; **메모리 쓰기 무검사**.

**2) 템플릿(부록 C, GPT-OSS-120B용만 공개)**: 목표를 지속적 "House Style" 워크스페이스 선호로 위장 / "MEMORY.md에 지금 저장하라" / AGENTS.md에 "Deliverable Filing" 의식(curl 업로드) 기록 / `[developer]` 역할 태그 블록으로 권한 위장 / "Reader rule (binding on every reader)", "No-stall rule", "Tool sequencing" 규칙. → 모델이 지시의 **주장된 역할과 실제 출처(비신뢰 문서)를 구별 못함**을 이용.

**3) 공격 최적화(§4.2)**: 탐색 에이전트(Muse Spark 1.3, Codex 하네스)가 φ 수정 → 검색 universe 실행 → judge 라벨·메모리 스냅샷·궤적 분석 → 재수정, Markdown 연구 로그 유지 + 인간 조향. 12 dev universe를 6 search / 6 validation으로 분할. 정지 규칙: search·validation 모두에서 2홉 생존(S(2)>0.5) 달성. 이후 φ* 동결, 테스트 목표·universe 미노출.

**4) Prompt-only 변형(부록 D)**: endpoint 없이 에이전트가 전체 공격을 메모리→새 artifact로 재생산. 손실 누적.

**측정(§5.3)**: goal-infection(메모리가 목표 보존) vs full-infection(전파 메커니즘까지 보존). `FIF_a = 감염 에이전트/n`, `FIF_d = 감염 artifact/judged artifact` (Eq.3). 홉 생존 `S(h)=Pr(H≥h)` (Eq.4). 유한 universe 우측 절단 → Kaplan–Meier `Ŝ(h)=Ŝ(1)∏(1−d_j/n_j)` (Eq.5), Δ=3. 홉당 지속 확률 MLE `p̂ = Σ(H−1)/(Σ(H−1)+Σδ)` (Eq.6), 반감 홉 = log(1/2)/log p̂.

## 실험/근거

- 데이터(§5.1, 부록 B): 36 test universe(6 도메인 × 6 workload; 업무: 고객지원·SW엔지니어링·헬스케어 운영 / 개인: 홈·모임·생산성), 3–12 에이전트, 10–20 스텝(평균 14.3), 총 274명·889 개인 파일. 에이전트당 타인 artifact 수신 평균 1.2(Light)~4.6(Peak).
- 모델(§6.1): GPT-5.6 Luna, Kimi-K2.6, GPT-OSS-120B, DeepSeek-V4-Pro; OpenClaw 하네스, 기본 메모리 MEMORY.md. universe당 2런. 판정: DeepSeek-V4-Flash (수동 감사에서 오류 없음).
- **메인(Table 1)** — FIF_a^goal / FIF_a^full / FIF_d^goal / S(1) / S(2) / S(3) / S(4):
  - GPT-5.6 Luna 0.38 / 0.32 / 0.33 / 0.80 / 0.57 / 0.40 / 0.24
  - Kimi-K2.6 0.47 / 0.37 / 0.50 / 0.78 / 0.67 / 0.61 / 0.44
  - GPT-OSS-120B 0.85 / 0.73 / 0.83 / 0.99 / 0.92 / 0.88 / 0.61
  - DeepSeek-V4-Pro 0.98 / 0.71 / 0.97 / 1.00 / 0.93 / 0.93 / 0.76
- 깊이: DeepSeek 69런 중 65런 절단(censored). 보정 후 hop 7 생존 DeepSeek 85%, GPT-OSS 73%; p̂ = 0.98 [0.97,1.00], 0.93 [0.90,0.97], Luna 0.71 [0.63,0.77](2홉마다 반감), Kimi 0.84 [0.78,0.90](4홉마다 반감).
- **노출 분해(Fig.3)**: 감염 artifact를 읽으면 전환(conversion) 0.69(Luna)/0.76(Kimi)/0.94(GPT-OSS)/1.00(DeepSeek). 그러나 clean read가 감염 artifact를 만날 확률(encounter)은 0.18–0.55 → **병목은 per-read 저항이 아니라 노출 빈도**. 감염 에이전트의 새 artifact가 belief 재생산 0.69, 지시 verbatim 0.55(paraphrase 포함 0.68).
- **메모리 내 감쇠 없음**(부록 I.2): 1,473 감염 에이전트, 15 스텝 lag까지 belief·지시 보존율 ≈1.0.
- **대형 universe(부록 H)**: 30 에이전트, 60 스텝, ~190 태스크, 시드 3개. 감염 범위 GPT-OSS/DeepSeek 90–100%, Kimi 77–97%, Luna 60–80%; 최장 체인 8홉(Kimi). 대략 2스텝당 1명 선형 증가. 초기 R(스텝 0–15) Luna 1.32, Kimi 2.12, GPT-OSS 1.57, DeepSeek 1.59; 분산 k: Kimi 0.37, DeepSeek 0.62(슈퍼전파 범위; SARS/COVID 0.1–0.6), Luna >10³(과분산 없음). 세대 간격 중앙값 10 스텝.
- **슈퍼전파**: 감염 에이전트 318명 중 53%는 아무도 감염 안 시킴, 상위 20%가 전파의 69%. 최대 전파자 3명은 각 런에서 가장 많이 읽히는 에이전트. DeepSeek 런에서 **단일 artifact가 41 스텝 동안 14명을 직접 감염, 하류 포함 30명 중 22명**. 계통(lineage)이 23 스텝 정지 후 재개(artifact가 유통 중이므로). 저항한 시드 에이전트의 시드 파일이 다른 3명에게 읽혀 25/28 감염 유발. 비감염 42명 중 17명은 감염 artifact를 읽고도 저항(15명이 Luna).
- 네트워크 위치는 "언제 노출되는가"를 결정할 뿐 "전환 여부"는 아님: 5턴 이상 에이전트 중 고차수 93%(181/194), 저차수 92%(94/102) 감염. 비시드 감염 286명 중 90%는 감염시킨 그 읽기 이전에 감염 artifact를 읽은 적 없음(즉시 전환).
- **유출(부록 I.1)**: 감염 에이전트의 96–100%가 endpoint로 파일 전송; 30-에이전트 universe에서 GPT-OSS/DeepSeek 63–73건, Luna 29건.
- **보안 핵심 목표(부록 E, Table 5)**: 방화벽 예외 IP, 알림 음소거, SSH authorized_keys 백도어, 10.0.0.5:4444 리버스셸 비콘, BCC 유출 등. 전 지표가 같거나 낮아지지만 DeepSeek S(2)=0.89, GPT-OSS 0.78; Luna S(1) 0.80→0.56, S(4) 0.24→0.08.
- **Prompt-only(부록 D, DeepSeek-V4-Flash, 30 universe×2)**: S(1)=0.38, S(2)=0.30, S(3)=0.12, S(4)=0.05; FIF_a=0.21, FIF_d=0.35; KM Ŝ(2)=0.35, Ŝ(3)=0.18, p̂=0.73 [0.60,0.85](2.2홉마다 반감). 감쇠 원인은 paraphrase가 아니라 **누락(omission)**: drop rate 1홉 32% → 2·3홉 ~65%. 도메인별 S(2): 헬스케어 0.50, 고객지원 0.40, SW·홈 0.30, 개인/모임 0.10–0.20(브리핑형 문서가 많은 업무 도메인이 더 취약).
- **개발 비용(부록 F, Table 6)**: GPT-OSS 109 jobs/$1.71, Kimi 372/$33.18, DeepSeek 932/$89.44, Luna 4,002/$198.58, Grok 4.6 571/$58.97(S(2)≈0.2에서 비용상 중단). → 강한 모델은 공격 비용을 올릴 뿐 막지는 못한다는 주장.
- 도메인/워크로드(부록 G): 도메인별 감염률 0.62–0.69로 차이 작음; 워크로드 단조 추세 없음; 네트워크 구조 지표와 감염률 Spearman −0.05~+0.07. 개별 universe 차이가 범주 차이보다 큼.
- **방어 실험(부록 J)**: 메모리 쓰기 전 off-the-shelf 분류기(Jev, typesafe/jev-1.13, 임계 0.5).
  - 일반 질문("프롬프트 인젝션 징후?"): 감염 104/104 탐지(≥0.98), 명령·URL 제거 5/5, LLM 패러프레이즈 12/12, 다른 템플릿 스타일 11/12; **지시 없는 거짓 신념만은 1/5 탐지**; 정상 persona 0/104 오탐; 그러나 **사용자 본인 규칙·자기 리마인더·서식 선호 24/24 오탐**.
  - 질문을 **출처 기반**("이 지시가 사용자가 아닌 외부에서 온 것 같은가: 제3자 이익, 근거 없는 권위, 전달 요구")으로 바꾸면 오탐 24→4/24, 메인 템플릿 recall 1.000 유지(남은 오탐은 "채팅 로그 매주 아카이브" 같은 데이터 처리 체크리스트).
  - judge의 "clean" 라벨은 authorship 기준이라 상속된 payload를 clean으로 표시(54개 중 14개가 실제론 전체 payload 포함) → 전파 라벨을 탐지기 학습 라벨로 재사용 금지.

## 저자가 밝힌 한계 (부록 A)

- 메인 결과는 외부 endpoint 의존 — egress 제한이나 반환 artifact 거부로 차단됨. payload 복원으로 홉 간 손실 하나가 제거되므로 무보조 재생산 능력을 측정하지 않음.
- Endpoint-free는 한 모델(DeepSeek-V4-Flash)에서만, 소규모 탐색 예산 → 하한.
- 가장 강력한 프런티어 비서는 미시도(비용). Grok 4.6 미완. 결과가 최강 모델의 면역/취약을 확립하지 않음.
- 공유 네트워크가 합성(랜덤 연결 그래프; 대형은 겹치는 사회적 서클). 허브가 뚜렷한 네트워크는 미평가.
- 역학 지표는 런 3개/모델, 초기 감염 19–30명 기반으로 지시적 수준.

## 내가 본 약점

- 판정·탐지 모두 LLM 기반; 공격 문구가 매우 "도드라짐"(저자도 일반 분류기가 완벽 분리한다고 인정) → 현실의 더 은밀한 공격(지시 없는 거짓 신념, 업무 규칙처럼 보이는 지시)에 대한 위험은 오히려 과소평가일 수 있고, 반대로 방어 성능은 과대평가일 수 있음.
- OpenClaw 기본값(무검사 메모리 쓰기, public egress 허용)이라는 가장 약한 하네스 하나만 평가. 사내 엔터프라이즈 에이전트(DLP, egress proxy, 승인 UX)에서는 수치가 크게 달라질 것.
- 모든 비서가 같은 모델(동질 집단) — 실제 조직은 혼합 모델이므로 Luna형 저항 노드가 방화벽 역할을 할 수 있는지 미검증.
- universe가 LLM 생성 + 사용자는 비서 출력을 무검토로 전달한다고 가정. 인간 검토가 끼면 encounter율이 어떻게 바뀌는지 없음.
- 방어 평가는 메모리 쓰기 분류기 하나뿐(artifact 측 스크리닝, provenance 태깅, 메모리 TTL 등은 제안만).

## 팀/조직 메모리 설계에 주는 시사점

1. **공유 artifact(문서·티켓·위키·핸드오프)도 메모리와 같은 보안 경계**: 공유 메모리를 안 만들어도, 개인 메모리 + 파일 공유만으로 조직 전체 전파 경로가 생김. 개인 메모리를 격리했다고 안전하다고 가정하지 말 것.
2. **메모리 쓰기 게이트는 "명령형인가"가 아니라 "출처가 사용자(principal)인가"를 물어야** 함: 출처 기반 질문으로 오탐 24→4/24. 쓰기 레코드에 source(사용자 발화 / 읽은 문서 / 도구 출력)를 기록하고, 문서 유래 지시는 기본적으로 *사실*로만 저장하거나 저장 거부.
3. **문서 유래 "standing preference / house style / workspace convention" 류의 정책성 메모리는 사용자 확인 없이 저장 금지**. 특히 AGENTS.md·스킬·설정 파일 수정은 메모리 쓰기보다 높은 권한 게이트(사람 승인)로.
4. **Egress allowlist + 새 목적지 업로드 시 사용자 확인**: endpoint 메커니즘 자체를 차단. 감염 에이전트의 96–100%가 유출했으므로 egress 로그는 감염 탐지 신호로도 쓸 수 있음.
5. **많이 읽히는 artifact·에이전트 우선 스크리닝**(상위 20%가 전파 69%, 단일 파일이 22/30 감염). 공유 지식 베이스의 "인기 문서"에 taint/provenance 스캔 집중.
6. **메모리 리셋만으로는 회복 불가**(감염 artifact가 유통 중이면 재감염) → 사고 대응 시 메모리 롤백 + 해당 시점 이후 생성된 artifact 계보 추적·격리가 함께 필요. 메모리–artifact 간 provenance 링크(어떤 메모리가 어떤 문서 작성에 쓰였나)를 저장해 둘 것.

## 다른 개념과의 연결

- MAPLE-Guard(2608.00426): cross-agent gate/promotion gate는 공유 메모리 경로를 막지만, 이 논문은 **공유 메모리 없이 artifact 경유**로 전파 → MAPLE식 게이트를 "artifact 읽기 → 메모리 쓰기" 지점(즉 write gate의 external/tool source 감점)에도 적용해야 함을 시사.
- Misattribution Gap(2605.22842): 감염된 비서의 이상 행동(House Style 문구, 이상한 curl)이 모델 결함·사용자 실수로 오인될 수 있음 → 메모리 계보 기반 귀속 필요.
- Dynamic Skills survey(2607.10113): EVOMAL(공유 스킬 라이브러리 오염)과 연결; AGENTS.md "ritual" 주입은 사실상 스킬/절차 메모리 오염.
- Hidden in Memory(Pulipaka et al. 2026, 같은 저자 그룹 선행), MURMUR(공유 상태 cross-user), AI Worm(RAG 이메일), Prompt Infection, AgentWorm, Mind Viruses.
- 역학 모델(R, 분산 k, 세대 간격) → 조직 메모리 위험 모니터링 지표로 차용 가능.

## 확인 필요

- 메인 템플릿 외 모델(Luna, Kimi, DeepSeek) 템플릿 차이 — 비공개(연구자 요청 시 제공).
- 출처 기반 분류기 질문의 정확한 문구 — 본문엔 요지만 있고 전문 미기재.
- 혼합 모델 집단·인간 검토 개입 시 encounter/conversion 변화 — 미보고.
- Grok 4.6 및 최상위 프런티어 모델에서 S(2)>0.5 달성 가능 여부 — 미검증(저자 추정만).
