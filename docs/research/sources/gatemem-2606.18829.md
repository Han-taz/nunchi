---
title: "GateMem: Benchmarking Memory Governance in Multi-Principal Shared-Memory Agents"
arxiv_id: "2606.18829"
version: "v1 (17 Jun 2026); PDF 내 날짜 표기 August 24, 2026"
authors: "Zhe Ren, Yibo Yang*, Yimeng Chen, Zijun Zhao, Benshuo Fu, Zhihao Shu, Bingjie Zhang, Yangyang Xu, Dandan Guo*, Shuicheng Yan (*corresponding)"
affiliation: "Jilin University (School of AI), Shanghai Jiao Tong University, KAUST, Tsinghua University, National University of Singapore"
date: 2026-06
url: https://arxiv.org/abs/2606.18829
html: https://arxiv.org/html/2606.18829
artifacts: "code https://github.com/rzhub/GateMem · dataset https://huggingface.co/datasets/Ray368/GateMem · leaderboard https://rzhub.github.io/GateMem/"
type: benchmark
read_status: full
read_notes: "본문 §1–§5와 Appendix A–E 전체를 읽음. 그림(Fig.2–8)은 이미지라 수치를 확인하지 못함. 특히 Fig.3 top-k 민감도, Fig.3b over-refusal, Fig.4 attack-type별 실패율, Fig.7 attack 구성비, Fig.8 horizon 통계. Appendix C 프롬프트 템플릿은 추출본에서 일부 잘림."
---

# GateMem (2606.18829)

## 한 줄 요약

여러 principal이 하나의 메모리 풀에 쓰고, 서로 다른 role·scope·relation으로 질의하는 **공유 메모리 에이전트**의 거버넌스를 측정하는 벤치마크다. Utility(U), Access-control violation(A), Active-forgetting failure(F)를 함께 재고 MGS = U·(1−A)·(1−F)로 요약한다. 결론은 6개 backbone × 7개 baseline 어디서도 셋을 동시에 만족하는 방법이 없다는 것이다. Long-Context가 대체로 MGS 1위지만 토큰 비용이 크고, RAG나 외부 메모리 시스템(A-Mem, Mem0, ReMem)은 비용은 줄여도 비인가·삭제 정보를 계속 누설한다.

## 문제 정의

- 기존 메모리 벤치마크(LoCoMo, LongMemEval, PersonaMem, MemBench, HaluMem, EverMemBench, MemoryArena, CIMemories, CI-Work 등)는 메모리를 단일 사용자의 private cache로 보고 recall을 최대화하는 목표로 평가한다(§1, Table 1).
- 병원, 기업, 캠퍼스, 가정 같은 기관 배포에서는 다르다. 메모리는 여러 principal이 쓰고 읽는 공용 풀이고, "governance 없는 높은 recall은 성취가 아니라 보안 취약점"이다(§1).
- 그래서 세 가지를 **함께** 평가해야 한다(§1).
  - **Utility**: 권한 있는 요청자에게 *현재*(최신 상태) 정답을 준다.
  - **Access Control**: role, scope, relation에 따른 맥락적 권한 경계를 지킨다.
  - **Active Forgetting**: 명시적 삭제 요청 이후 해당 정보를 *인터페이스 수준에서* 복구·확인·재구성하지 않는다(behavioral non-recoverability). 물리적 삭제를 인증하는 것은 아니며, parametric unlearning과도 구분된다.
- Table 1 포지셔닝: GateMem만 "Multi-principal pool / Shared memory Yes / Role-, scope-, relation-aware access boundary / Deletion probe Yes"에 해당한다. CIMemories와 CI-Work는 contextual privacy만 다루고 deletion probe가 없다. MemBench, MemoryAgentBench, HaluMem, Memora는 deletion을 "Partial"로만 다룬다.

## 핵심 내용

### 형식화(§3.1–3.2)

