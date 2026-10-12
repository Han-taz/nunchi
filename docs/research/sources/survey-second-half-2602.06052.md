---
title: "A Survey of Agent Memory in the Second Half: Towards Self-Evolving and Long-Horizon Agents"
arxiv_id: "2602.06052"
version: "v4 (04 Aug 2026), cs.CL; 'Reviewed on OpenReview' (forum XycbogUAeJ)"
authors: "Wei-Chieh Huang, Weizhi Zhang, Yueqing Liang, Yuanchen Bei, Yankai Chen, … (약 60명) … Julian McAuley, James Zou, Jiawei Han, Philip S. Yu, Kai Shu 외. Co-first, core contributor, organizer, supervisor 표기(†, *, ‡, ¶)가 있으나 추출본에서 이름별 매핑은 소실됨"
affiliation: "UIC, IIT, ASU, Emory, Northwestern, NTU, UCF, Rutgers, Cambridge, Harvard, UTokyo, UCSD, UCSC, TAMU, UCSB, MBZUAI, McGill, UCLA, Stanford, Salesforce, Google, Meta, Roblox, Cisco, Capital One 등"
date: 2026-02 (v1) / 2026-08 (v4)
url: https://arxiv.org/abs/2602.06052
html: https://arxiv.org/html/2602.06052
repo: "AgentMemoryWorld/Awesome-Agent-Memory (GitHub)"
type: survey
read_status: partial
read_notes: "HTML v4 본문(참고문헌 제외 약 23.5만 자)을 받음. 전문 정독: §1 Intro, §2, §3 Taxonomy 전체, §4 Operation 전체(특히 §4.2 multi-agent), §5 Learning policies 전체, §7 Evaluation 전체(Table 3–5 포함), §9 Future directions 전체, §10. Skim: §6(단, §6.2.2·§6.2.3은 정독), §8 Applications(Table 6과 단락 첫머리). 일부 긴 문단(§3.1.1 Structural store 말미, §3.1.2 Weights/KV cache 말미)은 추출 도구에서 잘려 끝부분 미확인. Figure 1–9는 이미지라 내용 미확인(Fig.4 taxonomy forest 포함)."
caveat: "작업 지시에는 저자를 'Zhao, Wang, Zou'로 적었으나 실제 1저자는 Wei-Chieh Huang 외 다수. 같은 arXiv id 제목 'A Survey of Agent Memory in the Second Half'와 일치하므로 이 논문으로 진행함."
---

# A Survey of Agent Memory in the Second Half (2602.06052)

## 한 줄 요약

218편(2023 Q1–2025 Q4)을 선별해 에이전트 메모리를 **3개 직교 축**으로 정리한 대형 서베이다. 세 축은 substrate(internal/external), cognitive mechanism(sensory/working/episodic/semantic/procedural), subject(user-/agent-centric)이다. single-agent의 5개 연산과 **multi-agent의 architecture·routing·isolation/conflict**를 분석하고, prompting→SFT→RL로 이어지는 학습형 메모리 정책, 평가 지표와 벤치마크, 6개 미해결 과제를 다룬다. 이 서베이가 일관되게 내세우는 관점은 "메모리 = self-evolution의 substrate"이고, skill을 procedural memory를 외부화한 것으로 본다.

## 문제 정의

- "Second half" 관점(§1): AI가 모델·벤치마크 점수 경쟁에서 문제 정의와 실제 환경 평가로 옮겨 갔다. agentic coding, deep research, computer use 같은 장기·동적·사용자 의존 작업에서는 컨텍스트가 고정 창을 넘어 폭발한다. 그래서 메모리가 utility gap을 메우는 핵심 수단이 된다.
- 기존 서베이는 task나 관리 전략 중심(Zhang et al. 2025p, Du et al. 2025)이거나, 신경과학 유비(Wu 2025f, Liang 2025)거나, forms/functions/dynamics(Hu et al. 2025d)를 다뤘다. 저자 평가로는 이들이 substrate와 "메모리가 누구를 위한 것인가(subject)"를 체계적으로 다루지 않았다(§1).
- 기여 세 가지(§1): (1) substrate × mechanism × subject 3축 taxonomy, (2) single/multi-agent topology에서 메모리가 어떻게 구현·운영·평가되는지에 대한 시스템 설계 분석, (3) 메모리를 self-evolution의 중심 메커니즘으로 위치시키고 6개 open challenge 제시.

