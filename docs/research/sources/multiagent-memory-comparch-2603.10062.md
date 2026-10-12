---
title: "Multi-Agent Memory from a Computer Architecture Perspective: Visions and Challenges Ahead"
arxiv_id: "2603.10062"
version: "v2 (30 Mar 2026)"
authors: "Zhongming Yu, Naicheng Yu, Hejia Zhang, Wentao Ni, Mingrui Yin, Jiaying Yang, Yujie Zhao, Jishen Zhao"
affiliation: "UC San Diego (7명), Georgia Institute of Technology (Jiaying Yang)"
venue: "Architecture 2.0 Workshop on AI for Computing Systems Design, 2026-03-23, Pittsburgh"
date: 2026-03
url: https://arxiv.org/abs/2603.10062
html: https://arxiv.org/html/2603.10062
type: position
read_status: full
read_notes: "본문 §1–§7 전체 + 참고문헌 읽음. 분량은 아주 짧음(본문 약 2페이지). Figure 1–3은 이미지라 텍스트로 확인하지 못함. 특히 Figure 3(SC/TSO/RC → multi-agent consistency 비교 차트)의 내용은 미확인."
---

# Multi-Agent Memory from a Computer Architecture Perspective (2603.10062)

## 한 줄 요약

멀티 에이전트 메모리를 컴퓨터 아키텍처 문제로 보자는 2페이지짜리 포지션 페이퍼. shared/distributed 두 패러다임, I/O–cache–memory 3계층 계층 구조, 아직 없는 두 프로토콜(에이전트 간 cache sharing, memory access control)을 제시하고, 가장 시급한 미해결 과제로 **multi-agent memory consistency**(아직 정의조차 없음)를 꼽는다.

## 문제 정의

- 에이전트는 single-agent 도구에서 multi-agent 시스템(tool-using agent, planner–orchestrator stack, debate team, 전문 sub-agent)으로 옮겨 가고 있고, 컨텍스트도 더 길고 멀티모달·구조화된 trace·커스텀 환경으로 복잡해지고 있다(§1, §2).
- 저자들은 이것이 컴퓨터 시스템의 "memory wall"과 같은 병목이라고 본다. 다른 점은 다루는 대상이 raw byte가 아니라 **추론에 쓰이는 semantic context**라는 것뿐이다(§1).
- §2의 근거: RULER(긴 히스토리 위 추론), MMMU·VideoMME(멀티모달), Spider·BIRD(구조화되고 실행 가능한 trace), SWE-bench·OSWorld(장기 상태 추적). 그래서 컨텍스트는 정적 프롬프트가 아니라 "bandwidth, caching, coherence 제약을 갖는 동적 메모리 시스템"이라는 주장이다.

## 핵심 내용

### §3 Shared vs. Distributed 메모리

- **Shared memory**: 모든 에이전트가 공용 풀(shared vector store, document DB 등)에 접근한다. 지식 재사용은 쉽지만 **coherence 지원이 필수**다. 조정이 없으면 서로 덮어쓰고(overwrite), stale 정보를 읽고, 공유 사실의 버전이 어긋난다.
- **Distributed memory**: 에이전트마다 로컬 메모리를 갖고 선택적으로 동기화한다. 격리와 확장성은 좋지만 명시적 sync가 필요하고, 관리를 소홀히 하면 상태 발산(state divergence)이 흔해진다.
- 실제 시스템은 대부분 그 중간이다. **로컬 working memory + 선택적으로 공유하는 artifact** 형태.

### §4 3계층 메모리 계층(아키텍처 유비)

| 계층 | 내용 | 예 |
|---|---|---|
| Agent I/O layer | 정보 입출력 인터페이스 | audio, text 문서, 이미지, 네트워크 호출 |
| Agent cache layer | 즉각 추론용. 빠르고 용량이 작음 | 압축된 컨텍스트, 최근 tool call, KV cache·embedding 같은 short-term latent |
| Agent memory layer | 검색과 영속을 위한 대용량·저속 계층 | 전체 대화 이력, vector DB, graph DB, document store |

- 원칙: "agent performance is an end-to-end data movement problem." 필요한 정보가 잘못된 계층에 있거나 로드되지 않으면 정확도와 효율이 함께 떨어진다. "caching is not optional."

### §5 멀티 에이전트용 프로토콜 확장

