---
title: 팀·조직용 에이전트 메모리 리서치 — 허브
date: 2026-10-12
---

# 팀·조직용 에이전트 메모리 리서치

개인 비서(Hermes, OpenClaw 등)가 아니라 회사/팀 환경, 즉 다수 주체 + 다수 에이전트를 위한 메모리 구조의 최근 동향과 수렴하는 개념을 원문 정독으로 정리한 자료.

## 읽는 순서

1. [implementation-guide-v1.md](implementation-guide-v1.md) — **실제 팀 도입용**: 저장소 구조, 파일 형식, 쓰기/읽기 흐름, 단계별 도입
2. [synthesis.md](synthesis.md) — 수렴하는 개념 9가지, 첫 답변 정정, 미해결 문제, 참조 아키텍처, 설계 체크리스트
3. [platform-comparison.md](platform-comparison.md) — Claude / Letta / AWS / Databricks / Tencent / Asana 비교표
4. `sources/` — 출처별 상세 노트 (섹션 번호, 수치, 저자가 밝힌 한계와 내가 본 약점을 구분, 확인 필요 항목)

## 출처 노트 목록

### 거버넌스 / 엔터프라이즈 공유 메모리

| 노트 | 원문 | 유형 | 정독 |
|---|---|---|---|
| [governed-memory-2603.17787](sources/governed-memory-2603.17787.md) | arXiv 2603.17787 Governed Memory (Personize.ai) | 논문(프로덕션) | 전문 + 부록 |
| [akasicmem-2609.25563](sources/akasicmem-2609.25563.md) | arXiv 2609.25563 AkasicMEM | 설계 논문(실험 없음) | 전문 |
| [lineage-aware-memory-2610.07258](sources/lineage-aware-memory-2610.07258.md) | arXiv 2610.07258 Lineage-Aware Memory Governance (AMU) | 논문 | 본문 전문(보충자료 미공개) |
| [collaborative-memory-2505.18279](sources/collaborative-memory-2505.18279.md) | arXiv 2505.18279 Collaborative Memory | 논문 | 전문 + 부록 |

### 아키텍처 / 벤치마크 / 서베이

| 노트 | 원문 | 유형 | 정독 |
|---|---|---|---|
| [multiagent-memory-comparch-2603.10062](sources/multiagent-memory-comparch-2603.10062.md) | arXiv 2603.10062 컴퓨터 구조 관점의 다중 에이전트 메모리 | 입장 논문 | 전문(그림 미독) |
| [gatemem-2606.18829](sources/gatemem-2606.18829.md) | arXiv 2606.18829 GateMem | 벤치마크 | 전문 |
| [survey-second-half-2602.06052](sources/survey-second-half-2602.06052.md) | arXiv 2602.06052 v4 Agent Memory 서베이 | 서베이 | 부분(핵심 섹션 전문, §6·§8은 훑어봄) |

### 보안 / skill 라이브러리

| 노트 | 원문 | 유형 | 정독 |
|---|---|---|---|
| [maple-guard-2608.00426](sources/maple-guard-2608.00426.md) | arXiv 2608.00426 MAPLE-Guard | 방어 논문 | 전문 |
| [memory-hopping-2609.35576](sources/memory-hopping-2609.35576.md) | arXiv 2609.35576 Memory-Hopping | 공격 논문 | 전문 |
| [misattribution-gap-2605.22842](sources/misattribution-gap-2605.22842.md) | arXiv 2605.22842 Misattribution Gap | 공격/방어 논문 ⚠ 수치 불일치 | 전문 |
| [dynamic-skills-survey-2607.10113](sources/dynamic-skills-survey-2607.10113.md) | arXiv 2607.10113 Dynamic Agent Skills | 서베이 | 전문 |

### 업계 플랫폼 (1차 문서)

| 노트 | 원천 | 정독 |
|---|---|---|
| [claude-managed-agents-memory](sources/claude-managed-agents-memory.md) | Anthropic 문서(memory, dreams), 블로그 | 전문(self-hosted, API ref 미독) |
| [letta-memfs](sources/letta-memfs.md) | Letta 블로그/문서 7페이지 | 전문 |
| [aws-agentcore-memory](sources/aws-agentcore-memory.md) | AWS 블로그 + 개발자 가이드 2개 | 전문(IAM 키 레퍼런스 미독) |
| [databricks-managed-memory](sources/databricks-managed-memory.md) | Databricks 문서(현행 + legacy) | 전문 |
| [tencent-team-memory](sources/tencent-team-memory.md) | TencentDB-Agent-Memory README / ROADMAP / 코드 + VentureBeat | 대부분(일부 API 문서 미독) |
| [asana-awm](sources/asana-awm.md) | Asana 엔지니어링 블로그 + VentureBeat 2편 | 전문 |
| [zep-graphiti-2501.13956](sources/zep-graphiti-2501.13956.md) | arXiv 2501.13956 + Graphiti README | 전문 |
| [context-graphs-decision-traces](sources/context-graphs-decision-traces.md) | Foundation Capital, ContextOS, Neo4j agent-memory, 비판 | 전문(일부 비판은 2차 요약만 확인) |

## 작업 메모

- 2026-10-12 v1: 웹 검색으로 1차 정리한 뒤 원문 정독(하위 에이전트 5개 병렬)으로 출처 노트 19개를 작성하고 종합 문서를 썼다.
- 다음에 보강할 후보: SkillClaw/AutoSkill 원문(팀 간 skill 공유 메커니즘), Claude docs의 프롬프트 인젝션 경고 문구가 판(version)마다 다른지 확인, AWS IAM 조건키 레퍼런스, Tencent v2.0.1 정정 기능 출시 여부.
