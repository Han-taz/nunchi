---
title: Team Memory Core — 설계서 v1
date: 2026-10-12
status: draft (스키마·RLS는 Postgres 16에서 스모크 테스트 통과)
files: db/schema.sql, db/tests/smoke_test.sql
---

# Team Memory Core — 설계서 v1

## 1. 목표와 범위

조직 종류(개발, 영업, 인사, 운영)와 상관없이, 여러 사람과 여러 에이전트가 함께 쓰는 팀 메모리를 만든다.

하는 것

- 에이전트가 배운 것을 제안하고, 담당자가 승인한 것만 공유한다.
- 권한 범위(store)별로 읽기와 쓰기를 DB가 직접 강제한다.
- 사실을 정정할 때 덮어쓰지 않고 이력과 감사 기록을 남긴다. 삭제 요청에도 대응한다.
- 원본 데이터는 기존 시스템에 두고 링크로만 참조한다.

안 하는 것 (v1)

- 원본 데이터를 한곳에 모아 복사하는 수집 파이프라인
- 벡터 DB, 지식 그래프 (필요해지면 확장점으로 추가)
- 에이전트 개인 작업 기억 (각 에이전트 런타임 몫)
- 자동 머지되는 정리 작업

## 2. 전체 구성

```text
 사용자 ── 에이전트 런타임 (Claude Code / Codex / Hermes / Copilot / 자체 봇)
              │  ① 원천 읽기: 기존 MCP/공식 커넥터, "사용자 권한"으로 (복사 안 함)
              │  ② 메모리 읽기/제안: MCP
              ▼
     ┌─────────── Memory Core ───────────┐
     │ MCP 서버 + REST API (같은 서비스 계층) │
     │  - 인증: OIDC 토큰(사용자) + 에이전트 클라이언트 자격 │
     │  - 쓰기 게이트 (결정적 검사 → 선택적 LLM 리뷰) │
     │ PostgreSQL (RLS = 권한 강제)          │
     └───────┬───────────────┬────────────┘
             │               │
     승인 봇 (Slack/Teams)   작업자(worker)
     승인/반려/대체 버튼       만료 처리, 주간 정리 제안, 원천 링크 점검
             │
     관리 UI (store 목록, 권한, 검토 대기함, 감사 로그)
     SCIM ← IdP (Okta / Entra / Google): 사용자·그룹 동기화
```

컴포넌트는 서비스 하나(API + MCP), DB 하나, 승인 봇, worker, 작은 관리 UI로 끝난다.

## 3. 핵심 개념

| 개념 | 정의 | 근거 |
|---|---|---|
| store | 접근 경계. 종류는 org / team / project / user. 권한은 store 단위로만 준다 | Databricks "보안 경계는 store", Claude store 패턴 |
| principal | user / group / agent. 그룹은 SCIM으로 동기화한다 | — |
| 실효 권한 | **사용자 권한 ∩ 에이전트 권한.** 에이전트는 대리하는 사용자보다 많이 볼 수 없고, 사용자도 에이전트에게 허용된 것 이상을 시킬 수 없다 | Asana "트리거한 사용자로 범위 고정", AkasicMEM 누수 사례 |
| memory | 레코드 하나 = 지식 하나. 종류는 fact / decision / procedure / note | 파일/레코드 수렴 |
| 상태 | proposed → active → superseded / expired, 또는 rejected, deleted. 검토 전에 이미 노출된 `provisional`이 proposed와 active 사이에 있다. 허용되는 전이는 `memory_transition` 표 한 장이 전부다 | 승격 관문(MAPLE-Guard), 무효화(Zep) |
| 위험 등급 | `auto` / `auto_labeled` / `one_curator` / `two_curators`. 서버 함수 `risk_tier()`가 등급표 순서대로 정하고, `approval_tier_rule` 표가 등급마다 최초 상태와 승인 정족수를 정한다 | Fable 2라운드 §2.1 |
| source_refs | 근거 원문 링크. note를 빼면 필수. 다른 메모리를 근거로 삼을 때는 `memory://<id>` | 계보, 정정 전파 |
| origin | internal / external. 외부 출처 표시는 정리나 요약을 거쳐도 유지한다 | memory-hopping, Misattribution |