- 현재 프로토콜(MCP 등)은 **agent context I/O**에 해당한다. 필요하지만 충분하지 않다. 에이전트 간 대역폭은 여전히 message passing에 묶여 있다.
- **Missing piece 1: Agent cache sharing protocol.** KV cache 공유 연구(DroidSpeak, Cache-to-Cache, KVCOMM)는 있지만, 한 에이전트가 캐시한 결과를 다른 에이전트가 *변환해서 재사용*하는 원칙적 프로토콜은 없다. 멀티프로세서의 cache transfer에 대응한다.
- **Missing piece 2: Agent memory access protocol.** MemGPT, A-Mem, Mem0, MemoRAG 등은 공유 상태를 일부 지원하지만 표준 접근 프로토콜(**permissions, scope, granularity**)이 정해져 있지 않다. 저자가 던진 질문은 다음과 같다.
  - 한 에이전트가 다른 에이전트의 long-term memory를 읽을 수 있는가?
  - read-only인가 read-write인가?
  - 접근 단위는 document / chunk / key-value record / trace segment 중 무엇인가?

### §6 Multi-Agent Consistency(핵심 주장)

- HW consistency model(SC, TSO, Release Consistency)은 한 프로세서의 메모리 연산이 다른 프로세서에 *언제, 어떤 순서로* 보이는지를 규정한다. 무슨 값을 읽느냐가 아니라 순서와 가시성의 문제다. 에이전트 메모리에는 이에 상응하는 formalism이 없다.
- Single agent의 경우: working/episodic/semantic store 사이의 업데이트가 **causal order**로 전파되어야 한다. Generative Agents는 temporally coherent retrieval이 필요하다고 언급만 했고 순서 보장을 형식화하지는 않았다.
- Multi-agent consistency는 두 요구사항으로 분해된다.
  1. **Update-time visibility & ordering**: 한 에이전트의 write가 언제 다른 에이전트에게 보이는지, 서로 다른 에이전트의 concurrent write가 어떤 순서로 관측될 수 있는지.
  2. **Read-time conflict resolution**: 동시 수정으로 버전이 갈라진 record에서 충돌하거나 stale한 artifact를 읽는 쪽이 어떻게 조정할지.
- HW보다 어려운 이유 세 가지: (a) 메모리 artifact가 의미적으로 이질적이다(evidence, tool trace, plan). (b) 에이전트 간 의존성이 선언되지 않고 암묵적이다. (c) 충돌이 semantic이고 환경 상태와 결합되어 있다.
- 결론: "multi-agent memory consistency has not been formally defined." 위반을 탐지하거나 분류하는 프레임워크도 없다.

### §7 결론

현재 에이전트 메모리는 인간 기억처럼 "informal, redundant, hard to control"하다. 저자가 필요하다고 보는 것은 세 가지다. 더 나은 hierarchy, cache sharing과 memory access에 대한 명시적 protocol, 그리고 공유 컨텍스트를 coherent하게 유지할 consistency model.

## 실험/근거

- **실험 없음.** 정량 결과나 프로토타입, 사례 측정이 없는 순수 포지션 페이퍼다.
- 근거는 기존 벤치마크(RULER, MMMU, VideoMME, Spider, BIRD, SWE-bench, OSWorld)를 컨텍스트 복잡도의 증거로 인용한 것과 HW 아키텍처 유비뿐이다.

## 저자가 밝힌 한계 + 내가 본 약점

**저자가 밝힌 한계(명시적 limitation 섹션은 없음. 본문에서 스스로 "미해결"이라고 한 것)**

- consistency 정의가 없고, 위반 탐지·분류 프레임워크도 없다(§6).
- cache sharing과 access protocol은 문제 제기 수준이고 설계는 제시하지 않았다(§5).

**내가 본 약점**

- 유비만 있고 구체 설계가 없다. 어떤 consistency level(예: 에이전트 artifact에 대한 causal 또는 release consistency)이 적절한지 제안하지 않는다. Figure 3 차트에 매핑이 있을 수 있으나 텍스트로는 확인하지 못했다.
- **멀티 principal(사람·팀·권한 주체) 관점이 없다.** access protocol을 "에이전트 대 에이전트"로만 다룬다. 회사 환경의 사용자/역할/프로젝트 scope, 삭제 요청, 감사(audit)는 다루지 않는다.
- forgetting/retention, consolidation, provenance를 다루지 않는다. "memory layer"는 저장소 나열 수준이다.
- cache layer에 KV cache(모델 내부 표현)와 compressed context(텍스트)를 같이 넣었다. 에이전트마다 모델이 다르면 KV 공유 자체가 성립하지 않을 수 있어, "transform and reuse"의 실현성이 불명확하다.
- Semantic conflict는 HW처럼 last-writer-wins로 해결되지 않는다. 그런데도 HW consistency 계층을 그대로 차용할 수 있는지는 논증하지 않는다.

