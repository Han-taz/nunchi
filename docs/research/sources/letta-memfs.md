---
title: "Letta Context Repositories / MemFS / Shared memory"
vendor: Letta
urls:
  - https://letta.com/blog/context-repositories
  - https://docs.letta.com/letta-code/memfs
  - https://docs.letta.com/agent-sdk/memory
  - https://docs.letta.com/agent-sdk/repositories
  - https://docs.letta.com/concepts/shared-memory
  - https://docs.letta.com/configuration/memory
  - https://letta.com/blog/our-next-phase
accessed: 2026-10-12
type: vendor-doc
read_status: "full (7개 페이지 web_extract로 전문 읽음; docs.letta.com/letta-code/memfs는 /concepts/memfs로 리다이렉트). 블로그 이미지(f1–f4) 내용은 텍스트로 확인 불가. SDK reference 미독."
---

# Letta Context Repositories / MemFS / Shared memory

## 한 줄 요약

Letta는 에이전트 메모리를 **에이전트 소유 git 저장소(MemFS = Context Repository)** 로 두고 이를 실행 머신에 실제 checkout으로 "투영(project)"하여 bash·파일 도구로 편집하게 하며, 모든 편집은 commit으로 버전화되고, **git worktree**로 백그라운드 메모리 서브에이전트(dreaming/reflection, defrag, doctor)가 동시 작업 후 merge하며, 여러 에이전트 간 공유는 **조직 소유 shared memory repository**로 한다. 기존 서버 측 메모리 도구·sleep-time 에이전트 등은 deprecated.

## 객체 모델 / 범위(scope) 모델

- **MemFS (per-agent)**: "held in a git repository that belongs to the agent — hosted by Letta for cloud agents". 로컬 전용 에이전트는 현재 머신의 repo에 commit(백업은 사용자 책임).
- **Memory = path**: label `persona` → `persona.md`. 각 파일은 Markdown + YAML frontmatter(`name`, `description`). 예외: `MEMORY.md` 인덱스.
- **컨텍스트 적재 규칙**
  - 현재 문서(MemFS concept): **메모리 루트의 파일**은 매 턴 시스템 프롬프트에 로드. "Older agents use a `system/` directory instead."
  - Agent SDK 문서: "memory you set at creation lands under `system/`", "Files under `system/` are in the system prompt every turn. Everything else stays out of context — the agent sees the file tree".
  - 블로그(2026-02): 파일 트리 구조는 항상 시스템 프롬프트에 있고, `system/` 디렉터리 파일은 전부 로드. 에이전트가 파일을 `system/` 안팎으로 옮겨 pin 여부를 스스로 관리(progressive disclosure).
  - 자체 `MEMORY.md`를 가진 하위 디렉터리는 필요할 때까지 컨텍스트 밖; 루트 `MEMORY.md`가 이를 나열.
- **디렉터리 예시**: `$MEMORY_DIR/{MEMORY.md, persona.md, human.md, reference/{MEMORY.md, project-notes.md}, skills/my-skill/SKILL.md}`. 에이전트 소유 skill은 `$MEMORY_DIR/skills`에서 함께 버전화.
- **검색**: 기본적으로 semantic/vector 인덱스 없음 → 파일 검색·읽기 도구. 선택형 MemFS Search mod(`@letta-ai/memfs-search`; keyword, semantic/hybrid는 QMD 필요). 대화 기록 검색은 별개(Cloud: full-text/vector/hybrid).
- **Shared memory repository (org-scoped)**: "a Git repository hosted in Letta Cloud and owned by your organization". 용도: 팀 컨벤션, 제품 지식, 리서치, 계획, 여러 에이전트가 유지하는 문서. Cloud 기능; self-hosted는 자체 git remote로 공유 가능.
  - 이름: 고유, 최대 64자(영숫자, `.`, `_`, `-`).
  - 파일: `files.create/update`는 최대 **10 MiB** 문자열, repo당 **2,000 파일** 초과 시 create 거부. 요청당 1 파일 연산, 성공 mutation은 **commit SHA 반환**.
  - 부착 방식: 세션 `resources`(임시, 세션 종료 시 SDK가 만든 링크 제거) vs `client.agents.repositories.attach()`(영구, 명시적 detach까지).
  - 로컬 위치: `$MEMORY_DIR/../<repository-name>/`. 시스템 프롬프트엔 repo 경로 + 최상위 파일 목록(인라인 아님, 필요 시 읽음).
  - repo 루트의 `skills/<skill-name>/SKILL.md`는 부착된 에이전트에 skill로 제공, detach 시 로딩 중단.