### 역할

| 역할 | 읽기 | 제안 | 승인·대체·삭제 |
|---|---|---|---|
| reader | ● | | |
| contributor | ● | ● | |
| curator | ● | ● | ● |

- 에이전트는 기본 contributor다. curator 권한을 받은 에이전트도 대리하는 사용자가 curator가 아니면 승인할 수 없다(교집합).
- 승인은 위험 등급이 정한다. user store는 등급 `auto`(개인 노트)이고, 공유 store의 사람 저위험 제안은 `auto_labeled`(provisional로 시작해 표본 검토를 받는다), 나머지는 curator 1인 또는 2인이다.

## 4. 데이터 모델

전체 DDL은 `db/schema.sql`에 있다. 요약하면:

- `tenant`, `principal`, `group_member`: 주체와 SCIM 동기화 결과
- `store`, `store_grant(store, principal, role)`: 경계와 권한
- `memory`: 본문, 메타데이터, 상태, 출처, 작성 주체(`created_by`), 대리한 사용자(`on_behalf_of`), 세션, 게이트 결과, 내용 해시, 버전(낙관적 잠금), 전문검색 인덱스
- `memory_version`: append-only 변경 기록(감사 로그). 트리거로 수정과 삭제를 막는다. 단, 내용만 비우는 redact는 허용한다.
- `review`: 사람 승인과 리뷰 에이전트 의견
- `deleted_hash`: 삭제한 내용의 해시. 정리 작업이나 재제안이 지운 내용을 되살리지 못하게 막는다.
- `memory_transition(from_status, to_status, op, by_role)`: 상태 기계. `approval_tier_rule(tier, initial_status, approvals_needed)`: 등급 -> 최초 상태와 정족수. `proposer_trust(principal, store, points, ...)`: 제안자 신뢰 점수(20점부터 에이전트도 `auto_labeled`).

DB 수준에서 거는 제약

- deleted 상태면 body가 NULL이어야 한다(tombstone).
- note를 빼고는 source_refs가 비면 안 된다.
- 상태 전이는 `memory_transition` 표에 있는 (from, to)만 가능하고, 표의 `by_role`이 curator면 요청 컨텍스트가, system이면 컨텍스트 없는 워커가 필요하다. `tier`는 INSERT 때 정해진 뒤 바뀌지 않는다.

## 5. 권한 강제 방식

