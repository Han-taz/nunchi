---
title: Team Memory Core — 설계서 v1.1
date: 2026-10-13
status: 구현 중. develop에 병합된 것과 병합 전인 것을 구분해 적는다
supersedes: team-memory-core-v1.md 중 아래 "v1과의 관계" 표의 부분
files: db/schema.sql, db/tests/smoke_test.sql, db/tests/expectations.tsv, src/nunchi/
---

# Team Memory Core — 설계서 v1.1

이 문서는 지금 만들고 있는 설계를 적는다. [v1 설계서](team-memory-core-v1.md)에서 바뀌지 않은 부분은 v1이 여전히 기준이다. 바뀐 부분은 이 문서가 우선한다.

표기 규칙은 다음과 같다.

- 표기가 없는 내용은 작성 시점(2026-10-13)에 `develop`에 병합돼 있다.
- `planned (unit Ux)`는 아직 병합 전이다. 해당 유닛이 PR로 올라와 있어도 병합 전이면 planned로 적는다.
- 유닛 번호는 아래 표를 따른다. 번호가 없는 항목은 `unit 미배정`이다.

| 유닛 | 내용 | 상태 |
|---|---|---|
| U4a | 위험 등급, `provisional` 상태, `memory_transition` 표 (PR #27) | 병합 전 |
| U4b | `app_sec.decide()`, 정족수, 제안자 신뢰 점수, `approval_card` 표 (PR #29) | 병합 전 |
| U5 | 주체/속성(`entity`, `entity_alias`), 대체 제약 | 계획 |
| U6 | Slack 연동: 바인딩 표, 청중 포함 검사, 카드 발급 | 계획 |
| U8b | bearer JWT 인증, 발급자 기반 테넌트 해석 (PR #19) | 병합 전 |
| U8c | REST API와 Hypothesis RLS 속성 테스트 (PR #34) | 병합 전 |
| U9a | 결정적 쓰기 게이트 (PR #32) | 병합 전 |
| U9b | 추출기 (`Extractor`, `ClaudeExtractor`, `NullExtractor`) | 병합됨 |
| U14 | 릴리스 파이프라인 | 계획 |

## 1. 목적과 범위

### 1.1 v1과의 관계

| v1 절 | v1.1에서 |
|---|---|
| 1 목표와 범위 | 아래 1.2, 1.3으로 대체 |
| 2 전체 구성 | 아래 2절로 대체. 승인 봇은 Slack 어댑터가 되고 추출기가 쓰기 경로 앞에 들어온다 |
| 3 핵심 개념 | 상태에 `provisional`, 위험 등급이 추가됨. `store.auto_approve`는 삭제된다(planned, unit U4a) |
| 4~5 데이터 모델, 권한 강제 | v1의 5절은 대부분 그대로 유효하고 3절에서 현재 구현을 요약한다 |
| 6 API | `propose`에서 `origin` 인자가 빠졌다. `review`는 `decide`로 대체된다(planned, unit U4b와 U8c) |
| 7.1 제안 → 승인 | 4절, 5절로 대체 |
| 11 위험과 남은 결정 | 9절로 대체 |
| 12 구현 순서 | 유닛 표(위)로 대체 |

### 1.2 하는 것

- 에이전트와 사람이 배운 것을 제안하고, 위험 등급이 정한 만큼의 검토를 거친 것만 공유한다.
- 권한 범위(store)별 읽기와 쓰기를 DB가 강제한다. 앱은 권한을 판단하지 않는다.
- 사실이 바뀌면 덮어쓰지 않고 이력과 해시 체인 감사 기록을 남긴다.
- 대화방(Slack)을 출처로 쓰되, 저장하는 것은 증류한 결론과 원문 링크뿐이다.

### 1.3 안 하는 것

- 원본 데이터를 한곳에 모아 복사하는 수집 파이프라인
- 벡터 DB, 지식 그래프
- 에이전트 개인 작업 기억
- 자동 머지되는 정리 작업
- 봇이 먼저 "기록할까요?"라고 묻는 능동 제안, 주기적 digest 캡처
- DM과 그룹 DM의 캡처
- 역할 비트 집합, store 상속, SCIM과 store의 자동 프로비저닝
- DB 안의 JWT 검증, 암호화 파쇄, WORM 앵커
- 신뢰 점수 감쇠 worker, `memory_ref` 정규화 테이블
- 두 번째 메신저(NAVER WORKS 포함)

## 2. 행위자와 표면

핵심 원칙은 하나다. 표면은 모두 같은 서비스 함수 위의 얇은 어댑터이고, 경계는 토큰과 RLS다. MCP는 보안 경계가 아니다.

| 표면 | 하는 일 | 상태 |
|---|---|---|
| DB (`app_sec.*`, RLS, 트리거) | 권한, 상태 기계, 감사의 유일한 구현 | 병합됨 (등급과 `decide`는 planned, unit U4a/U4b) |
| 추출기 | 메시지 한 건을 `ProposalDraft` 초안으로 바꾼다 | 병합됨 (unit U9b) |
| 쓰기 게이트 | 비밀값, 개인정보, 지시문 패턴을 LLM 없이 검사한다 | planned (unit U9a) |
| REST (`/v1`) | `list_stores`, `index`, `search`, `get`, `propose`, `history`, `dependents`. `decide`는 타입이 있는 501 | planned (unit U8c). 인증은 planned (unit U8b) |
| MCP 서버 | 에이전트가 쓰는 같은 함수들의 MCP 노출 | planned (unit 미배정). `src/nunchi/mcp/`는 빈 패키지 |
| Slack | 캡처(📌, @멘션), 승인 카드 DM, 버튼 콜백 | planned (unit U6). `src/nunchi/slack/`는 빈 패키지 |
| SCIM | IdP에서 사용자와 그룹을 동기화한다 | planned (unit 미배정). `src/nunchi/scim/`는 빈 패키지 |
| worker | 만료, 14일 자동 반려, 정정 전파, 방 멤버십 갱신 | planned (unit 미배정). `src/nunchi/worker/`는 빈 패키지 |

행위자는 사람, 에이전트, 시스템 셋이다. 캡처 봇과 승인 봇도 별도 신뢰 등급이 아니라 같은 `principal`(kind `agent`)이다. 캡처 봇은 바인딩된 store의 contributor이고, 승인 봇은 curator 상한만 가진다. 실제 권한은 언제나 사람 ∩ 에이전트이므로, "클릭한 사람의 권한으로 판정한다"는 규칙이 새 코드가 아니라 기존 RLS로 구현된다.

신원은 `app_sec.resolve_principal(발급 테넌트, 종류, external_id)` 하나로 id가 된다. 테넌트는 검증된 토큰의 `iss`에서만 나오고, 요청 헤더나 본문이 고르지 못한다(planned, unit U8b). `X-Agent-Token`은 v1에서 client-credentials JWT를 받는다. RFC 8693 token exchange는 이후 유닛으로 미뤘다.

시스템 작업(worker)은 사용자 컨텍스트가 없다. `memory_transition.by_role = 'system'`인 전이만 컨텍스트 없는 쪽이 할 수 있고, curator 전이는 컨텍스트 없이 하면 `42501`이다(planned, unit U4a).

## 3. 데이터 모델

전체 DDL은 [db/schema.sql](../../db/schema.sql)이 기준이고 `db/migrations/`가 적용 이력이다. 병합된 마이그레이션은 고치지 않는다(`migrations-immutable` job).

### 3.1 store와 principal

- `tenant`, `principal`(user / group / agent), `group_member`, `store`(org / team / project / user), `store_grant(store, principal, role)`. 역할은 reader < contributor < curator.
- 테넌트 경계는 복합 FK가 지킨다. `store(tenant_id, id)`와 `principal(tenant_id, id)`를 `store_grant`와 `memory`가 참조하므로 교차 테넌트 행은 소유자 권한으로도 만들 수 없다.
- `principal.external_id`(IdP subject)는 `app_rw`가 읽으면 `42501`이다. 읽는 길은 `resolve_principal` 하나다.

### 3.2 사용자 ∩ 에이전트 교집합

`app_sec.begin_request(user, agent)`가 principal의 종류, 활성 여부, 테넌트를 DB에서 다시 검증하고 트랜잭션 로컬 값으로 설정한다. 값은 현재 xid에 묶인다. 세션 레벨 `SET`이나 풀러에 남은 값은 xid가 맞지 않아 읽히지 않는다. 컨텍스트가 없으면 권한도 없다.

실효 권한은 `app_sec.my_store_roles()`가 계산한다. 사용자와 에이전트 중 한쪽이라도 grant가 없으면 그 store는 목록에 없다. 에이전트가 curator 권한을 받았어도 대리하는 사용자가 curator가 아니면 승인할 수 없다. 정책은 `store_id IN (SELECT ...)`로 쓰므로 행마다가 아니라 요청마다 한 번 평가된다.

이 구조의 한계도 알려져 있다. `app_rw`는 한 트랜잭션 안에서 `set_config`로 컨텍스트를 직접 쓸 수 있으므로 탈취된 앱 서버는 신원을 위조할 수 있다. `begin_request`는 실수와 풀러 누수를 막는 장치이고 탈취를 막지 못한다. DB 안에서 토큰을 검증하는 방식은 범위 밖이다(1.3).

### 3.3 RLS와 쓰기 경로

- 읽기: 실효 권한이 reader 이상이고 테넌트가 같을 때 active, superseded, expired를 본다. `proposed`는 대리된 사용자 본인(`coalesce(on_behalf_of, created_by)`)과 curator만 본다. `rejected`와 `deleted`는 curator만 본다. `provisional`도 reader가 본다(planned, unit U4a).
- INSERT: contributor 이상. BEFORE INSERT 트리거가 작성자, 대리 사용자, 테넌트를 요청에 묶는다. 다른 값을 보내면 `42501`이다. 상태, 버전, 내용 해시(서버 비밀키 HMAC)는 서버가 정한다.
- UPDATE: BEFORE UPDATE 트리거가 불변 컬럼, origin 단방향(external → internal 금지), `memory_transition` 표에 있는 전이만 허용한다. 위반은 `P0001`이다.
- `app_rw`는 `memory`에만 SELECT/INSERT/UPDATE를 가진다. `memory_version`, `review`, `deleted_hash`, 권한 테이블은 SELECT만이고, 쓰기는 SECURITY DEFINER 함수와 트리거가 한다.
- 함수는 모두 `SET search_path = pg_catalog, public, pg_temp`로 고정한다. `TEMPORARY` 권한은 `PUBLIC`에서 회수했다.
- 검색은 `app_sec.search()`(SECURITY DEFINER)로 한다. RLS 아래에서는 `@@`가 LEAKPROOF가 아니라 GIN 인덱스를 못 쓰기 때문이다. 함수가 정책과 같은 가시성 규칙을 직접 적용하고, 입력은 1000자와 tsquery 노드 64개로 제한한다.

### 3.4 감사 해시 체인

`memory_version`은 append-only이고 트리거만 기록한다. 행마다 `snapshot_hash`, 직전 행의 `prev_hash`, 둘을 묶은 `row_hash`를 가진다. 삭제하면 모든 과거 snapshot을 NULL로 지우지만 해시는 남으므로 `app_sec.verify_chain(memory_id)`가 계속 검증할 수 있다. actor, reason, 순서 중 무엇을 바꿔도 `false`다. 외부 앵커링(WORM)은 범위 밖이다.

### 3.5 새로 들어오는 표

| 표 | 역할 | 상태 |
|---|---|---|
| `memory_transition(from_status, to_status, op, by_role, reviewed)` | 허용 전이 13행이 전부. 트리거는 이 표를 조회할 뿐 분기하지 않는다 | planned (unit U4a, `reviewed` 열은 U4b) |
| `approval_tier_rule(tier, initial_status, approvals_needed)` | 등급마다 최초 상태와 정족수 | planned (unit U4a) |
| `proposer_trust(principal, store, points, approved, rejected, retracted, demoted_until)` | (제안자, store)별 신뢰 | planned (unit U4a 표, U4b 갱신) |
| `trust_rule(op, points, ...)` | 전이의 op마다 점수 변화 | planned (unit U4b) |
| `approval_card(nonce, memory_id, version_at_issue, issued_to, ...)` | 카드 1장 = nonce 1개 | planned (unit U4b 표, U6 발급) |
| `entity`, `entity_alias`, `memory.subject_id`, `memory.attribute` | 주체/속성 | planned (unit U5) |
| `principal_identity`, `room_binding`, `room_member`, `inbound_event` | Slack 신원, 바인딩, 멤버십, 수신 이벤트 | planned (unit U6) |
| `source_system(tenant, system, host_pattern, authority, is_internal)` | 출처 허용목록으로 origin을 서버가 정함 | planned (unit 미배정) |

## 4. 쓰기 경로

```text
캡처 ─▶ 추출기 ─▶ 결정적 게이트 ─▶ 위험 등급 ─▶ proposed / provisional / active ─▶ decide
(사람·에이전트)  (초안, 데이터)   (reject·flag)   (서버가 정함)                      (curator)
```

1. 캡처. 사람이나 에이전트가 `propose`를 직접 부르거나, Slack에서 📌 또는 @멘션으로 메시지 한 건을 고른다(planned, unit U6).
2. 추출기. `Extractor.extract(source_text, context)`가 `ProposalDraft(kind, title, body, subject, attribute, source_refs, valid_from, origin)`을 돌려주거나, 기억할 가치가 없으면 `None`을 돌려준다. `origin`과 `source_refs`는 호출자가 `ExtractContext`로 넘기고 모델이 정하지 못한다. 모델 출력은 고정 JSON 스키마이고 이후 단계에서 데이터로만 쓰인다. 메시지 본문은 `<source>` 구분자 안에 넣고, 꺾쇠 괄호의 모든 표기(전각, 작은 형태 포함)를 HTML 엔티티로 바꿔 구분자를 닫지 못하게 한다. `ANTHROPIC_API_KEY`가 없으면 `NullExtractor`가 첫 줄을 제목으로 쓴다.
3. 결정적 게이트(planned, unit U9a). LLM 없이 규칙 레지스트리 16행을 돈다. 비밀값과 한국 개인정보 패턴은 reject, 지시문 패턴은 flag다. 게이트는 추출된 본문과 원 메시지 둘 다에 돌린다(`evaluate_pair`, 합집합에서 가장 엄격한 verdict). 추출기가 지시문을 빼고 의미만 남기는 경우를 막기 위해서다. 결과는 `memory.gate_result`에 들어간다.
4. 위험 등급(planned, unit U4a). `app_sec.risk_tier(memory)`가 5.1의 표 순서 그대로 등급을 정한다. 클라이언트가 보낸 `status`, `tier`는 트리거가 덮어쓴다.
5. 최초 상태. 등급이 `approval_tier_rule`을 통해 정한다. `auto`는 active, `auto_labeled`는 provisional, 나머지는 proposed다.
6. 결정. proposed와 provisional은 `app_sec.decide()`로만 움직인다. 직접 `UPDATE ... SET status`는 review 행이 없으면 `42501`이다(planned, unit U4b).

상태 기계는 다음과 같다(planned, unit U4a). 표에 없는 전이는 `P0001`이다.

```text
proposed ──auto_activate(system)──▶ provisional ──confirm(curator)──▶ active
   │                                    ├──retract(curator)──▶ rejected
   │                                    └──supersede / delete(curator)
   ├──approve(curator, 정족수)──▶ active
   └──reject(curator)──▶ rejected
active ──supersede(curator)──▶ superseded       active ──expire(system)──▶ expired
{active, provisional, superseded, expired, rejected} ──delete(curator)──▶ deleted (종단)
```

`provisional`은 불리언이 아니라 상태다. 읽기 정책, 검색 기본값, 오염 전파가 각자 불리언을 기억할 필요가 없다. 검색과 `index`의 기본 필터는 active만이고, provisional을 섞으려면 명시해야 한다(`include_provisional`). API 응답은 항상 `status`와 `tier`를 싣는다(planned, unit U8c). 에이전트는 provisional 메모리를 인용할 때 "미검토"라고 밝히고, 그것을 근거로 행동 규칙을 바꾸지 않는다.

provisional은 조용히 active가 되지 않는다. 사람이 `confirm`하거나 `retract`한다.

## 5. 승인 모델 B

소유자가 정한 모델이다: 저위험 제안은 자동으로 노출하고, 고위험 제안은 사람 curator가 승인한다. "신뢰 점수가 먼저"라는 1라운드 권고는 모델 B를 거부하는 조건이 아니라 등급표의 한 행(11행)이 됐다.

### 5.1 위험 등급표 (planned, unit U4a)

입력은 모두 서버나 DB가 정한 값이다. 위에서부터 첫 일치 행이 등급이다. `risk_tier()`는 이 순서를 단일 `CASE`로 구현한다.

| # | 조건 | 등급 |
|---|---|---|
| 1 | 게이트 verdict가 reject | 행을 만들지 않고 거부 (게이트 쪽, planned unit U9a) |
| 2 | `store.kind = user` | `auto` (active, 라벨 없음) |
| 3 | `store.kind = org` 또는 `kind = decision` | `two_curators` |
| 4 | `supersedes_id`가 있고 대상이 decision이거나 curator 저작이거나 출처 authority가 더 높음 | `two_curators` |
| 5 | `supersedes_id`가 있음 (그 외) | `one_curator` |
| 6 | `kind = procedure` | `one_curator` |
| 7 | `origin = external` | `one_curator` |
| 8 | 게이트 flags가 비어 있지 않음 | `one_curator` |
| 9 | `conflict_with`가 있거나 `gate_result.containment`가 `ok`가 아님 | `one_curator` |
| 10 | 제안자가 강등 중 | `one_curator` |
| 11 | 제안자가 user이거나 신뢰 점수가 20 이상 | `auto_labeled` (provisional) |
| 12 | 그 외 (신뢰가 없는 에이전트) | `one_curator` |

설계가 정한 이유는 다음과 같다.

- 에이전트가 쓴 제안에 첫날부터 자동을 주면 공유 store를 거쳐 다른 에이전트로 퍼지는 경로(memory-hopping)가 신뢰가 쌓이기 전에 열린다. 승격 관문을 뺀 실험에서 피해가 16배였다는 결과가 근거다.
- procedure는 지시문 형태 그 자체라서 자동이 될 수 없다.
- user store의 자동(2행)도 게이트는 통과해야 한다. user store 메모리를 `memory://`로 인용한 공유 store 제안과 provisional을 인용한 제안은 `origin = external`로 취급돼 7행을 탄다.
- `conflict_with`는 서버가 채운다(planned, unit U5). 지금은 NULL로 고정이라 9행의 충돌 조건은 U5 전까지 발화하지 않는다.
- `origin`은 지금 `memory://` 근거를 통해서만 external이 된다. 출처 host로 external을 정하는 `source_system`은 아직 없다(9절).

### 5.2 승인 경로: `decide()` (planned, unit U4b)

`app_sec.decide(nonce, memory_id, expected_version, verdict, reason)`가 유일한 승인 경로다. SECURITY DEFINER이고 `app_rw`는 EXECUTE만 가진다. 거절 사유는 위에서부터 첫 일치 하나만 돌려준다.

| 반환 | 뜻 |
|---|---|
| `active` / `rejected` / `pending_quorum:n/m` / `comment` | 처리됨 |
| `unknown_nonce` | 없는 nonce |
| `wrong_clicker` | 카드 수신자가 아님 |
| `duplicate:<원결과>` | 같은 nonce 재사용. review 행과 버전은 변하지 않음 |
| `mismatch` / `expired` | 카드의 memory와 다름 / 만료 |
| `not_curator` | 클릭한 사람이 그 store의 curator가 아님 (사람 ∩ 봇) |
| `stale` | 카드를 발급한 뒤 memory 버전이 바뀜. review 행을 남기지 않음 |
| `self_review` | 제안자나 대리 사용자 본인 |

`wrong_clicker`를 `duplicate`보다 앞에 둔다. 반대 순서면 소비된 nonce를 아는 남이 원래 결과를 읽는다.

정족수와 직무 분리는 `decide()`가 아니라 트리거가 본다. `decide()`를 우회해 UPDATE해도 제안자 본인이면 `42501`이고, 서로 다른 비저자 reviewer 수가 `approvals_needed`보다 적어도 `42501`이다. `two_curators`는 서로 다른 curator 두 명의 approve가 필요하다. 첫 사람은 `pending_quorum:1/2`를 받는다. supersede 승인은 같은 호출에서 옛 행을 superseded로 바꾼다. review는 판단한 memory 버전을 `review.version`에 담고(트리거가 채운다), 정족수는 현재 버전의 review만 센다. 본문이 바뀌면 이전 승인은 기록에만 남고, 역할을 회수했다 복구하면 이전 승인이 다시 센다.

### 5.3 신뢰 점수 (planned, unit U4b)

키는 (제안자 = `created_by`, store)다. 사람이 📌을 찍으면 캡처 봇이 저자이고 사람이 `on_behalf_of`다. 갱신은 AFTER 트리거가 하므로 앱이 우회하지 못한다.

| 사건 | 점수 | 기타 |
|---|---|---|
| approve, confirm | +1 | |
| reject (proposed에서) | -5 | |
| retract (provisional에서) | -10 | 30일 강등 |

회수가 반려의 두 배인 이유는 이미 다른 에이전트가 읽었을 수 있기 때문이다. 임계값 20, 첫 10건 100% 표본, 이후 20% 표본은 측정값이 아니라 파일럿 기간에 맞춘 시작값이다.

### 5.4 소유자가 정한 값 (2026-10-12)

1. 사람이 쓴 저위험 제안은 첫날부터 `provisional`로 자동 노출한다. (제안자, store)의 첫 10건은 100% 표본 검토한다.
2. 신뢰 임계값은 20이다. 첫 10건은 100%, 그 뒤는 20% 무작위 표본이다. 4주 뒤 재검토하고, 회수율이 5%를 넘으면 임계값을 올린다.
3. Slack Connect 채널은 바인딩할 수 있고 `origin = external`을 강제한다(항상 curator 1인 이상). 파일럿 팀에 Connect 채널이 없으면 허용하지 않고 시작한다.
4. 방 바인딩은 테넌트 관리자가 하고, 그 store의 curator 한 명이 확인한다.
5. 삭제 계약에 Slack 카드 삭제(`chat.delete`, 제목 한 줄)를 포함하고 참여자에게 고지한다. 기밀 store는 id만 담은 카드를 보낸다.

### 5.5 사후 검토 루프 (planned, unit 미배정)

매주 store별 digest 한 장이 새 provisional 전체를 보여 준다. 개별 카드의 확인·회수 버튼은 5.4의 표본 규칙을 따른다. 종속 항목(`memory://` 인용)이 생긴 provisional은 100% 검토한다. 표본 검토자는 저자가 아니어야 하므로 curator 본인의 제안은 다른 curator에게 간다. 회수되면 종속 항목에 "근거 바뀜"을 표시한다.

### 5.6 콜드 스타트

| 저자 | store | 저위험 제안의 등급 |
|---|---|---|
| 사람 (직접 제안 또는 📌) | team, project | `auto_labeled` |
| 사람 | org | `two_curators` |
| 자율 에이전트 세션 | team, project | `one_curator` (20점까지) |
| 누구나 | user | `auto` |

📌 캡처의 저자는 캡처 봇이다. 관리자가 바인딩할 때 캡처 봇의 `proposer_trust.points`를 20으로 명시적으로 시드한다. 내용은 사람이 골랐고 청중은 바인딩이 묶었기 때문이다. 시드는 `room_binding` 감사 행에 남는다. 회수가 쌓이면 캡처 봇도 똑같이 강등된다.

## 6. 대체(supersession) (planned, unit U5)

문제: v1은 내용 해시가 정확히 같을 때만 중복으로 본다. "A사 담당자 = 이OO"와 "= 박OO"가 둘 다 active가 된다.

### 6.1 데이터 모양

- `entity(store_id, canonical_name)`, `entity_alias(store_id, alias_norm, entity_id, added_by)`. entity는 store 단위다. 같은 고객사가 sales와 hr에 따로 있어도 store 경계를 entity로 넘지 않는다.
- `memory.subject_id`, `memory.attribute`(NFKC, 소문자, 공백 정규화는 트리거), `memory.conflict_with`.
- `fact`는 subject와 attribute가 필수다(`fact_needs_subject`, 기존 행 때문에 `NOT VALID`로 추가하고 backfill 뒤 `VALIDATE`). 주체를 못 찾으면 `note`다.
- 같은 (store, subject, attribute)의 살아있는 행(active, provisional)은 하나뿐이다. 부분 유니크 인덱스가 아니라 `DEFERRABLE` EXCLUDE 제약(`memory_subject_live_excl`)으로 구현한다. 부분 유니크 인덱스는 DEFERRABLE이 안 되어 "옛 행 먼저, 새 행 나중" 순서에 묶이기 때문이다.

### 6.2 후보 매칭

1. 추출기가 `subject`(문자열)와 `attribute`를 낸다. 이 두 필드는 이미 `ProposalDraft`에 있다.
2. 서버가 `alias_norm(subject)`로 `entity_alias`를 정확 일치로 찾고, 없으면 `canonical_name`을 정확 일치로 찾는다. 없으면 새 entity 후보다.
3. 같은 키의 살아있는 행이 있으면 트리거가 `conflict_with`를 채운다. 5.1의 9행이 이 값을 읽는다.
4. 2단계가 실패했을 때만 FTS와 trigram으로 entity 후보 5개를 모아 LLM 판정기에 준다. 판정기는 `{same_subject, relation: duplicate|update|unrelated, suggested_alias, confidence}`를 JSON으로 낸다.
5. 카드에 "A사 ≈ A Corp?" 질문과 대체·별도·반려 버튼을 보인다. 대체 버튼은 별칭 추가(`added_by` = curator), `supersedes_id` 설정, 승인을 한 번에 한다. 별도 버튼은 새 entity를 만든다. 같은 키가 살아있으면 EXCLUDE 제약이 막는다(`23P01`, 카드는 소비되지 않는다).

LLM 판정기는 후보를 지목하고 의견을 낼 뿐이다. entity 생성, 병합, 별칭 추가, `supersedes_id` 설정, 등급 낮추기는 하지 못한다. 등급은 판정기 출력을 입력으로 쓰지 않는다. 판정 의견은 카드에 "에이전트 의견"으로 격리해 보인다.

### 6.3 대체는 자동이 아니다

대체를 선언한 제안은 최소 `one_curator`다(5.1의 4, 5행). 대체 승인은 `decide()` 한 트랜잭션 안에서 옛 행 superseded(`valid_to` = 새 행의 `valid_from` 또는 오늘), 새 행 active를 함께 처리한다. U4b의 `decide()`는 대체 처리에 UPDATE 두 개만 쓰고, 제약을 `DEFERRED`로 바꾸고 마지막에 즉시 검사하는 부분은 U5에서 붙는다. 같은 빈 키를 두 제안이 동시에 보면 두 번째 INSERT가 `23P01`을 받고, API가 이를 `conflict_with`가 있는 `one_curator` 제안으로 다시 제출한다.

## 7. Slack 연동 (planned, unit U6)

전송은 개발 중 Socket Mode이고, 서명 비밀은 이후 HTTP 모드를 위해 둔다. 메시지 본문은 Slack에서 가져오되 저장하지 않는다.

### 7.1 방은 출처다

방은 store가 아니라 출처다. 메모리에는 증류한 결론(fact, decision, procedure)과 원문 링크만 남고 대화 로그는 남지 않는다. 캡처 트리거는 두 가지뿐이다.

| 트리거 | 이벤트 | 캡처 범위 |
|---|---|---|
| 📌 (`:pushpin:`) | `reaction_added` | 그 메시지 1건과 스레드 부모 permalink. 스레드 전체가 아님 |
| @봇 멘션 | `app_mention` | 멘션된 메시지. 스레드 답글이면 부모 메시지 1건 |

봇이 먼저 "기록할까요?"라고 묻는 방식은 바인딩된 모든 채널의 `message` 이벤트를 구독해야 하므로 제외한다. "초대된 채널만 읽는다"는 약속이 사실상 "초대된 채널은 전부 읽는다"가 되기 때문이다.

수신 흐름: 서명 검증, `inbound_event(dedup_key)` 적재, 200 응답을 3초 안에 한다. worker가 `conversations.history(channel, latest=ts, inclusive=true, limit=1)`로 메시지 한 건을 가져오고(봇이 멤버인 채널만 가능하다), 추출기와 게이트를 거쳐, `begin_request(핀 찍은 사람, 캡처 봇)`으로 `propose`한다. 핀 찍은 사람이 바인딩 store의 contributor가 아니면 교집합이 막는다.

### 7.2 바인딩 규칙

- `room_binding(platform, workspace_id, channel_id, kind, store_id, bound_by, revoked_at)`. `kind`는 public, private, connect 셋뿐이다. DM과 그룹 DM은 `kind`에 없으므로 바인딩할 수 없다. 살아있는 바인딩은 (platform, workspace_id, channel_id)당 하나다.
- 바인딩하지 않은 방의 제안은 거부한다. 바인딩은 테넌트 관리자가 하고 그 store의 curator 한 명이 확인한다(5.4의 4).
- 바인딩 표는 필요조건이지 충분조건이 아니다. 채널이 비공개로 바뀌거나 사람이 나가거나 Connect가 붙는 일은 바인딩 뒤에도 생긴다. 그래서 제안마다 `app_sec.room_containment(binding)`이 "store의 사람 reader 중 채널 멤버가 아닌 사람 수"(`missing_readers`)를 다시 센다. `room_member` 스냅샷이 1시간보다 오래되면 fail-closed다.
- 청중 포함 검사는 거부가 아니라 등급 상승이다. `containment`가 `ok`가 아니면 5.1의 9행으로 `one_curator`가 되고, 사람이 승인하면 그것이 기록된 declassification이다. 좁은 곳에서 넓은 곳으로 올리는 승격은 사람의 행위이고 가역이 아니다.
- Slack Connect 채널은 `origin = external`을 강제한다. 외부 멤버는 principal이 아니므로 store reader가 될 수 없다.
- Slack 사용자는 `principal_identity(platform, platform_user_id, principal_id, link_quality)`로 principal과 잇는다. `link_quality`는 `scim`과 `email`이고, `email` 품질은 열람만 되고 `decide()`를 못 한다. 이메일 변경과 재사용이 승인 권한으로 이어지는 길을 끊기 위해서다.

### 7.3 카드는 DM으로, 버튼은 nonce로

1. 발급: 등급이 `one_curator`나 `two_curators`인 제안마다 store curator별로 `approval_card` 한 행을 만들고 DM으로 보낸다. `two_curators`는 최소 두 사람에게 보낸다. 버튼 값은 `{"n": nonce}`뿐이다.
2. 수신(`block_actions`): raw body로 `v0=HMAC-SHA256(v0:{ts}:{body})`를 상수 시간으로 비교하고 `|now - ts| <= 300s`를 확인한다. `team.id`가 테넌트의 workspace 목록에 있어야 한다. 서명 검증은 JSON 파싱 전에 raw body로 해야 한다.
3. 처리: `user.id`를 `principal_identity`(`scim` 품질)로 principal에 푼다. 없거나 `email` 품질이면 "연결 안 됨"으로 끝낸다.
4. 클릭한 사람으로 행동: 코어를 부를 때 클릭한 사람이 주체(`sub`)이고 봇이 행위자(`act`)인 단기 토큰을 쓴다. 코어는 `begin_request(클릭한 사람, slack-bot)` 뒤에 `decide(nonce, memory_id, expected_version = version_at_issue, verdict)`를 부른다. 봇이 curator 권한의 서비스 토큰을 갖는 경로는 없다.
5. 결과는 `chat.update`로 카드의 버튼을 지우고 결과 한 줄을 남긴다. `response_url`은 30분 5회 한도라 쓰지 않는다.

카드에는 제목(80자 이하), kind, store slug, 등급, 저자 표시명, 게이트 flag 수, 충돌 후보 제목, 검토 UI 딥링크를 싣는다. 본문, 출처 URL, subject 값은 싣지 않는다. 기밀 store의 카드는 제목 대신 "[기밀 store 제안 #id]"만 보인다. 본문 미리보기는 ephemeral 메시지로만 보인다.

`memory.delete`는 그 memory의 모든 `approval_card.message_ts`에 `chat.delete`를 부른다. 실패하면 재시도 큐에 넣고 삭제 저널에 미완료로 남긴다.

### 7.4 Slack 고유 위험

- 메시지를 수정하거나 지워도 캡처본은 남는다. v1.1은 `source_refs[].captured_at`만 기록한다. `message_changed`와 `message_deleted`를 종속 표시에 연결하는 일은 이후 버전이다.
- 워크스페이스 보존 정책으로 원문이 사라질 수 있다. Slack 출처는 `inherit_acl = false`로 두어 링크가 접근 게이트가 아니라 출처 표시가 되게 한다.
- 비공개 채널은 봇이 멤버여야 멤버십을 읽는다. 봇이 없는 채널은 바인딩할 수 없다(검사 불가는 fail-closed).
- Slack에서만 비활성화된 사용자는 `principal.active`를 바꾸지 못한다. active는 IdP SCIM이 정한다.
- 서명 키를 탈취당하면 공격자는 이미 발급된 카드를 그 수신 curator의 이름으로 처리할 수 있다. 새 제안을 만들거나 남의 권한을 얻지는 못한다.

## 8. 보안 불변식

각 항목은 불변식과, 그것을 지키는 테스트 또는 CI job을 짝지어 적는다. 테스트 id는 `db/tests/expectations.tsv`의 id이고, `scripts/db-test.sh`가 current 스키마에서 통과하고 알려진 취약 스키마(`db/tests/fixtures/schema_v1_0_vulnerable.sql`)에서 `on_vulnerable` 열의 값대로 실패하는지 확인한다(`db-tests`와 `mutation-gate` job). 앱 테스트는 `tests/` 아래 pytest이고 `app-tests`와 `app-mutation` job이 돈다.

1번부터 18번까지는 병합돼 있고, 19번부터는 `planned`다. planned 항목은 해당 유닛이 병합되기 전까지 `develop`의 어떤 검사도 지키지 않는다.

1. 컨텍스트는 `begin_request`만 만든다. 비활성, group, agent 위장은 `28000`이고, 세션 레벨 `SET`으로 위조한 컨텍스트는 0행이다. 테스트 `F3a`~`F3d`, `F4`.
2. 에이전트를 붙여도 권한은 늘지 않는다. 한쪽 grant가 없으면 권한이 없다. 테스트 `X1a`~`X1g`, `F1`, `F6a`, `F6b`, 앱 쪽 `tests/test_db.py::test_agent_is_intersected_with_user`와 `test_agent_without_a_grant_sees_nothing`.
3. 테넌트 경계는 복합 FK와 정책이 지킨다. 테스트 `N8a`~`N8c`, `N11a`, `N16a`~`N16d`.
4. 작성자, 대리 사용자, 테넌트, 상태, 해시는 서버가 정한다. 위조하면 `42501`이다. 테스트 `X2a`~`X2h`, `F5`. 앱 쪽에서 `origin`은 클라이언트 필드가 아니다: `tests/test_models.py::test_origin_is_not_a_client_field`.
5. 존재 오라클이 없다. 못 읽는 행과 없는 행을 `supersedes_id`와 `memory://`로 가리키면 같은 오류다. 테스트 `F7a`~`F7h`.
6. 권한, 감사, 삭제 해시 테이블은 `app_rw`가 쓰지 못한다. 테스트 `X3a`~`X3g`, `X4a`~`X4l`, `X5a`~`X5i`, `F8a`~`F8d`, `N4b`.
7. `app_rw`가 실행할 수 있는 함수는 허용 목록과 정확히 같고, 내부 함수는 직접 부를 수 없다. 새 함수는 목록에 의식적으로 추가해야 한다. 테스트 `P3`, `P3b`, `P3c`, `P1`, `P2a`~`P2c`.
8. 모든 함수는 `search_path`를 고정하고 `pg_temp`를 마지막에 둔다. 임시 객체로 권한 함수를 가로챌 수 없다. 테스트 `S1`(`scripts/db-test.sh`가 `lint_search_path.sql`로 실행), `S2a`~`S2e`, `S3`, `S4`, `S5a`~`S5d`.
9. 감사 체인은 변조를 드러낸다. 소유자가 트리거를 끄고 actor나 reason을 바꿔도 `verify_chain`이 `false`다. 테스트 `F9f`~`F9h`, `P5`.
10. origin은 단방향이고 삭제된 행은 되살아나지 않는다. 삭제하면 본문과 모든 snapshot이 NULL이 된다. 테스트 `F9b`~`F9e`.
11. 삭제된 내용은 다시 들어오지 못한다. 공백, NBSP, 보이지 않는 문자, 결합 문자 사이의 U+034F로 변형해도 같은 해시다. 테스트 `F10`, `P4a`~`P4c`, `N12a`~`N12i`. 보이지 않는 문자 클래스는 `sql-lint` job이 `scripts/gen-unicode-ignorables.py --check`로 UCD 고정 파일에서 다시 만들어 비교한다.
12. 검색은 호출자가 직접 읽을 수 있는 행만 돌려주고 기본 status는 active다. 입력은 1000자와 tsquery 노드 64개로 제한한다. 테스트 `N10a`~`N10m`, `N13a`~`N13h`, 정책 비용은 `F11`.
13. `principal.external_id`는 `app_rw`가 읽지 못하고 `resolve_principal`만 id를 준다. 테스트 `N14a`~`N14c`, `N15a`~`N15e`.
14. 추출기 출력은 데이터이고 `origin`과 `source_refs`는 호출자가 정한다. 메시지 본문이 구분자를 닫지 못한다. 테스트 `tests/test_extract.py`의 `test_remembered_message_becomes_draft_with_caller_owned_fields`, `test_request_shape_and_injection_stays_in_user_content`, `test_closer_variants_are_neutralized`, `test_any_source_stays_inside_one_delimiter_pair`.
15. 게이트를 약하게 만드는 PR은 자기 자신을 통과시키지 못한다. `gate-integrity` job은 `pull_request_target`에서 베이스의 스크립트로 `pr-size`, `migrations-immutable`, 커밋 규칙, `expectations.tsv` 삭제를 검사하고 PR 헤드를 실행하지 않는다. `ci-gate`는 모든 job이 success가 아니면(건너뜀 포함) 실패한다.
16. 병합된 마이그레이션은 바뀌지 않고, `schema.sql`은 마이그레이션을 순서대로 적용한 결과와 같다. `migrations-immutable`, `schema-drift` job.
17. 테스트는 이빨이 있다. 등록하지 않은 테스트와 출력되지 않은 테스트는 실패하고, `on_vulnerable = fail`인 테스트는 취약 스키마에서 반드시 실패한다. `db-tests`, `mutation-gate` job. 앱은 변경된 모듈에 대해 `app-mutation`(죽인 뮤턴트 80% 이상)이 같은 역할을 한다.
18. 변경 크기는 800줄(추가+삭제)을 넘지 못하고 `docs/design`도 면제가 아니다. `pr-size` job.
19. 등급은 서버가 정하고 클라이언트의 `status`, `tier`는 무시된다(planned, unit U4a). 테스트 `G1a`, `G1b`, `G1d`, `G1f`~`G1s`(`G1l`은 등급 규칙 표, `G1m`은 전이 표), `B6a`, `F6c`, `N10n`.
20. 전이 표에 없는 전이는 거부되고 `tier`는 바뀌지 않는다. 컨텍스트가 있는 쪽이 system 전이를 하거나 없는 쪽이 curator 전이를 하면 `42501`이다(planned, unit U4a). 테스트 `G3m`~`G3p`.
21. 직접 `UPDATE ... SET status`로 승인하지 못한다. 제안자 본인은 승인할 수 없고, 정족수는 서로 다른 비저자 reviewer로 센다(planned, unit U4b). 테스트 `T5`, `T5b`, `G3g`, `G3i`, `G3k`, `G3w`, `G3x`.
22. 카드 결과가 표와 같다: `wrong_clicker`, `duplicate`, `stale`, `expired`, `not_curator` 등(planned, unit U4b). 테스트 `G3a`~`G3v`.
23. 신뢰 점수는 트리거가 갱신하고 회수는 강등을 낳는다(planned, unit U4b). 테스트 `G4a`~`G4i`.
24. 사용자 ∩ 에이전트가 HTTP를 거쳐도 지켜진다. 무작위 테넌트, 그룹, grant, 에이전트에서 오라클이 계산한 가시 집합이 API 결과와 같고, 에이전트를 붙여도 가시성이 늘지 않으며, 요청이 테넌트를 고르지 못한다(planned, unit U8c). Hypothesis 테스트.
25. 토큰의 테넌트는 `iss`에서만 나오고, 만료, 잘못된 `aud`, `alg: none`, HS256 혼동은 거부된다(planned, unit U8b). `tests/` 아래 인증 테스트.
26. 게이트 규칙은 멱등이고, 제로폭 문자를 넣어도 reject가 유지된다(planned, unit U9a). `tests/test_gate.py`.
27. 청중 포함: store의 사람 reader가 채널 멤버가 아니면 `one_curator`이고, 스냅샷이 1시간보다 오래되면 fail-closed다(planned, unit U6). 사양이 정한 시나리오 `G5a`~`G5e`가 있으나 저장소에는 아직 테스트가 없다.
28. Slack 서명은 raw body로 검증하고 재전송은 `inbound_event`의 키로 멱등이다(planned, unit U6). 테스트는 U6에서 정한다.

## 9. 열린 항목

- `origin`의 서버 결정(planned, unit 미배정). 지금 DB는 `memory://` 근거로 external을 전파할 뿐이고, 출처 URL이 내부 시스템이 아닌 경우를 external로 만드는 `source_system`이 없다. 앱 모델은 `origin`을 클라이언트 필드로 받지 않지만, DB 자체는 INSERT의 `origin` 값을 덮어쓰지 않는다. `source_system`이 생기면 5.1의 7행이 비로소 웹 출처를 잡는다.
- `gate_result`는 앱이 채운다. DB는 이를 검증하지 않고 5.1의 8, 9행이 그대로 읽는다. 탈취된 앱 서버가 게이트 결과를 지우는 것은 3.2의 알려진 한계와 같은 뿌리다. DB 안의 토큰 검증이 P1 항목이다.
- 14일 무처리 자동 반려. v1과 사양은 `rejected`에 system actor와 `reason = 'review_expired'`를 쓰기로 했지만, 현재 전이 표에서 `proposed → rejected`는 curator만 할 수 있다. system 전이를 추가하거나 worker 설계를 따로 정해야 한다(planned, unit 미배정).
- worker 설계: 만료, 정정 전파, 주간 digest, 방 멤버십 갱신(1시간 주기와 `member_joined_channel` 이벤트), subject 없는 fact와 미해결 별칭 보고. 신뢰 점수 감쇠(30일 승인 0건이면 양수 점수를 0.9배)는 이후 버전이다.
- 사양은 decision의 `rationale`이 비면 게이트가 거부하도록 정했다. U9a의 규칙 레지스트리에 이 규칙이 있는지 확인하지 못했다.
- MCP 서버와 SCIM 동기화의 유닛 번호가 없다.
- 감사 로그 외부 앵커(WORM)와 `verify_chain` worker.
- 삭제 계약 문서: 무엇이 지워지고(본문, snapshot, Slack 카드 제목) 무엇이 남는지(메타, 해시, 백업 N일). 파일럿 참여자에게 고지해야 한다. PITR 복원 뒤 삭제 저널을 다시 적용하는 절차도 필요하다.
- 한국어 전문검색. `search_tsv`가 `simple` 설정이라 "담당자가"와 "담당자"가 다른 토큰이다. 형태소 분석기 선택이 필요하다.
- 파일럿 지표: provisional 체류 시간(p50, p90), 회수율(저자별, store별), 표본 카드 처리율, `decide` 반환값 분포(`stale`과 `duplicate` 비율이 높으면 카드 UX 문제), `room_containment` 실패율, 매핑되지 않은 reader 수.
- 원천 ACL 상속(`inherit_acl`) 어댑터는 v1의 계획 그대로 남아 있고 이 문서는 바꾸지 않는다. Slack 출처만 `inherit_acl = false`로 고정한다.