## 핵심 내용

### §3 Taxonomy(3축)

**(1) Memory Substrate(§3.1): 어떤 형태로 저장되는가**

- External(§3.1.1): 모델 파라미터나 상태 밖에 두고 명시적 read/write를 한다.
  - Vector Index: ANN(HNSW/IVF/PQ) top-k. 현재 가장 지배적인 방식이다.
  - Text Record: 사람이 읽을 수 있는 core summary + semantic list(insert/update/delete) + episodic ledger(타임스탬프).
  - Structural Store: relational table(SQL), graph(KG), tree(RAPTOR류).
  - Hierarchical Store: core/episodic/semantic/procedural/resource 모듈과 **knowledge store(credential, API key 등 민감정보에 strict access control 적용)**를 meta-memory manager가 라우팅한다(MIRIX류). 단점은 multi-store 사이의 data consistency와 동기화가 필요하다는 것이다.
- Internal(§3.1.2): Weights(continual learning, model editing(ROME/MEMIT), distillation), Latent-state, KV cache(H2O, SnapKV, layer별 budget 등).
- Table 1 trade-off(8개 차원): internal은 latency가 낮고, 업데이트 유연성이 낮고, catastrophic forgetting 위험이 높고, KV/latent는 세션을 넘어 지속되지 않는다. external은 insert/update/delete가 자유롭고, 영속적이며, 확장성이 높지만 precision이 embedding과 ranking에 좌우된다. 대표 예: internal은 MemoryLLM, WISE, SELF-PARAM, Titans, ChunkKV, EpiCache. external은 Mem0, Zep, A-Mem, HippoRAG2, MIRIX, MemTree. 결론은 hybrid다(§3.1.3).

**(2) Cognitive Mechanism(§3.2, Table 2): 어떤 기능을 하는가.** 저자는 이 다섯 가지를 "minimal and architecturally complete"하다고 주장한다.

- Sensory(무엇을 지각하나): 대부분 암묵적이다. HMT, LightMem, M2PA가 명시적으로 다룬다.
- Working(지금 무엇을 다루나): active context다. (a) pre-write 압축·folding·참조 치환과 (b) 고정 예산에서의 online 유지·eviction으로 나뉜다. curation policy를 **RL로 학습**하는 추세다(MEM1, MemAgent, MemAct, MemSearcher). 이 서베이는 working memory를 self-evolution loop의 "gateway"로 본다.
- Episodic(무슨 일이 있었나): episode recording과 retrieval/reflection 두 갈래. 열린 문제는 episode 경계, recall 영향 조절, 규모가 커질 때의 retention이다.
- Semantic(무엇을 아나): episodic을 탈맥락화(semanticization)해서 만든다. hierarchical schema, memory graph(Zep), neural module. preference drift 탐지와 continual editing(WISE)도 여기에 속한다.
- **Procedural(어떻게 하나)**: 명시적 템플릿에서 parametric policy로 가는 흐름이 있다. 동시에 **skill로 외부화하는 반대 흐름**도 있다. Voyager의 skill library에서 시작해 Anthropic Agent Skills 같은 "instructions + code + resources 번들"로 이어지고, 이식·버전 관리가 가능한 인프라가 됐다. self-evolving 측면에서는 diagnose-and-revise(Belikova 2026), skill library 건강 관리(merge/repair/retire, Song 2026), memory skill 학습(MemSkill)이 있다. **caveat 두 가지**: 자가 생성 skill은 사람이 큐레이션한 skill보다 성능이 낮다(Li and others 2026). 커뮤니티 skill 중 상당 비율에 취약점이 있다(Liu et al. 2026).