## 팀/조직 메모리 설계에 주는 시사점

1. **계층을 명시하라.** 팀 메모리를 (i) 에이전트 세션 working set(cache), (ii) 팀/조직 공유 store(memory), (iii) 외부 I/O(MCP 툴·문서)로 나누고, 계층 간 이동(promote/evict)을 정책으로 정의한다. "어디에 무엇이 있어야 하는가"를 데이터 이동 문제로 다룬다.
2. **기본은 hybrid로 한다.** private working memory + 선택적으로 공유하는 artifact. 공유 승격(publish)을 명시적 연산으로 만들고, 공유 풀에는 coherence 메타데이터(버전, writer, timestamp, 의존 레코드)를 필수로 붙인다.
3. **Access protocol 스펙에 세 축을 넣는다.** permission(read-only/read-write), scope(누구의 메모리인가: agent/user/team/org), **granularity**(document / chunk / KV record / trace segment). 특히 granularity를 미리 정하지 않으면 redaction이나 부분 공유가 불가능하다.
4. **Consistency 계약을 문서화한다.** 최소한 두 가지를 정한다. (a) write visibility: 공유 store에 쓴 내용이 다른 에이전트에게 언제 보이는가(즉시 / 작업 종료 시 / 리뷰 후). (b) read-time conflict 규칙: 같은 fact의 버전이 여러 개일 때 최신 우선인지, 출처 신뢰도 우선인지, 사람 확인을 요청할지.
5. **에이전트 간 의존성을 선언형으로 만든다.** 저자가 HW보다 어렵다고 본 이유가 "의존성이 암묵적"이라는 점이다. 그러니 artifact에 "derived_from / supersedes" 링크를 남겨 stale 전파를 추적할 수 있게 한다.

## 다른 개념과의 연결

- **Scope hierarchy**: I/O–cache–memory는 *속도·용량* 계층이고 agent/user/team/org 같은 *소유·권한* 계층이 아니다. 팀 설계에는 두 축이 직교로 필요하다. 이 논문은 앞의 축만 다루고, 권한 계층은 §5 질문으로만 남긴다.
- **Consistency**: 이 논문의 핵심 기여. update-time visibility/ordering과 read-time conflict resolution으로 나눈 틀은 Survey(2602.06052) §4.2.3의 "write control vs. feedback-loop consistency"와 대응한다. write control은 쓰는 시점에 막는 것이고, read-time resolution은 읽는 시점에 조정하는 것이다.
- **Access control**: §5 Missing piece 2. GateMem(2606.18829)이 바로 이 공백, 즉 role/scope/relation 인식 접근통제를 벤치마크로 측정한다.
- **Forgetting**: 다루지 않음. Consistency 관점에서 보면 삭제도 하나의 write이므로, 삭제의 visibility와 전파를 같은 틀로 정의할 수 있다(내 해석).
- **Consolidation**: 다루지 않음. cache→memory로 내리는 것을 consolidation으로 볼 수 있지만 논문은 언급하지 않는다.
- **Skills as procedural memory**: 언급 없음. 다만 "cache sharing protocol"을 텍스트 수준으로 확장하면 한 에이전트의 검증된 절차(skill)를 다른 에이전트가 재사용하는 형태가 된다(내 해석).

## 확인 필요

- Figure 3("Consistency model comparison from traditional memory architecture to multi-agent memory")에 SC/TSO/RC를 에이전트 메모리의 어떤 모델에 매핑했는지(이미지라 미확인).
- Figure 2(memory hierarchy와 protocol framing 다이어그램)에서 MCP, cache sharing, access protocol이 어느 계층 사이에 그려져 있는지.
- 같은 그룹(UCSD Jishen Zhao 랩)이 이 비전을 구현한 후속 시스템이나 consistency 정의 논문을 냈는지. 같은 랩의 AMA-Bench(2602.22769)가 GateMem Table 1에 인용됨.
- v1→v2(2026-03-30) 사이에 무엇이 바뀌었는지.