## 쓰기 경로 / 읽기 경로 / 동시성

- **쓰기(에이전트)**: 투영된 checkout을 일반 파일 도구/bash로 편집 → "Edits are local until committed and pushed, at which point they become the agent's memory everywhere." 클라우드 백업 에이전트는 hosted repo로 push.
- **명시적 교육**: `/remember ...` → 에이전트가 위치를 정하고 MemFS에 commit. `/init`은 repo 탐색 + (선택) Claude Code/Codex 이력 리뷰로 초기 계층 생성.
- **SDK 쓰기(shared repo)**: `client.repositories.files.{list,create,read,update,delete}`, `update`에 `precondition: {contentSha256}` → 읽은 뒤 변경되었으면 실패. rename은 `newPath`.
- **공유 repo 동기화**: 에이전트는 git으로 commit·push해야 하며 다른 에이전트는 pull. Letta Code는 처음 clone 후 이후 **fast-forward** 동기화; `letta shared-memory sync`.
- **동시성**: 블로그 — "By giving each subagent an isolated worktree, multiple subagents can process and write to memory concurrently, then merge their changes back through git-based conflict resolution." MemFS 문서 — dreaming·memory doctor는 worktree를 사용해 메인 에이전트를 막지 않음.
- **읽기**: 루트(또는 `system/`) 파일은 항상 컨텍스트, 나머지는 트리/인덱스를 보고 on-demand 읽기. `session.getDeviceStatus()`로 `memoryDirectory` 경로 확인.

## 권한·감사·삭제

- **버전/감사**: "Every memory edit is committed to the MemFS git repository" — 버전 이력, 충돌 해결, 저장/미커밋 경계. 블로그: "every change to memory is automatically versioned with informative commit messages."
- Shared repo: `client.repositories.versions.list(repoId, {path, limit})`, `versions.get(repoId, sha, {path})`, `files.list/read`에 `ref`로 과거 스냅샷.
- **삭제**: `client.repositories.delete(id)` — 이후 list/retrieve에서 사라지며 **SDK에 restore 메서드 없음**. `agents.repositories.detach`.
- **접근 제어**: 문서상 단위는 "repo를 어떤 에이전트에 attach하느냐". repo/파일 단위 read-only 모드, 사용자/principal별 ACL은 이번에 읽은 문서에서 **언급 없음**. "owned by your organization"만 명시.
- **Redaction/retention**: 언급 없음(git 이력에 남은 민감정보 제거 방법 미기재).
- Identities는 deprecated → "move to the application layer using tags"(our-next-phase).

## 정리(consolidation) 메커니즘

- **Dreaming (= memory reflection, sleep-time)**: 백그라운드 서브에이전트가 최근 대화를 리뷰해 교훈을 통합하고 메모리 갱신. 블로그: worktree에서 작업 후 자동 merge, 정보성 commit 메시지.
  - SDK 설정 `dreaming: { trigger: "off"|"step-count"|"compaction-event", behavior: "reminder"|"auto-launch", stepCount }`. `behavior`는 생성 시에만 설정, 세션은 `trigger`/`stepCount`만 override. CLI `/sleeptime` 또는 앱 Dream settings.
  - "Agent reviews before applying" 옵션: 두 번째 백그라운드 대화에서 에이전트가 제안된 업데이트를 검토·수정(토큰 추가, **사용자 승인은 요청하지 않음**).
- **Defragmentation / reorganize**: 블로그 — 메모리 FS를 **백업한 뒤** 서브에이전트가 큰 파일 분할, 중복 병합, "clean hierarchy of 15–25 focused files"로 재구성. 현 문서 — "backs up the current repository before splitting large files, merging duplicates, or restructuring".
- **/doctor (memory doctor)**: 배치·중복·시스템 프롬프트 토큰 사용량 감사.
- **/init 병렬 학습**: 이력 슬라이스별 서브에이전트가 각자 worktree에서 반영 후 main으로 merge("memory swarms").

## 무엇이 deprecated 되었나 (our-next-phase, 2026-03-16)