**(3) Memory Subject(§3.3): 누구를 위한 것인가**

- User-centric(§3.3.1): 장기 대화 관리, persistent user simulation, long-term personalization, **privacy-preserving memory**. 블랙박스에서 추출 공격이 가능하고, multi-agent에서는 이질적인 role과 동적 협업 때문에 일관된 privacy protocol을 적용하기 어렵다. 필요한 것으로는 selective retention, secure storage, **user-controlled deletion**, **transparent auditing**, 프로필 *추론*에 대한 사용자 통제, DP, 암호화 vector DB, retention/access-control policy를 든다.
- Agent-centric(§3.3.2): long-horizon task execution(MEM1, MemAgent), domain-specific long-tail 해법 반복, cross-task skill 일반화(Agent KB), continual strategy/skill evolution(WebArena, GUI, embodied).
- 두 subject는 상호배타가 아니다. 예: 코딩 어시스턴트는 사용자 스타일과 여러 사용자에서 모은 디버깅 전략을 함께 가진다. 그런데 현재 벤치마크는 둘을 동시에 요구하는 경우가 드물다.

### §4 Memory Operation

**§4.1 Single-agent 5개 연산**

1. Storage & Index: write 시점에 embedding + metadata(timestamp, task id, entity, tool)를 붙인다.
2. Loading & Retrieval: metadata(recency, task scope, memory type)로 먼저 거르고 → 유사도 검색 → budget 기반 선별을 한다. 너무 많이 넣으면 노이즈, 너무 적으면 누락.
3. Update & Refresh: update는 내용을 수정(재작성, 병합, 중요도 조정)하는 것이다. refresh는 내용은 그대로 두고 prominence(재랭킹, 요약 재생성, 강화)만 조정한다. reflection이 둘을 촉발한다.
4. Compression & Summarization: 주기적 또는 작업 종료 후 consolidation, 계층형(tree), Dynamic Cheatsheet. abstraction fidelity와 recall 사이에 trade-off가 있다.
5. Forgetting & Retention: recency decay, importance threshold, 학습형 제거 정책, 적응형 retention.

**§4.2 Multi-agent(정독 대상)**

- 서두: multi-agent에서는 기본 연산보다 **cross-agent read/write 규칙**이 더 중요하다. 이 규칙이 role별로 어떤 메모리에 접근하는지, role-specific 경험·skill·피드백이 어떻게 이전되는지를 결정한다. 이질적인 에이전트가 만든 메모리의 **provenance, reliability, compatibility**를 고려해서 중복 제거, 충돌 해소, consistency 유지를 추가로 해야 한다. 메커니즘은 selective sharing, validation, consolidation, revision이다.
- **§4.2.1 Memory Architecture(4유형)**. 저장 계층, 에이전트 간 read/write 권한 정의, controller 유무가 routing 효율과 **information leakage** 가능성을 결정한다.

  | 유형 | 정의 | 장점 | 단점 | 예 |
  |---|---|---|---|---|
  | Private-only | 에이전트별 독립 메모리, 권한은 자기 메모리 안에서만 | 강한 격리, 검증 쉬움 | 같은 메모리를 여러 곳에서 중복 생성 | RecAgent(사용자당 1 agent), TradingGPT, MetaAgents |
  | Shared-workspace | 모든 에이전트가 읽고 쓰는 공용 풀 | P2P 메시징 비용 감소 | 노이즈 증가, 동시 갱신 충돌 | MetaGPT(공용 풀 + role profile 필터), InteRecAgent(Candidate Bus), MAICC(공유 experience pool) |
  | **Hybrid** | private + shared 두 층, **write policy**가 어느 층에 쓸지 결정하고 호출마다 **권한 제한된 memory view** 생성 | 재사용과 민감정보 격리의 균형 | (명시 없음) | **Collaborative Memory**(write policy로 일반/사용자 특화 판별, read policy가 **access graph**로 view 구성), MirrorMind |
  | Orchestrated | 명시적 controller가 작업 분해, 할당, read/write 권한 결정 | 다단계 workflow, 강한 제약 환경에 적합 | 병목, 복잡도 | ChatDev(ChatChain), MIRIX(Meta Memory Manager), MGA, AgentFlow |

  - 저자는 orchestrated의 control layer가 저장 레이아웃과 **직교**한다고 본다. 즉 private, shared, hybrid 어느 것과도 결합할 수 있다.