1. API가 요청마다 토큰을 검증한 뒤, 트랜잭션 시작 시 `app_sec.begin_request(user, agent)`를 호출한다. 함수가 principal의 종류(user/agent)·활성·테넌트를 DB에서 다시 검증하고, 값을 트랜잭션 로컬로 설정하면서 현재 xid에 묶는다. 세션 레벨 `SET`이나 풀러 연결에 남은 값은 xid가 맞지 않아 읽히지 않는다(컨텍스트 없음 = 권한 없음). **store나 사용자를 모델이 파라미터로 고르지 않는다.** 모델은 store slug를 고를 수 있지만, 권한은 DB가 다시 판정한다.
2. RLS 정책
   - 읽기: 실효 권한이 reader 이상이고 `tenant_id`가 요청의 테넌트와 같을 때. provisional은 active처럼 reader에게도 보인다. proposed는 대리된 사용자 본인(`coalesce(on_behalf_of, created_by)`)과 curator만 본다. 같은 에이전트를 쓰는 다른 사용자는 남의 proposed를 보지 못한다. rejected와 deleted는 curator만 본다.
   - INSERT: contributor 이상. 작성자는 BEFORE INSERT 트리거가 요청에 묶는다: `created_by` = 에이전트(없으면 사용자), `on_behalf_of` = 에이전트일 때만 사용자, `tenant_id` = 요청의 테넌트. NULL은 채우고 다른 값은 `42501`로 거부한다. `tier`와 최초 status는 트리거가 `risk_tier()`와 `approval_tier_rule`로 정하고(클라이언트가 `active`나 `tier`를 보내도 덮어쓴다), version은 1로, `content_hash`는 서버 비밀키 HMAC으로 덮어쓴다(클라이언트가 `active`나 해시를 보내도 무시). 삭제된 내용의 재제안은 `23505`, `supersedes_id`는 같은 store의 읽을 수 있는 active 또는 provisional 행만 허용하고 `memory://` 근거는 읽을 수 있는 행만 허용한다(없는 행과 못 읽는 행은 모두 `23503`이라 존재 여부가 새지 않는다). 근거 중 하나라도 external이거나 provisional이거나 user store의 것이면 파생 메모리도 external이다.
   - UPDATE: curator만. BEFORE UPDATE 트리거가 불변 컬럼(`store_id`, `kind`, `created_by`, `on_behalf_of` 등), origin 단방향(external→internal 금지), `memory_transition` 표에 있는 상태 전이만(표의 `by_role` 포함), 승인·확인·반려·회수 전이(`reviewed`)는 정족수(등급이 정한 수의 서로 다른 비저자 review)와 직무 분리(제안자 본인 불가, `42501`), 본문 편집은 proposed/active에서만 허용한다. 모든 UPDATE는 version을 1 올리고, 삭제는 본문을 NULL, 제목을 `[deleted]`로 바꾼다. 위반은 `P0001`.
   - 실효 권한은 `app_sec.my_store_roles()`가 계산한다. 정책은 `store_id IN (SELECT ...)`로 쓰므로 행마다가 아니라 요청당 한 번 평가된다(10만 행 `count(*)`가 로컬에서 약 35ms. v1.0 정책은 같은 조건에서 약 3.8초).
   - 테넌트 경계는 복합 FK가 지킨다: `store(tenant_id, id)`, `principal(tenant_id, id)`를 `store_grant`와 `memory`가 (tenant_id, …)로 참조하므로 교차 테넌트 grant나 memory 행은 소유자 권한으로도 만들 수 없다.
   - principal, group_member, store, store_grant: 모두 `FORCE ROW LEVEL SECURITY`. principal은 요청 테넌트의 행만 보인다(같은 테넌트의 표시 이름 해석에 필요해서 store 공유 여부로는 좁히지 않는다). group_member는 내 소속(사용자·에이전트)과 내가 curator인 store에 grant된 그룹의 구성원만, store는 `my_stores()`에 있는 것만, store_grant는 나와 내 그룹의 grant와 내가 curator인 store의 모든 grant만 보인다. `my_store_roles`, `app_sec.closure`, `begin_request`는 SECURITY DEFINER라 이 정책을 거치지 않는다. `principal_closure(p)`는 `p`가 요청의 사용자나 에이전트일 때만 값을 주고 남의 그룹 소속은 빈 집합이다.
   - `principal.external_id`(IdP subject, SCIM id)는 컬럼 단위 GRANT에서 빠져 있어 `app_rw`가 읽으면 `42501`이다. 토큰의 subject를 principal id로 바꾸는 길은 `app_sec.resolve_principal(발급 테넌트, 종류, external_id)`(SECURITY DEFINER) 하나이고, 테넌트와 종류가 정확히 맞는 활성 principal의 id만 돌려주고 그 밖에는 NULL이다.
   - 내용 해시 정규화: 보이지 않는 문자(일반 범주 Cf 전체, Default_Ignorable_Code_Point, 공백이 아닌 Cc)를 지우고, NFKC로 정규화한 뒤 다시 지우고, 공백류(Zs, 줄·문단 구분자, 탭·개행·NEL)를 U+0020 한 칸으로 접고 소문자로 바꾼다. 두 번 지우는 이유는 결합 문자 사이에 낀 U+034F나 U+200B가 NFKC의 합성을 막기 때문이다(`café`와 `cafe`+U+034F+U+0301이 같은 해시). 문자 클래스는 `scripts/gen-unicode-ignorables.py`가 고정된 UCD 파일에서 만들고 CI가 다시 만들어 비교한다.
   - 테스트 헬퍼는 `smoke_test.sql`이 만드는 스키마 `t`에만 있고, P3 허용 목록 검사는 이름이 아니라 이 스키마를 통째로 제외한다.
   - memory_version, review: 부모 memory가 보일 때만 보인다(memory의 RLS 승계). 앱(`app_rw`)은 쓰지 못한다. 버전은 memory 트리거만 기록하고, 삭제 때 과거 snapshot을 전부 redact한다. review 행은 승인 함수 `app_sec.decide()`만 쓴다.
   - deleted_hash: 해당 store의 curator만 읽는다. 쓰기는 삭제 트리거만. contributor의 재제안 검사는 `app_sec.is_deleted_content()`(SECURITY DEFINER)가 대신하고, 해시는 평문 sha256이 아니라 서버 비밀키 HMAC이라 추측 오라클이 되지 않는다.