- Letta Filesystem → 실제 파일시스템 접근, context repositories, computer use.
- 레거시 서버 메모리 도구(`core_memory_replace` 등) 제거 → git-backed repo에 대한 파일 연산.
- Templates → 버전화된 Letta Code SDK / lettactl.
- Identities → 애플리케이션 계층 tags.
- Server-side MCP → client-side skills.
- **Server-side sleep-time agents → client-side subagent system.**
- 하드코딩된 server-side multi-agent tools → subagents, agent-discovery skills.
- Tool rules deprecated.
- 일정: tool rules·legacy tools 즉시, templates·filesystem은 "mid-April"까지.
- `/memfs` 명령: 기존 에이전트에서 `memory(...)` 도구를 detach하고 memory blocks를 git-backed FS로 sync(블로그). SDK는 `memory` preset 이름을 거부("creation backends reject memory preset names").

## 문서가 명시한 보안 경고·권장사항

- "Local-only agents commit to a repository on the current machine, so you are responsible for backing it up."
- 공유 메모리 사용 조건: "Use shared memory when multiple cloud-hosted agents need access to the same Git-backed files and working context."
- Dreaming 리뷰 옵션은 "does not ask you for approval" — 사람 승인 게이트가 아님.
- 명시적 보안(접근 제어, PII, 프롬프트 인젝션) 경고는 이번에 읽은 페이지에 **없음**.

## 팀/조직 메모리 설계에 주는 시사점

- **개인(에이전트) 메모리 vs 조직 공유 메모리의 소유권 분리**를 1급 개념으로 둠(MemFS=1 agent, shared repo=organization) → 팀 메모리 설계에서 "누가 소유하는가"를 저장소 단위로 명시하는 패턴.
- git을 동시성·감사·롤백 기반으로 쓰면 다중 에이전트 쓰기를 **브랜치/worktree → merge** 로 직렬화 가능. 단 merge 충돌을 LLM이 해결하므로 공유 사실의 정합성 검증 단계가 필요.
- 컨텍스트 예산은 **항상 로드(루트/`system/`) vs 인덱스 기반 on-demand**의 2단 구조로 관리 — 팀 메모리는 기본적으로 on-demand(트리/최상위 파일만 노출)로 붙는다.
- 권한 모델이 "attach 여부"뿐이므로 팀/조직 도입 시 read-only 공유, 민감 정보 redaction, 사용자별 ACL을 **애플리케이션 계층에서 보완**해야 함(Identities도 앱 계층 tags로 이동).
- 정리 작업 전 백업 + 서브에이전트 재구성(15–25 파일 목표)은 공유 repo 정리 시에도 PR형 검토와 결합하기 좋은 패턴.
- skill을 메모리 repo에 함께 버전화/배포 → 조직 지식과 절차(skill)를 같은 공유 repo로 배포하는 모델.

## 다른 플랫폼과 비교 포인트

- Anthropic memory store와 가장 유사(파일·경로·sha256 precondition·버전). 차이: Letta는 git commit SHA/ref·worktree·merge, Anthropic은 서버 version + redact + read_only 마운트.
- AWS AgentCore·Databricks는 레코드/엔트리 + 검색 API 중심이고 LLM 추출·consolidation이 서버 측; Letta는 **에이전트 자신이 bash로 메모리를 편집**하고 정리도 클라이언트 측 서브에이전트가 수행.
- 범위 강제: AgentCore(IAM 조건 키), Databricks(store=보안 경계, UC 권한은 legacy), Anthropic(세션 마운트 access), Letta(attach 여부; 세부 ACL 문서상 없음).
- 정리: Letta dreaming은 원본 repo에 직접 merge(백업은 defrag 시) vs Anthropic Dreams는 항상 새 store 산출.

## 확인 필요

- Shared memory repository에 read-only attach, 에이전트/사용자별 권한, 브랜치 보호 같은 접근 제어가 있는지.
- 여러 에이전트가 같은 shared repo에 push할 때 non-fast-forward 충돌 처리 방식(자동 rebase? 에이전트가 수동 merge?).
- git 이력에서 민감정보 제거(redaction/history rewrite) 및 보존 정책.
- 루트 파일 로드(현행) vs `system/` 로드(SDK 문서·구 에이전트) 규칙이 어떤 에이전트 버전부터 바뀌었는지 — 문서 간 서술 차이 존재.
- 클라우드 MemFS repo 크기/파일 수 한도(shared repo의 2,000 파일·10 MiB 외).
- Dreaming 결과 merge 충돌 시 처리, merge 실패 시 재시도/알림.