- **§4.2.2 Memory Routing**: 작업이 들어오면 role별 memory view를 만들어 무엇을 검색해 각 컨텍스트에 어떻게 주입할지 정한다. 결정 위치에 따라 세 가지로 나눈다.
  - *Orchestrator-based*: 중앙이 전역 상태를 들고 subtask와 필요한 메모리를 배분한다. 예: LEGOMem(task memory는 orchestrator로, subtask memory는 선택된 agent로), GameGPT(단계별 산출물을 shared workspace에 기록), Westhäußer 2025(MCP로 memory source를 선택하고 Self-Validator가 증거 부족 시 재검색). 단점은 single point of load/failure.
  - *Agent-initiated*: 공유 풀에 publish하고 각 agent가 로컬에서 선택한다. 예: SRMT(cross-attention으로 shared memory 읽기), S3(forgetting, relevance, **source credibility**로 점수 매김), Talker-Reasoner(읽을 시점을 agent가 결정하고 갱신을 기다리기도 함). 필터 설계에 크게 의존한다.
  - *Memory-driven*: 검색 → 점수·재랭킹 → 선택 + 그래프 확장. 예: G-Memory(계층 그래프 → 핵심 subgraph → role별 view), CRMWeaver(guideline 단위 routing, 매칭이 없으면 새 guideline을 write-back), Spark.
- **§4.2.3 Memory Isolation and Conflicts**: 병렬 결론, 시간에 따라 바뀌는 권한, 서로 모순되는 write, 제거되지 않은 outdated 정보가 문제다. 예로 Talker-Reasoner에서 Reasoner가 갱신하기 전 stale belief state를 Talker가 읽어 성급한 오답을 낸 사례를 든다.
  - *Write Control for Isolation*: Memory-R1은 **memory manager만 mutate 권한**을 갖고, ADD/UPDATE/DELETE/NOOP 이산 연산을 쓰며, UPDATE 때 정보가 더 많은 버전을 유지한다. WebCoach는 **episode가 완료된 뒤에만** 장기 메모리에 쓰므로 부분 trajectory가 들어가지 않는다.
  - *Consistency with Feedback Loop*: stable **constraint memory**와 growing **feedback memory**를 둔다. EvoMem은 verifier 점수가 100일 때만 수용한다.

### §5 Memory Evolution & Optimization Policies(정독 대상)

- **§5.1 Prompt-driven**(파라미터 변경 없음, 해석 가능):
  - Static: (a) memory OS/조직(SCM, MemGPT, A-Mem, Zep 등), (b) persona/도메인 prior로 제어(RoleLLM, FinMem 등), (c) **multi-agent 정적 할당·조정**(MIRIX, LEGOMem, G-Memory, MADRA, GameGPT, ChatDev). 즉 현재 multi-agent 메모리 할당은 대부분 학습되지 않은 고정 규칙이다.
  - Dynamic: reflection으로 정책 수정(Reflexion, ReasoningBank, WebCoach), 표현 최적화(ACON, ACE, SeCom, Nemori, EvoMem), procedural 증류(BoT, Memp, ToolMem). 한계는 **explicit credit assignment가 없다**는 것이다.