3. API는 RLS를 우회하지 않는 전용 DB 역할(`app_rw`: `LOGIN NOBYPASSRLS NOINHERIT`, 최소 권한)로 **직접** 접속한다. 테이블과 SECURITY DEFINER 함수의 소유자는 접속에 쓰지 않는 별도 역할(운영에서는 `NOLOGIN` 인 `app_owner`)이고, RLS 테이블에는 `FORCE ROW LEVEL SECURITY`가 걸려 있다. 관리 작업(SCIM 동기화, worker)만 별도 역할을 쓴다. 스모크 테스트의 `SET ROLE app_rw`는 테스트 전용이다. superuser로 접속해 `SET ROLE`하는 구조는 SQL 인젝션 한 번이 `RESET ROLE`로 이어지므로 쓰지 않는다.
   - `app_rw` 권한: tenant/principal/group_member/store/store_grant/memory_transition/memory_version/review/deleted_hash는 SELECT만(스스로 권한 부여 불가, 감사 위조 불가). memory만 SELECT/INSERT/UPDATE. 함수는 허용 목록(`begin_request`, `decide`, `search` 등)만 EXECUTE한다. 역할 생성과 GRANT는 `schema.sql`에 있다.
   - 신뢰 경계: `app_rw`는 한 트랜잭션 안에서 `set_config`로 `app.user_id`, `app.agent_id`, `app.tenant_id`, `app.ctx_xid`를 직접 쓸 수 있다. 탈취된 앱은 컨텍스트를 위조할 수 있다. app_rw can forge context inside a transaction; DB-side token verification is P1 (fable report §6.2). `begin_request`는 실수와 풀러 누수를 막는 장치이지 탈취된 앱을 막는 장치가 아니다. v1.1에서는 이 한계를 받아들인다.
   - 임시 객체 하이재킹 방어: 모든 함수에 `SET search_path = pg_catalog, public, pg_temp`를 건다. `pg_temp`를 빼면 임시 스키마가 관계 조회에서 가장 먼저 검색되어, `app_rw`의 `CREATE TEMP TABLE store_grant`가 `my_store_roles()`를 가로챈다(`principal`, `group_member`도 같다). `pg_temp`는 반드시 마지막에 둔다. `TEMPORARY` 권한도 `PUBLIC`에서 회수한다(기본 권한이 `PUBLIC`에 있어 `app_rw`만 회수하면 효과가 없다). 임시 테이블이 필요한 관리 작업은 소유자로 하거나 따로 GRANT한다. 새 함수가 이 규칙을 어기면 `db-test.sh`의 lint(S1)가 CI에서 실패한다.
   - fail-closed: `begin_request`를 부르지 않았거나 xid가 맞지 않으면 컨텍스트가 NULL이고 권한은 없다(오류도 권한도 아님). 비활성·group·agent id를 user 자리에 넣거나 user id를 agent 자리에 넣으면 `begin_request`가 `28000`으로 거부한다. 에이전트가 있으면 사용자·에이전트 중 한쪽이라도 grant가 없을 때 NULL이다(`least()`는 NULL을 무시하므로 명시 처리). 비활성 principal과 비활성 그룹은 권한을 주지 않는다.
   - append-only 트리거: memory_version은 snapshot→NULL(redact)만 허용하고, snapshot을 뺀 모든 컬럼(reason 포함)이 같아야 한다. review는 UPDATE/DELETE 모두 금지.
   - 해시 체인: 각 버전 행은 `snapshot_hash`, 직전 행의 `prev_hash`, 둘을 묶은 `row_hash`를 가진다. snapshot이 redact돼도 해시는 남아 `app_sec.verify_chain(memory_id)`가 계속 검증할 수 있고, 행의 actor나 순서를 바꾸면 `false`가 된다(앵커링은 worker가 맡는다).
   - 검색: RLS 아래에서는 `@@`가 LEAKPROOF가 아니라 GIN 인덱스를 쓰지 못한다(10만 행에서 41ms 순차 스캔). 검색은 `app_sec.search(query, stores, statuses)`(SECURITY DEFINER)로 제공한다. 함수가 `my_store_roles()`로 `memory_read` 정책과 같은 규칙을 직접 적용하고(같은 호출자가 직접 읽는 행과 같은지는 사용자별로 테스트한다), 기본 status는 active이며, 점수 순 50건까지, 입력은 1000자와 tsquery 노드 64개까지이고 넘으면 `22023`으로 거부한다(`websearch_to_tsquery` 비용이 항 수에 제곱으로 늘어난다). 본문 없이 id·제목만 돌려준다(같은 조건에서 2.2ms).