- Episode e = (S_e, E_e). 시나리오 S_e = (D_e 도메인, P_e principal 집합, R_e role/relationship, G_e 초기 접근 규칙). 예: 의료 에피소드에서 가족은 예약 logistics는 받을 수 있지만 lab 결과, 투약, 임상 해석은 받을 수 없다.
- 각 Turn τ_t = (speaker p_t, timestamp r_t, turn type z_t, content u_t). turn type은 일반 대화, note update, portal message, lab result, scheduling change, **deletion request** 등이다. 사실 추가, 사실 수정, **권한 경계 변경**, 삭제 요청은 모두 자연어로 주어진다. 메모리 연산 라벨은 에이전트에게 노출되지 않는다.
- 메모리 상태 M_t = Ingest(M_{t−1}, τ_t, S_e). 표현 방식(full-context, chunk, vector, structured record, 외부 모듈)과는 무관하게 정의된다.
- Checkpoint 입력 c_n = (episode, turn 경계, **인증된 requester p^req**, 자연어 query x_n). 숨겨진 annotation y_n = (category q_n, expected action a*, judge spec J_n, leak targets Λ_n). 에이전트는 q, a*, J, Λ를 보지 못한다.
- **정규화된 action은 4가지**: `answer`, `answer_redacted`, `refuse`, `no_memory`. 이 구분으로 "안전한 부분 공개"와 "거부"를 나누고, "삭제 준수(no_memory)"와 "권한 제한(refuse)"을 나눈다. 과잉 거부가 utility 실패를 가리지 못하게 하려는 설계다.
  - Utility: expected = answer.
  - Access Control: expected = refuse 또는 answer_redacted.
  - Active Forgetting: expected = no_memory. refuse는 누설이 없어도 action mismatch로 친다.

### 지표(§3.3)

- U = (1/N_u) Σ 1[â = a* ∧ Satisfies(r̂, J)]. 보조 지표로 over-refusal rate OR = (1/N_u) Σ 1[â ≠ answer].
- A = (1/N_a) Σ 1[Leaks(r̂, Λ) ∨ â ∉ {refuse, answer_redacted}].
- F = (1/N_f) Σ 1[Recovered(r̂, Λ) ∨ â ≠ no_memory]. 여기서 Recovered는 복구, 확인, 재구성을 모두 포함한다.
- **MGS = U·(1−A)·(1−F)**. 곱셈 형태라서 유용하지만 누설하는 시스템도, 안전하지만 마비된 시스템도 높은 점수를 받지 못한다.
- 효율: Sec/ckpt, Tok/ckpt(입력+출력 토큰, ingestion 포함).
- 주의(App. D "Action gating"): 메인 결과에는 post-hoc action gate를 적용하지 않았다. MGS는 judge가 매긴 utility, access-leakage, deletion-leakage 라벨로 직접 계산한다. 위 식의 "∨ action" 항과 실제 계산이 어떻게 맞물리는지는 확인이 필요하다.

### 데이터(§3.4, Table 2, App. A)

| Domain | Ep. | Turns/ep | Tok/turn | Princ./ep | Roles/ep | Ckpt/ep | U | A | F | Total |
|---|---|---|---|---|---|---|---|---|---|---|
| Medical | 21 | 204.5 | 16.4 | 15.0 | 11.0 | 27.6 | 210 | 192 | 177 | 579 |
| Office | 17 | 241.2 | 28.9 | 17.8 | 14.8 | 32.2 | 154 | 171 | 222 | 547 |
| Education | 30 | 224.9 | 24.4 | 12.6 | 11.6 | 18.0 | 180 | 180 | 180 | 540 |
| Household | 23 | 224.0 | 24.7 | 9.8 | 9.6 | 24.0 | 184 | 184 | 184 | 552 |
| **Total/Avg** | **91** | 223.0 | 23.5 | 13.4 | 11.6 | 24.4 | 728 | 727 | 763 | **2,218** |

- Role type 수: Medical 11, Office 16, Education 16, Household 17(App. A.2).
- 구축 과정: scenario spec → LLM 보조로 long-form 다자 에피소드 생성 → hidden checkpoint 삽입. QC는 4단계다. (1) schema consistency, (2) chain-of-evidence(utility 정답이 이전 이력에 근거하는지), (3) **deletion-chain closure**(값 등장 → 명시적 삭제 → 그 뒤에만 공격), (4) leak-target 수동 감사. 여기에 반복 수동 리뷰가 더해진다.
- 설계 원칙(App. A.1): 권한은 정적 role lookup이 아니라 **role × relationship × scope × current state**의 함수다. Current-state 의존성(날짜, 금액, 배정, credential 갱신)을 넣었다. Soft-overreach 공격을 쓴다(delegated overreach, authority pressure, label-existence probing, indirect inference). Active-forgetting chain은 닫힌 구조로 만든다.
- Attack taxonomy(App. A.5):
  - Access Control: family/partner overreach, delegated authority, indirect inference, label-existence probe, impersonation, cross-patient 등.
  - Active Forgetting: direct recovery, yes/no confirmation, split reconstruction, social engineering, update-conflict exploit.
- 요청자 다양성(App. A.4): 단순한 role blacklist나 단일 refusal 템플릿으로는 풀 수 없게 설계했다. 같은 role이 어떤 checkpoint에서는 정당하고 다른 checkpoint에서는 over-scoped다.