- **§5.2 SFT**: §5.2.1 정책을 파라미터에 내재화(Memory3, MLP Memory), §5.2.2 **boundary control**(쓰기, 교정, 억제 경계 학습: WISE, SuperIntelliAgent, CRMWeaver, Character-LLM), §5.2.3 retrieval 정제. 학습 후 정책이 고정된다는 한계가 있다.
- **§5.3 RL**: 시간 범위를 넓혀 가며 정리한다. §5.3.1 step-level(Memory-R1 ADD/UPDATE/DELETE/NOOP, MemAct trim/summarize, MemAgent/RMM 고정 버퍼, Mem-α 다중 구성요소), §5.3.2 trajectory-level(메모리를 Markov state로 보고 folding을 정책으로 학습, MemSearcher), §5.3.3 **cross-episode & multi-agent**(MCTR, Retroformer, Memento, MemGen, ReMemR1, **MAICC, SRMT의 shared/decentralized memory policy**).

### §6 Scaling(부분 정독)

- §6.2.2: 환경이 복잡해지면 **외부화된 메모리가 schema-aware retrieval, versioning, targeted edit, access control**을 가능하게 한다. MCP(환경 접근)와 Agent Skills(절차 패키지)가 persistent state, 환경 접근, 재사용 skill을 일시적 추론 컨텍스트에서 분리해 **modularity, auditability, safety**를 높인다. 지속 상태는 privacy, permissions, **rollback** 같은 거버넌스 제약을 지켜야 하고, 새로운 문제로 **schema drift, concurrent updates**, path-dependent evaluation이 생긴다. 인터페이스가 바뀌면 skill도 개정해야 한다.
- §6.2.3 Multi-human-agent: 단순 컨텍스트 공유는 깨지므로 role-specific memory template + shared substrate(Intrinsic Memory Agents), 계층적·role-aware 대화, debate/consensus/majority 규칙, graph 기반 통신 topology가 필요하다.

### §7 Evaluation(정독 대상)

- Table 3 지표 3계열:
  - Accuracy 계열: Accuracy, F1, Recall@K, MAP, NDCG@K, SR/GC, Pass@K/RR, **Memory Integrity(MI)**, **False Memory Rate(FMR)**(HaluMem).
  - Similarity 계열: ROUGE, BLEU, Distinct-n, BERTScore, FactScore, Perplexity.
  - LLM-judge 계열: Response Correctness, Faithfulness/Groundedness, Preference Following.
- 권고: retrieval/selection과 generation을 분리할 수 있어야 메모리 메커니즘에 귀속시킬 수 있다. similarity 지표는 grounding 검사와 같이 써야 한다. 비용(capacity, efficiency)도 함께 보고한다.
- Table 4 user-centric 벤치마크 15종(MSC, DuLeMon, MemoryBank, PerLTQA, LoCoMo, DialSim, LOCCO, MemoryAgentBench, LongMemEval, HaluMem, PersonaMem, PrefEval, MemBench, MemoryBench, ConvoMem). 10개 능력 FE/MR/TR/UR/CS/FR/UP/AS/IC/AB로 커버리지를 표시했다.
  - MR과 UP는 가장 꾸준히 커버된다.
  - **CS(압축)와 FR(forgetting/retention)은 상대적으로 덜 평가된다.**
  - AB(abstain)도 일관되게 요구되지 않는다.
- Table 5 agent-centric 벤치마크 31종(HotpotQA…OdysseyBench). 메모리 특화 측정이 더 필요하다고 본다. dependency distance, memory correctness under interaction(drift/omission/contradiction), interruption 후 지속성, 효율.
- 주의: Table 4와 5 어디에도 **multi-principal access control이나 삭제 요청 준수를 평가하는 벤치마크가 없다**(FR은 효용 기반 forgetting). 이 서베이의 v4(2026-08)에 GateMem(2026-06)은 들어 있지 않다.

### §8 Applications(skim)

Table 6에 12개 도메인이 있다. education, science, gaming, robotics, healthcare, dialogue, **workflow automation**(AWM, ToolMem), **software engineering**(MetaGPT, ChatDev, SWE-bench), streaming/recsys, info search, finance, legal(provenance 필수).