4. 원천 링크에 `inherit_acl: true`가 붙은 메모리는 조회할 때 원천 시스템에서 사용자의 접근 가능 여부를 확인한다. 결과는 짧게 캐시한다. 원천에서 권한이 사라지면 메모리도 안 보인다. v1에서는 Google Drive, SharePoint, Notion 어댑터만 만든다.

### 스모크 테스트 결과 (Postgres 16, `db/tests/smoke_test.sql`)

| # | 시나리오 | 결과 |
|---|---|---|
| T1 | 영업 Alice + 영업봇이 인사 store 조회 | 0건 ✔ |
| T2 | 영업봇이 Alice 대리로 제안 | 성공 ✔ |
| T3 | 영업봇이 `status='active'`로 INSERT | 성공하되 저장된 status/tier는 `proposed/one_curator` ✔ |
| T4 | contributor Alice가 승인 | 0건 반영 ✔ |
| T5 | curator Carol이 승인 | 1건 반영 ✔ |
| T6 | Carol이 영업봇과 함께 승인 시도 (봇은 contributor) | 0건, 교집합 동작 ✔ |
| T7 | 버전 기록 변조 / redact | 변조 차단, redact 허용 ✔ |
| X1 | 인사 Bob + 영업봇(교집합에 한쪽 grant 없음), 빈 user_id | 권한 NULL, 0건 ✔ |
| F1 | Bob(hr curator, sales reader) + 영업봇(contributor) | `sales=reader`만, hr 없음 ✔ |
| F3 | 비활성 Eve / group id / agent id를 user로, user id를 agent로 `begin_request` | 모두 `28000` ✔ |
| F4 | 세션 레벨 `SET app.*` + `app.ctx_xid='1'` 후 조회 | 0건 ✔ |
| F6 | Dave(reader)+같은 봇 / Alice 단독이 Alice의 proposed 조회 | 0건 / 1건 ✔ |
| F5 | `status='active'`, `content_hash='client-hash'`로 INSERT | 저장값 `proposed`, 해시는 서버 HMAC ✔ |
| F7 | 못 읽는 HR 메모리 / 없는 uuid / 다른 store 메모리를 supersede, `memory://` 근거로 인용 | 모두 `23503`; external을 인용하면 파생도 external ✔ |
| F8 | deleted_hash·memory_version·review 직접 쓰기, 남의 deleted_hash 조회 | 쓰기 `42501`, 조회 0건 ✔ |
| F9 | 승인 → origin 세탁 → created_by 변경 → 삭제 → 소생 → 체인 | 버전 2 / `P0001` / `P0001` / 본문 NULL·snapshot 전부 NULL·deleted_hash 1 / `P0001` / `verify_chain` true; 변조하면 false ✔ |
| F10 | 삭제된 본문의 공백만 바꾼 재제안 | `23505` ✔ |
| N10 | 검색 함수: 못 읽는 store, 기본 status, 자기 proposed, curator 전용 상태, 컨텍스트 없음 | hr 단어 0건, 기본 active만, 작성자·curator만 proposed, 컨텍스트 없으면 0건; 사용자별로 직접 읽은 결과와 일치 ✔ |
| N8 | 교차 테넌트 principal·store로 grant, store와 tenant가 다른 memory (소유자 권한) | 모두 `23503` ✔ |
| F11 | 10만 행 `count(*)` (app_rw) | 로컬 한도 200ms, CI 한도 1000ms ✔ |
| A10 | `app_rw` 속성, `FORCE ROW LEVEL SECURITY` 대상 | `LOGIN`/`NOBYPASSRLS`/`NOINHERIT`, memory·memory_version·review ✔ |
| X2 | created_by / on_behalf_of / tenant_id 위조 제안 | RLS 거부, 정상 제안만 성공 ✔ |
| X3 | app_rw가 store_grant 등 권한 테이블 쓰기·삭제 | 거부(42501) ✔ |
| X4 | 타 store의 버전·리뷰 조회 / app_rw의 버전·리뷰 기록 | 0건, 기록 거부(42501) ✔ |
| X5 | redact 시 reason 등 변조, review 수정·삭제, app_rw의 redact | 트리거 차단, app_rw의 redact 거부(42501) ✔ |
| X6 | 비활성 사용자·그룹·에이전트 | 권한 NULL, 재활성화 시 복구 ✔ |
| S1 | `public`/`app_sec`의 모든 함수(확장 제외)가 `search_path`를 고정하고 `pg_temp`를 마지막에 둠 (lint) | 함수 전부 고정 ✔ |
| S2 | 임시 `store_grant`/`principal`/`group_member`로 권한 상승 시도 | 진짜 role 그대로, 임시 principal은 `begin_request`가 `28000` ✔ |
| S3 | `pg_temp.ctx_user()`, `pg_temp.current_setting()` 함수로 가리기 | 효과 없음 ✔ |
| S4 | `app_rw`의 `CREATE TEMP TABLE` | `42501` ✔ |
| S5 | `principal_closure`를 직접 호출: 비활성 그룹, 비활성 사용자 | 클로저에서 빠짐(`begin_request`를 거치지 않고 확인) ✔ |