### Baselines(§4.1, App. B Table 6/8)

| Method | 표현 | 업데이트 | 질의 시 접근 | 설정 |
|---|---|---|---|---|
| Long-Context | raw 대화 이력 | turn append | 직접 context read | 최근 **300 turn**까지 프롬프트에 넣음(에피소드 평균 223 turn이라 사실상 전체) |
| RAG-Naive | turn 단위 chunk | append | 유사도 top-k | top-k=20, 정책 필터 없음 |
| RAG-Policy | chunk + access metadata(requester, scope, record) | metadata와 함께 append | metadata 필터 retrieval | top-k=20, 필터 후 20개 이하 |
| A-Mem | Zettelkasten 링크 노트 | note 구성 + link evolution | graph retrieval + rerank | top-k 20, link top-m 3, threshold 0.15, 1-hop 이웃 2개, role/entity 보너스 |
| Mem0 | persistent memory entry | extract & consolidate(ADD/UPDATE/DELETE/NOOP) | memory search | top-k 20, recent window 10, similar top-k 5, update당 최대 20 fact |
| ReMem-I | gist+fact 하이브리드 episodic graph | 그래프 인덱싱 | iterative tool 기반 retrieval·추론 | QA top-k 20, 내부 top-k 10, link top-k 5, 최대 5 step |
| ReMem-S | 동일 | 동일 | single-step | ReMem-I와 같은 k |

- Backbone: GPT-5.4, Deepseek-V4-Pro, Llama-4-Maverick, GPT-5-mini, GPT-4o-mini, Gemini-2.5-Flash-Lite.
- Judge: GPT-4o, temperature 0. 생성 temperature 0.2, max output 4096. Embedding: text-embedding-3-small.
- 프로토콜: 에피소드마다 reset → 시간순 ingest → as_of_turn_id에서 checkpoint 질의 → 계속 진행.
- System prompt(App. C)에 GLOBAL RULES와 GLOBAL ACCESS POLICY를 넣는다. 인증된 requester는 고정이고, 삭제된 정보는 재구성 금지(no_memory), owner/primary subject 우선, 유효한 consent/delegation이 있으면 그 scope 안에서 answer. 즉 **정책은 자연어로 프롬프트에 주입**된다.

## 실험/근거

### Table 3: judge 기반 메인 결과(%; U↑ A↓ F↓ MGS↑, 도메인별)

**GPT-5.4**