### §9 Open challenges(정독 대상, 6개)

1. **Continual learning & self-evolving**(§9.1): intra-task(무엇을 유지·압축·폐기할지)와 cross-task(경험 consolidation과 일반화). 현재는 heuristic controller와 inference-time 재사용이 중심이다. 위험은 negative transfer, drift, semantic inconsistency. 방향은 semantic + episodic + procedural을 통합한 continual learning, 원칙 있는 post-training consolidation, 비정상(non-stationary) 환경에서의 행동 안정성 벤치마크.
2. **Multi-human-agent memory organization**(§9.2): 현재 협업은 "episodic and transient"해서 작업이 끝나면 경험이 남지 않고 매번 처음부터 다시 협업을 구성한다. 방향은 세 가지다.
   - **Collaborative(social) memory**: 협업자의 소통 선호, 전문성, 피드백 패턴, 과거 결과. trust를 보정하는 데 쓴다.
   - **Role-specific workflow/procedural memory**: 안정된 role의 분해 패턴과 실패 모드.
   - **Memory governance & coordination**: **ownership, access, responsibility**, 그리고 서로 다른 관점과 사람의 교정을 어떻게 처리할지. 오류 전파를 막는 데 필수라고 본다.
3. **Infrastructure & efficiency**(§9.3): 메모리 용량을 프롬프트 길이와 혼동하고 있다는 비판. 단계적 방향으로 organized text → compressed latent → internalized/parametric(MEM1, Mem-α) 순서를 제시하고, NeMo Gym 같은 환경 인프라를 언급한다.
4. **Lifelong personalization & trustworthy memory**(§9.4): staleness, concept drift, credit assignment, privacy leakage, **memory poisoning**, adversarial manipulation. 사용자가 **inspection, editing, revocation**을 직접 제어할 수 있어야 하고 비인가 접근과 악성 write를 막아야 한다. robustness, transparency, security를 adaptability와 같은 급의 목표로 둔다.
5. **Multimodal, embodied, world-model**(§9.5): memory를 예측형 world model로 보는 관점. 저장, 압축, 망각의 결과를 미리 시뮬레이션하는 proactive memory planning.
6. **Real-world benchmarking**(§9.6): LoCoMo는 stationary intent를 가정하고, PersonaMem은 update와 refresh를 평가하지 않는다. WebArena와 OSWorld는 reset 중심이다. InterruptBench는 목표 변경이 어렵다는 것을 보였다. Ma et al. 2026은 memoryless baseline도 task completion은 포화되지만 hidden user state 복구는 중간 수준이고 top-K retrieval에서 더 떨어진다고 보고했다. 방향은 **persistent state를 version, audit, rollback하고 provenance metadata를 붙이는 invariant**, MCP식 계층으로 **reproducible logging, permission enforcement, replay**, 토큰·저장·지연 대비 품질 측정.

## 실험/근거

- 서베이라서 자체 실험은 없다.
- 정량적 서술은 다음 정도다. 218편 선별(2023 Q1–2025 Q4, Google Scholar 키워드 + 주요 학회 수작업 검토, 초기 풀은 "several hundred"), 2025년 특히 Q4에 누적 출판량이 가장 가파르게 늘었다(Fig.3, 이미지라 수치 미확인). Table 4는 벤치마크별 #Sess/#Q/Max Tok을 정리했다(예: LongMemEval 50K sess, 500 Q, 1.5M tok. MemoryAgentBench 1.44M tok. ConvoMem 75,335 Q, 3M tok).
- 인용 수준의 경험적 주장: "self-generated skills still underperform human-curated ones"(Li and others 2026), "a substantial fraction of community-contributed skills found to contain vulnerabilities"(Liu et al. 2026). 구체 비율은 서베이 본문에 없다.

## 저자가 밝힌 한계 + 내가 본 약점