## 6. API (MCP 툴 = REST 엔드포인트)

| 툴 | 설명 | 필요 권한 |
|---|---|---|
| `memory.list_stores()` | 내가 쓸 수 있는 store와 설명, 역할 | — |
| `memory.index(store)` | active 항목의 제목과 설명 목록 (progressive disclosure) | reader |
| `memory.search(query, stores?, kind?)` | 전문검색. 기본은 active만 | reader |
| `memory.get(id)` | 본문, 출처, 이력 요약 | reader |
| `memory.propose(store, kind, title, body, source_refs, origin, supersedes?)` | 제안. 게이트 결과를 돌려준다 | contributor |
| `memory.review(id, verdict, note)` | 승인/반려 | curator |
| `memory.supersede(old_id, new_id)` | 대체 처리 | curator |
| `memory.delete(id, reason)` | 삭제(tombstone + 해시 등록 + 버전 redact) | curator |
| `memory.dependents(id)` | 이 메모리를 근거로 인용한 항목(역방향 계보) | reader |
| `memory.history(id)` | 버전 기록 | reader |

- 수정은 `expected_version`을 받는다(낙관적 잠금). 충돌하면 409를 돌려준다.
- 에이전트용 시스템 지시(AGENTS.md나 런타임 설정)는 한 줄이면 된다: "작업 전 memory.list_stores와 memory.index를 보고 필요한 것만 get, 새로 확인한 사실은 출처와 함께 propose."

