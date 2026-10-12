---
title: 업계 팀 메모리 플랫폼 비교표
date: 2026-10-12
basis: sources/의 벤더 1차 문서 노트 (2026-10-12 기준 접근)
---

# 업계 팀 메모리 플랫폼 비교 (2026-10-12 기준)

| 항목 | Claude Managed Agents | Letta (MemFS / shared repo) | AWS AgentCore Memory | Databricks (현행 Beta) | Tencent Team Memory | Asana AWM |
|---|---|---|---|---|---|---|
| 저장 단위 | store(`memstore_`) > memory(path) > version(`memver_`) | git repo 안의 Markdown + frontmatter | namespace 아래 long-term record (strategy가 추출) | store > entry(actor_id, session_id?, path) | 자산 4종: Chat Memory(L0~L3), Skill, Wiki, CodeGraph | Work Graph 객체에 연결된 memory (inferred / explicit) |
| 에이전트 접근 방식 | `/mnt/memory/<slug>/` 파일 마운트, 일반 파일 툴 | 로컬 checkout, bash/git | API 검색(정확 일치 / 하위 트리) | API, BM25 검색(최대 100건) | API + `/v3/tools/call` 필요 시 호출 | 실행 시작 시 + 실행 중 객체 연동 검색 |
| 범위 모델 | 세션당 store 최대 8개 연결 | 에이전트 repo + 조직 shared repo attach | `{actorId}/{sessionId}/{strategyId}` + 커스텀 변수 최대 5개(org/team 등) | actor_id 전략(사용자 / 팀 키 / 합성) | private / team / restricted / agent (+ 문서화 안 된 task) | 원천 작업 권한 상속, 트리거한 사용자로 범위 고정 |
| 권한 강제 | read_only / read_write를 파일시스템 수준에서(클라우드) | attach 여부(read-only attach, ACL은 문서에 없음) | IAM 조건키 namespace / namespacePath / namespaceVariable | **store가 경계**, actor는 접근 제어 아님 | 고정 바인딩 + User/Role/Agent ACL, 기본 private | Work Graph 권한 그대로 |
| 버전/감사 | 변경마다 불변 버전, redact, 보관 30일, restore 없음 | git commit SHA, 기록 조회 가능, delete는 복구 불가 | 문서상 레코드 버전/redact 설명 없음 | 서버 쪽 버전 설명 없음 | Skill 버전 + 리뷰, Chat Memory는 조회/삭제만(편집은 v2.0.1 예정) | 실행마다 사용/생성된 memory 표시, 사용자 조회/삭제 |
| 동시성 | API는 `content_sha256` 선조건, 파일 툴 쓰기는 불명 | git worktree + merge, `contentSha256` 선조건 | 명시 없음 | 명시 없음 | 명시 없음 | 명시 없음 |
| 정리 | Dreams: 원본 불변, 새 store 출력 | dreaming / doctor / defrag (worktree, 백업 후 재정리) | extraction → consolidation → reflection (namespace가 경계) | 없음(프롬프트 지침으로 정리) | L0 → L3 단계적 정제 | 명시 없음 |
| 문서상 주요 경고 | 자격증명 저장 금지, 쓰기 권한 최소화 | — | reflection의 actor 간 프라이버시, 커스텀 변수 누락 시 추출이 조용히 skip | 모델이 범위를 고르게 하지 말 것, 서비스 주체 자격증명 보호 | (외부 비판) 정정/만료/충돌 해결 절차 없음 | — |
| 한도 | memory 100KB, store당 10,000 memories, 세션당 8 store | 2,000 files, 쓰기당 10 MiB(shared repo) | 커스텀 키 5개, 키 32자 / 값 64자 | 이름 3~56자 | — | — |

## 읽는 법

- **경계를 어디에 두나**가 플랫폼마다 다르다. Claude와 Databricks는 store, AWS는 namespace + IAM, Tencent는 자산별 가시성, Asana는 원천 객체 권한이다. 경계 단위를 세밀하게 할수록 정리와 공유 단위도 그만큼 잘게 쪼개진다.
- **파일/git으로의 수렴**이 가장 뚜렷한 쪽은 Claude와 Letta다. 감사와 롤백이 쉬운 대신, 검색이나 구조적 질의는 에이전트가 직접 해야 한다.
- **원천 권한 상속**을 제대로 하는 곳은 Asana 하나다. 기존 권한 그래프가 있다는 전제가 필요하다.
- 동시성, 정정 전파, 삭제 의미론은 **모든 플랫폼에서 비어 있거나 약하다.**