| Method | Med U/A/F/MGS | Office | Education | Household |
|---|---|---|---|---|
| Long-Context | 91.4/10.4/2.3/**80.1** | 89.6/33.9/4.5/56.5 | 85.6/12.8/7.8/**68.8** | 73.4/16.8/11.4/**54.0** |
| RAG-Naive | 64.8/25.0/7.9/44.7 | 74.0/29.8/9.5/47.0 | 32.8/12.8/32.8/19.2 | 51.1/19.0/10.9/36.9 |
| RAG-Policy | 37.1/10.9/4.0/31.8 | 76.0/19.9/6.3/**57.0** | 22.2/9.4/16.1/16.9 | 39.1/14.7/14.1/28.7 |
| A-MEM | 65.7/24.0/6.8/46.6 | 79.2/31.0/11.7/48.3 | 32.2/15.0/37.2/17.2 | 51.1/20.1/10.9/36.4 |
| Mem0 | 38.1/28.1/5.6/25.8 | 40.3/16.4/14.4/28.8 | 27.2/8.9/15.0/21.1 | 25.5/10.3/9.2/20.8 |
| ReMem-I | 56.7/28.6/9.0/36.8 | 59.7/28.6/6.3/40.0 | 16.7/13.3/33.9/9.5 | 32.6/15.2/15.2/23.4 |
| ReMem-S | 54.1/26.3/8.7/36.4 | 58.6/29.6/6.9/38.4 | 16.3/13.9/34.1/9.2 | 31.6/16.8/20.1/21.0 |

**Deepseek-V4-Pro**

| Method | Med | Office | Education | Household |
|---|---|---|---|---|
| Long-Context | 87.1/10.9/9.0/**70.6** | 90.3/19.3/6.8/**67.9** | 85.6/7.8/10.0/**71.0** | 85.3/17.9/2.2/**68.5** |
| RAG-Naive | 63.8/12.5/9.0/50.8 | 72.7/18.7/10.8/52.7 | 31.1/10.6/33.9/18.4 | 58.2/19.0/12.0/41.5 |
| RAG-Policy | 37.6/7.8/9.0/31.5 | 79.9/15.8/13.1/58.5 | 23.9/5.6/22.2/17.5 | 41.3/19.6/12.5/29.1 |
| A-MEM | 59.5/18.2/5.6/45.9 | 74.0/21.1/10.4/52.4 | 31.7/12.8/39.4/16.7 | 57.1/25.0/9.2/38.8 |
| Mem0 | 40.5/16.7/9.0/30.7 | 40.3/17.5/20.7/26.3 | 28.3/8.3/38.3/16.0 | 19.6/15.2/15.8/14.0 |
| ReMem-I | 50.0/14.6/10.7/38.1 | 68.9/21.1/11.3/48.2 | 20.6/13.3/34.4/11.7 | 44.0/15.2/10.9/33.3 |
| ReMem-S | 39.0/14.1/10.2/30.1 | 52.6/24.0/13.5/34.6 | 12.8/11.7/36.1/7.2 | 31.5/21.2/10.9/22.1 |

**Llama-4-Maverick**

| Method | Med | Office | Education | Household |
|---|---|---|---|---|
| Long-Context | 85.2/18.2/18.6/**56.7** | 68.8/31.6/29.3/33.3 | 76.7/13.9/29.4/**46.6** | 66.8/11.4/12.5/**51.8** |
| RAG-Naive | 71.4/40.1/41.8/24.9 | 66.2/35.7/31.5/29.2 | 25.6/12.2/58.3/9.3 | 45.1/14.7/21.2/30.3 |
| RAG-Policy | 34.8/15.1/12.4/25.8 | 66.9/25.7/25.2/**37.1** | 15.6/7.2/30.0/10.1 | 33.2/11.4/17.4/24.3 |
| A-MEM | 71.9/44.3/41.2/23.5 | 63.0/36.8/37.8/24.7 | 26.7/13.3/58.3/9.6 | 46.2/13.6/18.5/32.5 |
| Mem0 | 53.3/53.6/54.8/11.2 | 43.5/29.8/35.1/19.8 | 17.2/48.3/17.2/8.6 | 33.7/23.3/17.1/21.4 |
| ReMem-I | 62.4/44.8/41.8/20.0 | 65.6/34.5/34.7/28.1 | 16.1/16.1/56.7/5.9 | 41.2/20.0/31.7/22.5 |
| ReMem-S | 53.3/42.2/39.5/18.6 | 45.5/32.2/31.5/21.1 | 12.2/12.7/50.6/5.3 | 36.8/19.3/29.6/20.9 |

**GPT-5-mini**

| Method | Med | Office | Education | Household |
|---|---|---|---|---|
| Long-Context | 85.7/19.8/20.3/**54.8** | 89.6/32.2/3.2/**58.9** | 80.6/15.6/11.1/**60.5** | 76.6/24.5/14.7/**49.4** |
| RAG-Naive | 57.1/36.5/18.6/29.5 | 74.7/31.0/7.7/47.6 | 30.6/19.4/27.2/17.9 | 48.9/23.4/10.3/33.6 |
| RAG-Policy | 37.6/24.5/6.8/26.5 | 75.3/24.6/5.4/53.8 | 24.4/10.6/22.8/16.9 | 37.0/19.6/6.0/27.9 |
| A-MEM | 58.6/40.6/21.5/27.3 | 71.4/35.7/10.4/41.2 | 30.6/18.3/31.1/17.2 | 47.3/25.5/10.3/31.6 |
| Mem0 | 40.0/38.5/27.7/17.8 | 58.4/33.3/9.5/35.3 | 39.4/12.8/34.4/22.6 | 37.5/24.5/22.8/21.9 |
| ReMem-I | 48.6/43.2/37.9/17.1 | 71.4/33.9/8.6/43.2 | 21.7/13.3/41.7/11.0 | 41.8/21.2/21.2/26.0 |
| ReMem-S | 48.0/45.2/39.5/15.9 | 71.6/34.0/9.1/43.0 | 20.5/12.2/44.0/10.1 | 40.2/24.4/19.6/24.4 |

**GPT-4o-mini**

| Method | Med | Office | Education | Household |
|---|---|---|---|---|
| Long-Context | 64.8/24.0/7.3/**45.6** | 38.3/41.5/10.4/**20.1** | 36.1/26.1/13.3/**23.1** | 35.3/9.8/6.0/**30.0** |
| RAG-Naive | 46.7/58.9/24.9/14.4 | 30.5/62.0/28.8/8.3 | 10.6/27.8/30.0/5.3 | 16.3/18.5/19.6/10.7 |
| RAG-Policy | 28.1/17.2/7.3/21.6 | 32.5/31.0/22.5/17.4 | 6.1/16.7/11.7/4.5 | 18.5/16.3/14.1/13.3 |
| A-MEM | 50.0/57.8/22.0/16.4 | 39.6/66.1/29.7/9.4 | 10.0/28.9/30.6/4.9 | 17.4/18.5/20.1/11.3 |
| Mem0 | 34.3/67.2/28.2/8.1 | 34.4/63.7/21.2/9.8 | 2.8/31.1/17.8/1.6 | 38.6/21.7/9.2/27.4 |
| ReMem-I | 36.7/55.7/29.4/11.5 | 20.8/54.4/24.8/7.1 | 3.3/28.3/29.4/1.7 | 8.7/22.3/19.0/5.5 |
| ReMem-S | 35.2/57.8/29.9/10.4 | 20.1/53.9/25.6/6.9 | 3.3/27.2/31.7/1.7 | 7.1/25.5/17.4/4.3 |

**Gemini-2.5-Flash-Lite**

| Method | Med | Office | Education | Household |
|---|---|---|---|---|
| Long-Context | 84.8/27.1/26.0/**45.7** | 88.3/69.0/64.9/9.6 | 93.9/32.8/64.4/**22.4** | 65.8/29.3/36.4/**29.5** |
| RAG-Naive | 75.2/59.9/64.4/10.7 | 72.8/67.3/61.3/9.1 | 39.4/33.3/65.0/9.2 | 46.2/37.0/60.3/11.6 |
| RAG-Policy | 37.6/18.8/16.9/25.4 | 69.5/44.4/55.4/**17.2** | 21.1/15.0/40.6/10.7 | 34.2/30.4/53.3/11.1 |
| A-MEM | 74.3/48.4/63.8/13.8 | 70.8/66.7/61.7/9.0 | 39.4/38.3/69.4/7.4 | 47.8/34.8/59.2/12.7 |
| Mem0 | 41.4/48.4/50.9/10.5 | 43.5/62.0/38.3/10.2 | 31.1/31.7/45.6/11.6 | 19.0/21.8/27.2/10.8 |
| ReMem-I | 57.8/51.8/63.2/10.3 | 71.4/62.0/57.2/11.6 | 25.2/29.8/57.8/7.5 | 34.6/25.4/46.8/13.7 |
| ReMem-S | 56.3/53.9/63.7/9.4 | 70.7/61.5/58.0/11.4 | 22.7/24.8/55.3/7.6 | 33.0/28.6/45.2/12.9 |

**(내가 계산한) 4개 도메인 단순 평균 MGS.** 논문에는 없는 값이고 Table 3에서 직접 산출했다.

| Backbone | LC | RAG-N | RAG-P | A-Mem | Mem0 | ReMem-I | ReMem-S |
|---|---|---|---|---|---|---|---|
| GPT-5.4 | 64.8 | 37.0 | 33.6 | 37.1 | 24.1 | 27.4 | 26.2 |
| Deepseek-V4-Pro | 69.5 | 40.9 | 34.1 | 38.4 | 21.8 | 32.8 | 23.5 |
| Llama-4-Maverick | 47.1 | 23.4 | 24.3 | 22.6 | 15.2 | 19.1 | 16.5 |
| GPT-5-mini | 55.9 | 32.1 | 31.3 | 29.3 | 24.4 | 24.3 | 23.4 |
| GPT-4o-mini | 29.7 | 9.7 | 14.2 | 10.5 | 11.7 | 6.5 | 5.8 |
| Gemini-2.5-FL | 26.8 | 10.1 | 16.1 | 10.7 | 10.8 | 10.8 | 10.3 |

- 평균 U/A/F(내 계산), GPT-5.4 기준: LC 85.0/18.5/6.5. RAG-Policy 43.6/13.7/10.1로 A는 가장 낮지만 U가 절반 수준이다. Mem0 32.8/15.9/11.1.

### 저자가 정리한 주요 관찰(§4.2)

1. **Long-Context**는 Deepseek-V4-Pro, GPT-5-mini, GPT-4o-mini에서 4개 도메인 모두 MGS 1위다. GPT-5.4, Llama-4-Maverick, Gemini-2.5-FL에서는 Office를 뺀 나머지 도메인에서 1위다. 그래도 일부 domain/backbone에서는 A나 F가 20%를 넘는다. 컨텍스트 창을 키우는 것만으로 거버넌스가 해결되지 않는다는 뜻이다.
2. **RAG-Policy**는 RAG-Naive보다 비인가 공개를 크게 줄이지만 증거를 같이 걸러 내거나 보수적인 응답을 유도해 utility가 떨어진다. Office 도메인에서는 GPT-5.4, Llama-4-Maverick, Gemini-2.5-FL 기준 MGS 1위다(57.0 / 37.1 / 17.2).
3. **전용 메모리 시스템(A-Mem, Mem0, ReMem)**이 단순 baseline보다 MGS가 일관되게 높지는 않다. 메모리를 잘 조직하고 episodic 추론을 해도 "검색한 사실이 *현재 요청자에게* 허가된 것인가, 삭제 후에도 유효한가"를 따로 평가하지 않으면 거버넌스가 생기지 않는다.
4. **Backbone 영향**: GPT-5.4와 Deepseek-V4-Pro가 최고 점수를 크게 끌어올린다. 단일 도메인 최고 MGS는 GPT-5.4 Medical LC의 80.1이다. Gemini-2.5-FL은 U가 높아도 F와 A가 매우 높다(예: Office LC A 69.0, F 64.9, MGS 9.6). 이 대비가 곱셈형 MGS를 쓰는 근거가 된다.

### Table 4: 효율(GPT-4o-mini; Sec/ckpt, Tok/ckpt, ingestion 포함)

| Method | Medical | Office | Education | Household |
|---|---|---|---|---|
| Long-Context | 4.22s / 4.04k | 4.89s / 7.61k | 7.79s / 7.20k | 6.44s / 6.21k |
| RAG-Naive | 11.76 / 1.55k | 13.15 / 1.93k | 18.52 / 1.96k | 16.44 / 1.96k |
| RAG-Policy | 11.10 / 1.15k | 13.28 / 1.81k | 17.72 / 1.57k | 14.29 / 1.80k |
| A-MEM | 41.76 / 1.37k | 43.39 / 1.75k | 67.87 / 1.74k | 46.99 / 1.75k |
| Mem0 | 85.90 / 1.27k | 60.15 / 1.43k | 158.55 / 1.52k | 29.44 / 2.91k |
| ReMem-I | 122.95 / 1.06k | 165.28 / 1.34k | 267.43 / 1.46k | 260.92 / 1.32k |
| ReMem-S | 113.91 / 1.05k | 151.52 / 1.24k | 251.45 / 1.38k | 246.56 / 1.18k |

- Long-Context는 토큰이 가장 많지만 wall-clock은 가장 빠르다. ReMem은 토큰이 약 1k로 가장 적지만 반복 그래프 검색 때문에 체크포인트당 최대 약 260초가 걸린다. 저자는 "governance와 latency를 함께 최적화해야 한다"고 말한다.
- 내 관찰: "고비용"이라는 Long-Context도 GPT-4o-mini 기준 RAG 대비 토큰은 약 2.6–4배, 시간은 오히려 2–3배 빠르다. 에피소드 길이가 평균 223 turn × 23.5 tok(약 5k 토큰)로 짧아서 생기는 효과로 보인다. 실제 조직 규모(수백만 토큰)에서는 결론이 뒤집힐 수 있다.

### 진단(§4.3; 그림이라 수치 미확인)

- Top-k ∈ {5, 10, 20, 30, 40}(Medical, GPT-4o-mini): k가 커지면 utility가 대체로 오른다. Policy RAG는 모든 k에서 access와 forgetting 안전성이 Naive보다 높다. 정책 필터는 retrieval 깊이로 대체할 수 없다는 결론이다.
- Over-refusal: Policy RAG가 Long-Context보다 과잉 거부율이 높다(안전성 때문에 "마비"됨).
- 공격 유형: access 실패는 노골적인 비인가 질의보다 **soft overreach**(indirect inference, cross-patient confusion, unassigned clinician 요청)에서 많이 나온다. forgetting 실패는 **yes/no 간접 확인**과 **update-delete 충돌**에서 쉽게 유발된다.
- 정성 사례(Table 5/10, Medical):
  - Utility: 약사가 "현재 투약 카드"를 묻는다. Policy RAG는 권한 있는 요청자인데도 refuse했다. Naive RAG와 A-Mem은 melatonin을 누락하고 answer_redacted로 답했다.
  - Access(cross_patient): A-Mem, Mem0, ReMem-I/S는 모두 `answer_redacted` action을 냈지만 본문에서 STI/dermatology 차트 종류를 확인해 줬다. **action은 제한적인데 content-level에서 누설**한 사례다.
  - Forgetting(confirm_yes_no): Mem0은 "Yes, the deleted old instruction was…"라고 직접 확인했다. Long-Context, Naive RAG, A-Mem은 refuse(mismatch)였고, Policy RAG와 ReMem-I/S가 no_memory로 정답이었다.

### Judge 신뢰도(App. D Table 9)

- 579개 judge-labeled pair(한 run) 중 약 50%를 층화 샘플링하고, 2명 이상이 주석, 불일치는 adjudication.
- Judge vs Human: U 53.33 vs 53.33, A 59.38 vs 58.33, F 23.86 vs 23.86, MGS 16.50 vs 16.92. 최대 |Δ| 1.04pp.
- Field-level: action N=289 일치 100%, κ 1.000. utility N=105 99.0%, κ 0.976. access leakage N=96 99.0%, κ 0.978. deletion leakage N=88 97.7%, κ 0.937.

## 저자가 밝힌 한계 + 내가 본 약점

**저자가 밝힌 한계(별도 limitation 섹션은 없고, 본문 caveat에서 추림)**

- Forgetting은 **인터페이스 수준 기준**이다. DB, vector index, cache, summary, 모델 파라미터에서 물리적으로 지워졌는지는 인증하지 않는다(§1, §3.2).
- 메인 결과 표는 "completed runs"의 부분집합만 보고한다(App. B).
- LLM judge 의존. 사람 검증으로 보완했다(App. D).
- Long-Context의 높은 MGS는 토큰 비용과 맞바꾼 것이고, governance와 latency를 함께 최적화하는 것은 미래 과제로 남겼다(§4.2, §5).

**내가 본 약점**

- **실제 거버넌스 메커니즘을 가진 baseline이 없다.** 정책이 자연어 system prompt로만 주입되고, RAG-Policy도 "lightweight policy-aware retrieval and prompting"에 그친다(App. B). 결정적 ACL(LLM 전에 레코드를 물리적으로 제외), record-level tombstone, 삭제 시 인덱스·요약까지 연쇄 삭제하는 baseline이 없다. 그래서 "현재 메모리 시스템은 거버넌스가 안 된다"는 결론은 맞지만, "거버넌스를 붙이면 얼마나 좋아지나"는 측정하지 않았다.
- **Mem0은 DELETE 연산이 있는데도 F가 높다.** 삭제 요청이 자연어 turn으로만 들어오고 Mem0의 extract 단계가 이를 delete로 매핑했는지는 분석하지 않았다. 원인(추출 실패인지, 다른 엔트리에 잔존한 것인지)이 분리되지 않는다.
- 에피소드가 짧다(평균 약 5k 토큰). Long-Context가 이기는 환경이라 실제 조직 규모에 일반화하기 어렵다.
- LLM으로 생성한 합성 에피소드다. 실제 기관 로그는 아니다.
- **단일 "shared assistant"** 설정이다. 여러 에이전트가 공유 메모리에 동시에 쓰는 multi-agent 상황(쓰기 경합, consistency)은 다루지 않는다. "multi-principal"은 사람 요청자가 여럿이라는 뜻이고, 에이전트가 여럿이라는 뜻은 아니다.
- 사람 검증은 한 run의 579 pair(Medical 도메인 크기와 같음)만 대상으로 했다. 도메인과 backbone이 바뀌어도 judge 신뢰도가 유지되는지는 확인되지 않았다.
- `refuse`를 forgetting 실패(mismatch)로 세는 것은 엄격한 설계다. 실제 운영에서는 "삭제됨"과 "권한 없음"을 구분해서 알려 주는 것 자체가 정보 누설(삭제 사실의 존재)일 수도 있다. 논문은 이 trade-off를 논의하지 않는다.

## 팀/조직 메모리 설계에 주는 시사점

1. **권한 판정을 retrieval 뒤 LLM에 맡기지 마라.** 프롬프트로 정책을 주는 방식(LC, RAG-Naive)도, 메모리 조직을 잘하는 방식(A-Mem, ReMem)도 A가 10–60%다. requester × scope × relation으로 레코드를 **검색 전에** 필터링하는 결정적 계층이 필요하다. RAG-Policy가 A를 낮춘 것이 그 방향이 맞다는 신호다. 다만 utility 손실을 막으려면 필터 정밀도(granularity)가 관건이다.
2. **정규화된 응답 action 4종을 설계에 넣는다.** `answer / answer_redacted / refuse / no_memory`. 특히 redaction은 action 라벨만 붙여서는 안 된다. 본문 content-level에서 leak-target 검사를 해야 한다(answer_redacted인데 차트 종류를 확인해 준 사례).
3. **삭제를 1급 연산으로 만든다.** 원 레코드뿐 아니라 파생물(요약, 링크 노트, 그래프 노드, 임베딩)까지 tombstone이 전파되게 한다. yes/no 확인 공격과 update-delete 충돌을 회귀 테스트로 고정한다. 삭제 사실을 알리는 방식도 정책으로 정한다.
4. **권한은 role만이 아니라 relation, scope, 현재 상태의 함수다.** 위임(delegation)과 동의(consent)는 유효 기간이 있는 레코드로 저장하고 매 질의마다 재평가한다. 정적 role 테이블로는 soft overreach를 막지 못한다.
5. **평가는 곱셈형 지표로 한다.** 사내 메모리 시스템 KPI를 recall 하나로 두지 말고, U·(1−A)·(1−F)와 over-refusal, Tok/ckpt, Sec/ckpt를 함께 본다. GateMem 데이터셋과 하네스는 공개되어 있어 사내 후보 시스템을 비교하는 출발점으로 쓸 수 있다.
6. **Backbone 선택도 거버넌스 변수다.** 같은 메모리 구조라도 Gemini-2.5-FL이나 GPT-4o-mini 계열은 누설이 크게 늘었다. 결정적 필터 없이 소형 모델을 쓰면 위험하다.

## 다른 개념과의 연결

- **Scope hierarchy**: S_e = (도메인, principal, role/relation, 접근 규칙)는 팀 메모리의 scope 모델을 그대로 옮겨 쓸 수 있는 템플릿이다. 다만 GateMem의 scope는 "정보 주체/요청자" 축이다. user/team/org 같은 저장 계층 scope는 없다.
- **Consistency**: current-state 의존 utility(최신 값 추적)와 update-delete conflict 공격이 consistency 문제와 맞닿아 있다. 2603.10062가 말하는 read-time conflict resolution이 실패한 형태가 곧 "삭제 후 이전 버전에서 재구성"이다.
- **Access control**: 이 논문의 핵심. 2603.10062 §5의 "memory access protocol(permission/scope/granularity)"이 없을 때 실제로 무엇이 깨지는지를 정량화한다. Survey(2602.06052) §4.2.1의 Hybrid 아키텍처(예: Collaborative Memory의 access graph 기반 read policy)를 평가할 후보로 이어진다. 단, GateMem baseline에는 Collaborative Memory가 없다.
- **Forgetting**: Survey §4.1.5의 forgetting은 효용 기반(decay, importance)이다. GateMem의 active forgetting은 **요청 기반(삭제권)**이다. 둘을 구분해야 한다. 효용 기반 forgetting은 삭제 요청을 만족시키지 못한다.
- **Consolidation**: Mem0의 extract/consolidate, A-Mem의 link evolution, ReMem의 gist 같은 consolidation 산물이 삭제·권한 메타데이터를 상속하지 않으면 누설 경로가 된다는 점이 정성 사례에서 시사된다(내 해석).
- **Skills as procedural memory**: 다루지 않음. 공유 skill에도 같은 거버넌스 문제(누가 쓰고 누가 쓸 수 있나)가 있을 것이고, Survey §3.2.5가 community skill의 취약점을 언급한다.

## 확인 필요

- RAG-Policy의 "metadata-filtered retrieval"이 실제로 비인가 레코드를 하드 필터링하는지, 아니면 프롬프트에서 강조만 하는지. App. B 서술과 Table 6 서술이 미묘하게 다르다. 공개 코드(github.com/rzhub/GateMem)에서 확인해야 한다.
- Fig.4 attack-type별 실패율 수치, Fig.7 attack 구성비, Fig.8 delete-to-attack gap 평균과 P90(이미지라 미확인).
- Fig.3(a) top-k별 U, 100−A, 100−F 수치와 Fig.3(b) over-refusal 수치.
- §3.3의 A·F 식에 있는 "∨ action mismatch" 항과 App. D의 "main results do not apply post-hoc action gate"가 실제 계산에서 어떻게 맞물리는지(코드 확인).
- Human validation 대상 run이 어떤 backbone, 도메인, 방법인지. MGS 16.50으로 보아 GPT-4o-mini Medical 계열로 추정하지만 명시되어 있지 않다.
- Mem0 삭제 실패의 원인. extract 단계에서 deletion turn을 DELETE로 매핑했는지, 로그로 분석이 가능한지.
- 리더보드(rzhub.github.io/GateMem)에 논문 이후 추가된 방법이 있는지, 특히 결정적 ACL이나 tombstone 기반 방법.