## 7. 핵심 흐름

### 7.1 제안 → 승인

1. 에이전트가 `propose`를 호출한다.
2. 결정적 게이트가 돈다(LLM 없음, 실패하면 거부하거나 표시한다).
   - 출처 링크 필수
   - 비밀값 패턴 검사(gitleaks 규칙셋) → 걸리면 거부
   - 개인정보 패턴(주민번호, 전화번호, 계좌 등) → 걸리면 거부하고 "원문 링크로 대체하라"고 안내
   - `deleted_hash`와 같은 내용 → 거부
   - 같은 store의 active와 해시가 같으면 → 중복으로 거부
   - `origin=external`이면서 지시문 패턴("항상 ~해라", "이전 지시 무시")이 있으면 → 표시
3. 선택적 리뷰 에이전트가 기존 active와 충돌하는지, 대체 후보는 뭔지 의견을 단다. 의견만 달고 승인하지 않는다.
4. 위험 등급(`risk_tier()`, 등급표 위에서부터 첫 일치)이 `auto`/`auto_labeled`면 바로 active/provisional로 들어가고(provisional은 표본 검토 대상), `one_curator`/`two_curators`면 proposed로 남는다. 승인 봇이 store의 curator들에게 카드(nonce 1개 = memory 1건 x 수신 curator 1명)를 보낸다. 버튼은 클릭한 사용자의 컨텍스트에서 `app_sec.decide(nonce, memory_id, expected_version, verdict)`만 부른다(재전송은 `duplicate`, 버전이 바뀌었으면 `stale`, 남의 카드는 `wrong_clicker`, 제안자는 `self_review`, 정족수 미달은 `pending_quorum:n/m`). 내용, 출처, 게이트 결과, 충돌 후보, `[승인][반려][기존 항목 대체로 승인]` 버튼이 붙는다.
5. 승인되면 active가 되고 버전 기록이 남는다. 반려는 제안자 신뢰 점수 -5, 승인·확인 +1, provisional 회수 -10과 30일 강등으로 `proposer_trust`에 반영된다(비대칭). 대체 승인이면 옛 항목은 superseded가 되고 `supersedes_id`로 연결된다.
6. 일정 기간(기본 14일) 처리되지 않으면 자동으로 rejected 처리한다. 검토 대기함이 쌓이지 않게 하려는 것이다.

### 7.2 정정 전파

- 어떤 항목이 superseded, deleted, expired가 되면 worker가 `dependents`를 조회한다(source_refs의 `memory://` 역참조).
- 하위 항목에 "근거가 바뀜" 표시를 붙이고 해당 curator에게 점검 카드를 보낸다. 자동으로 고치지는 않는다.

### 7.3 삭제 요청 (개인정보 등)

- `memory.delete`: body를 NULL로 만들고 status를 deleted로 바꾼다. 내용 해시는 `deleted_hash`에 등록하고, 해당 항목의 모든 `memory_version.snapshot`을 redact한다. 메타데이터(누가 언제 왜 지웠나)는 남긴다.
- 원칙상 개인정보는 게이트에서 막혀 들어오지 않고 원문 링크로만 참조한다. 원문에서 지우면 거기서 끝난다.

### 7.4 만료와 정리