**저자가 밝힌 한계(별도 limitation 섹션은 없음. 본문과 §9에서 분야의 한계로 서술)**

- 현재 메모리 관리는 heuristic과 inference-time 재사용이 중심이고 consolidation 원칙이 없다(§9.1).
- multi-agent와 human-agent 협업은 일시적이고, 거버넌스(ownership/access/responsibility)가 미정이다(§9.2).
- 벤치마크는 정적이고 reset 중심이다. CS, FR, AB를 덜 평가한다(§7.2.1, §9.6).
- 프롬프트 기반 정책은 credit assignment가 없고, SFT 정책은 학습 후 고정된다(§5.1.2, §5.2.3).

**내가 본 약점**

- **Multi-agent 부분(§4.2)이 사례 나열 중심이다.** architecture, routing, isolation이 서로 직교한다고 말하지만(orchestrated layer만 명시) 3축을 조합한 설계 공간을 체계화하지 않는다. consistency도 Memory-R1, WebCoach, EvoMem 세 사례로만 다루고 visibility/ordering 같은 형식적 틀은 없다(2603.10062와 대조).
- **Access control과 거버넌스를 "privacy-preserving user memory"(§3.3.1)와 미래 과제(§9.2, §9.4)로만 다룬다.** 다중 principal 권한 모델(role × relation × scope)이나 삭제권 준수는 taxonomy 축에 들어 있지 않다. "subject" 축이 user/agent 이분법이라 **team/organization 수준 subject**가 빠졌다. 코딩 어시스턴트 예시에서 "여러 사용자에서 모은 전략"은 사실상 공유 scope인데 이름이 붙어 있지 않다.
- Forgetting을 효용·자원 관점(decay, importance)으로만 정의한다. 요청 기반 삭제와 파생물 전파는 다루지 않는다.
- 저자 약 60명이 섹션을 분담한 결과로 보이는데, 섹션 간 깊이 차이가 크다. 예를 들어 §5는 한 문장짜리 인용 나열이 많다.
- "다섯 cognitive mechanism이 minimal and architecturally complete하다"는 주장에 논증이 없다.
- 2025 Q4까지의 문헌이 기준이라 2026년의 multi-principal 벤치마크(GateMem, CI-Work 등)는 반영되지 않았다. v4에 2026 인용(skills 관련)이 일부 추가되긴 했다.

## 팀/조직 메모리 설계에 주는 시사점

1. **Hybrid + write policy + 권한 제한 memory view를 기본 구조로 한다**(§4.2.1). 쓰는 시점에 "일반적으로 유용한가 vs 특정 사용자·프로젝트에 한정되는가"를 판정해 층을 고르고, 읽는 시점에는 **access graph**로 호출별 view를 만든다(Collaborative Memory 패턴). 여기에 orchestrator를 직교로 얹는다.
2. **공유 메모리의 mutation 권한을 단일 관리자에게 모은다**(Memory-R1 패턴). 일반 에이전트는 "후보 fact"만 제안하고, memory manager가 ADD/UPDATE/DELETE/NOOP으로 반영한다. 미완료 trajectory는 쓰지 않는다(WebCoach 패턴). 이렇게 하면 동시 쓰기 충돌과 부분 상태 오염이 줄어든다.
3. **Routing 결정 위치를 의식적으로 고른다.** 규제가 강하거나 다단계인 workflow는 orchestrator-based(감사가 쉽지만 SPOF). 탐색형 협업은 agent-initiated + source credibility 점수(S3). 경험 재사용은 memory-driven(G-Memory식 role별 subgraph view).
4. **Skill을 버전 관리되는 공유 procedural memory로 운영한다**(§3.2.5, §6.2.2). skill 라이브러리를 정기적으로 정비(merge/repair/retire)하고, 실행 trace 기반으로 개정하고, **공유 전에 보안 검토**를 한다. 자가 생성 skill은 사람 큐레이션보다 약하므로 human-in-the-loop 승인 단계를 둔다.
5. **Collaborative(social) memory를 명시적 범주로 둔다**(§9.2). 동료와 사람에 대한 메모리(소통 선호, 전문성, 피드백 패턴)는 그 자체로 민감한 인사정보다. ownership, access, responsibility 정책을 먼저 정한 뒤에 도입한다.
6. **평가 harness에 memory-sensitive invariant를 넣는다**(§9.6, §7). version, audit, rollback, provenance metadata, MCP 계층의 permission enforcement와 replay 로그를 남기고, MI/FMR이나 drift/omission/contradiction을 측정한다. 여기에 GateMem식 U·(1−A)·(1−F)를 더하면 서베이가 비워 둔 거버넌스 축이 채워진다.

## 다른 개념과의 연결

- **Scope hierarchy**: subject 축(user/agent)과 §4.2.1 architecture(private/shared/hybrid)가 scope의 재료다. 다만 agent < user < team < org 같은 계층 scope는 정의하지 않는다. 팀 설계에서는 subject 축을 {agent, user, team/project, org}로 확장해야 한다(내 제안).
- **Consistency**: §3.1.1 hierarchical store의 multi-store 동기화, §4.2.3 write control과 feedback loop, §6.2.2 schema drift와 concurrent updates. 2603.10062의 update-time visibility와 read-time conflict resolution 틀에 대응시키면 write control은 update-time 쪽, feedback-loop consistency는 반복적 read-time 조정에 가깝다(내 매핑).
- **Access control**: §3.1.1 knowledge store의 strict access control, §3.3.1 multi-agent privacy protocol의 어려움, §4.2.1 hybrid의 permission-limited view, §6.2.2 외부화 메모리의 access control 가능성, §9.2 ownership/access/responsibility. 이 개념들이 흩어져 있고 평가 방법은 없다. GateMem이 그 평가 공백을 메운다.
- **Forgetting**: §4.1.5(효용 기반), §3.3.1(user-controlled deletion), §9.4(revocation). 벤치마크 차원 FR은 덜 평가된다고 저자도 인정한다(§7.2.1).
- **Consolidation**: episodic → semantic(semanticization) → procedural(skill) 증류를 self-evolution loop의 중심에 둔다(§1, §3.2). §4.2 서두에서는 multi-agent 경험을 공유 knowledge/skill repository로 aggregation하고 distillation하는 것도 언급한다.
- **Skills as procedural memory**: 이 서베이의 가장 명시적인 입장(§3.2.5, §6.2.2). skill은 portable, human-readable, versionable한 procedural memory이고 진화의 대상이다. caveat은 품질(자가 생성 < 사람 큐레이션)과 보안(커뮤니티 skill의 취약점)이다.

## 확인 필요

- Figure 4(taxonomy forest)와 Figure 9(future directions 다이어그램)의 세부 항목(이미지라 미확인).
- 저자 표기(†co-first, *core, ‡organizer, ¶supervisor)의 이름별 매핑. 지시문의 "Zhao, Wang, Zou"가 누구를 가리키는지(Wanjia Zhao, Yu Wang/Wenya Wang, James Zou 또는 Henry Peng Zou 등 후보가 여럿).
- "Reviewed on OpenReview (forum XycbogUAeJ)"가 어느 venue인지(TMLR로 추정, 미확인).
- Liu et al. 2026(community skill 취약점 비율)과 Li and others 2026(self-generated vs human-curated skill 성능 차이) 원 논문의 구체 수치.
- Collaborative Memory(Rezazadeh et al. 2025a, arXiv 2505.18279)의 access graph와 read/write policy 구체 구조. 팀 메모리 1순위 참고 아키텍처라서 원문을 따로 읽을 필요가 있다.
- Ma et al. 2026(hidden user state probing)의 구체 수치와 Wu et al. 2026(role·permission 구조를 가진 human-agent 벤치마크)의 정체.
- §3.1.1 Structural store 말미, §3.1.2 Weights/KV cache 말미의 잘린 문단 내용.