- `valid_to`가 지나면 worker가 expired로 바꾼다.
- 주간 정리: worker가 store마다 중복 후보, 오래 안 쓰인 항목, 서로 충돌하는 사실을 찾아 **제안 묶음**으로 curator에게 보낸다. 원본은 직접 고치지 않는다(Claude Dreams 원칙).
- 정리는 store 경계를 넘지 않는다. 여러 store를 묶어 요약하는 일은 하지 않는다.

## 8. 조직별 적용 예

| 조직 | store 구성 | curator |
|---|---|---|
| 개발 | org, team:platform, project:payments | 팀 리드, 테크 리드 |
| 영업 | org, team:sales, team:sales-apac | 영업 운영 담당 |
| 인사 | team:hr (인사팀만 reader) | 인사 매니저 |
| 전사 | org (전원 reader, curator는 관리자) | 운영/정책 담당 |

개발팀은 기존 git 기반 팀 메모리(구현 가이드 1~7장)를 써도 된다. 이 경우 Memory Core에 `project:*` store를 두고 git 쪽 decisions/skills를 링크로 참조하면 된다.

## 9. 배포 형태

- 회사 한 곳: 컨테이너 3개(api+mcp, worker, bot) + Postgres. tenant는 1개.
- 여러 조직: tenant 컬럼으로 분리하고 RLS에 tenant 조건을 추가한다(v1 스키마에 컬럼은 있음). 규제가 심한 고객은 고객별 DB를 따로 둔다.
- 백업: Postgres PITR. 감사 기록 보관 기간은 tenant 설정으로 둔다.

## 10. 확장점 (필요해질 때만)

| 신호 | 추가 |
|---|---|
| 전문검색으로 못 찾는 질문이 늘어남 | pgvector 컬럼 + 하이브리드 검색 (같은 DB, RLS 그대로) |
| 시간에 따라 바뀌는 엔티티 관계 질의 | Graphiti를 fact 사본(projection)으로 붙임. 원본은 Postgres |
| 원천 권한 확인이 느림 | 원천 ACL 캐시 테이블 + 웹훅으로 무효화 |
| 승인 부담이 큼 | store별로 "저위험 kind는 리뷰 에이전트 통과 시 자동 승인" 옵션. 단, org store는 제외 |

## 11. 위험과 남은 결정

- **승인 피로:** curator가 제안을 쌓아두면 시스템이 죽는다. 그래서 자동 만료, 묶음 승인, store당 일일 제안 한도를 둔다. 도입 첫 달은 제안 수와 승인율을 지표로 본다.
- **게이트 한계:** 지시문 패턴 검사는 키워드 기반이라 우회될 수 있다. 최종 방어선은 사람 승인과 external 표시 유지다.
- **원천 권한 확인 범위:** v1 어댑터는 Drive, SharePoint, Notion 셋뿐이다. 나머지 원천은 링크만 걸고 권한 확인은 하지 않는다. 이 사실을 UI에 표시한다.
- **아직 정해야 할 것:** 첫 적용 대상(회사 한 곳 / 여러 조직), IdP 종류, 승인 메신저(Slack / Teams), 첫 파일럿 팀.

## 12. 구현 순서

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| 1 | 스키마 + RLS + API의 읽기·제안·승인 + 결정적 게이트 | 스모크 테스트 + API 통합 테스트 통과 |
| 2 | MCP 서버 + 에이전트 1종 연결 | 에이전트가 index → get → propose 수행 |
| 3 | 승인 봇 + SCIM 동기화 | 파일럿 팀에서 제안 → 승인이 메신저로 처리됨 |
| 4 | worker (만료, 정정 전파, 주간 정리 제안) + 관리 UI | 2주 파일럿 지표(제안 수, 승인율, 재사용 횟수) 확보 |
| 5 | 원천 권한 확인 어댑터 | Drive/SharePoint에서 권한 회수 시 메모리도 안 보임 |
