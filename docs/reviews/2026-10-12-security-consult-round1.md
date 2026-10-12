# Team Memory Core v1 — 아키텍처·보안 컨설팅 보고서

- 대상: [`docs/design/team-memory-core-v1.md`](../design/team-memory-core-v1.md), `db/schema.sql`, `db/tests/smoke_test.sql` (검토 기준은 수정 전 원본 v1.0 = [`db/tests/fixtures/schema_v1_0_vulnerable.sql`](../../db/tests/fixtures/schema_v1_0_vulnerable.sql). 아래 `schema.sql:NN` 줄 번호는 원본 기준)
- 검증 환경: Postgres 16 (docker `postgres:16`), 원본 스키마 + 스모크 테스트 적재 후 실험. 실험 스크립트는 [`exp/`](exp/) (`exp1.sql`, `exp2.sql`, `exp_perf.sql`, `leak.sql`, 수정안 `fix.sql`, 수정 검증 `fixtest.sql`)
- 표기: **[재현됨]** = 위 환경에서 SQL로 재현. **[분석]** = 코드·문서 분석에 근거(실행 불가하거나 앱 계층 사안)

---

## 0. 결론 요약

설계의 뼈대(store = 경계, 제안→승인, 사용자∩에이전트, 링크 우선, append-only 버전)는 업계·학계 수렴 방향과 일치하고 올바르다. 그러나 **v1 스키마는 "RLS가 권한을 강제한다"는 핵심 주장을 아직 실현하지 못한다.** 선행 리뷰 X1~X6에 더해 이번 검토에서 다음을 추가로 확인했다.

| # | 발견 | 심각도 | 상태 |
|---|---|---|---|
| N1 | 세션 변수가 트랜잭션 xid 등에 바인딩되지 않아, 풀러/ORM의 세션 레벨 `SET` 한 번이면 **다음 요청이 이전 사용자 신원을 상속** | Critical | [재현됨] |
| N2 | `app.user_id`에 group/agent principal id를 넣어도 통과(kind 미검사) → 그룹 자체를 사용자로 가장하면 그 그룹의 전 권한 획득 | High | [재현됨] |
| N3 | `supersedes_id`/`memory://` FK 검사가 RLS를 우회해 **타 store 메모리 존재 오라클** + 크로스 store supersede 링크 생성 | Medium | [재현됨] |
| N4 | `deleted_hash`를 contributor가 타 store에 삽입(검열 DoS) / 전체 열람 / PK 충돌로 **삭제된 내용 존재 오라클**(평문 sha256) | High | [재현됨] |
| N5 | curator가 `origin` external→internal, `created_by`, `source_refs`를 자유 수정(**taint 세탁**), `deleted`→`active` **소생**, 버전 번호 불변 | High | [재현됨] |
| N6 | contributor 세션에서 **타 store 감사 스냅샷 열람 + 전체 redact + 가짜 approve 버전/리뷰 삽입**(actor를 curator로 위조) | Critical | [재현됨] |
| N7 | 같은 봇을 쓰는 **다른 사용자(reader)가 내 미승인 제안을 봄**, 정작 본인은 에이전트 없이 못 봄 | Medium | [재현됨] |
| N8 | 교차 테넌트 grant 생성 가능, `memory.tenant_id ≠ store.tenant_id` 행 허용 | High | [재현됨] |
| N9 | RLS 정책 함수가 행마다 3회 평가: 200k행 `count(*)` **8ms → 8,067ms(1,000배)** | High(가용성) | [재현됨] |
| N10 | RLS 테이블에서 `@@`, `@>`가 non-LEAKPROOF라 **GIN 인덱스(전문검색·역방향 계보)가 아예 사용 불가** → 모든 검색이 seq scan | High(가용성) | [재현됨] |
| N11 | `kind='note'`는 출처 불필요 + `origin` 기본 internal + 클라이언트 지정 → **note→memory://→fact 세탁 사슬**로 외부 지시문이 internal fact로 승격 | High | [분석] |
| N12 | user store `auto_approve`가 memory-hopping의 **자가 오염 경로**: 인젝션된 에이전트가 user store에 쓰고 다음 세션에 읽어 지속성 확보, 이후 team store로 memory:// 인용 세탁 | High | [분석] |
| N13 | `inherit_acl`을 제안하는 에이전트가 지정 → 원천 ACL 상속이 **비신뢰 주체의 opt-in** | High | [분석] |
| N14 | 승인 봇이 본문을 Slack/Teams에 복사 → 삭제 요청이 닿지 않는 **제3자 보존소** 생성; PITR/WAL/로그/LLM 리뷰어 로그도 동일 | High(컴플라이언스) | [분석] |
| N15 | curator가 **자기 제안을 자기가 승인**(직무 분리 없음), org store 단일 승인 | Medium | [분석] |

수정안(`fix.sql`)을 같은 환경에서 적용해 N1~N9, X1~X6이 닫히고 `count(*)`가 83ms로 회복됨을 확인했다(§6 참조). **파일럿 전 P0 항목(§6.1)을 끝내지 않으면 "DB가 권한을 강제한다"는 문구를 설계서에서 빼야 한다.**

---

## 1. 위협 모델

### 1.1 자산

1. 공유 메모리 본문·제목(요약이라도 원천 정보의 사본이다)
2. 권한 그래프(`store_grant`, `group_member`) — 변조되면 모든 것이 무너짐
3. 감사 기록(`memory_version`, `review`) — 사후 귀속·규제 대응의 근거
4. 승인 흐름의 무결성(누가 무엇을 승인했나)
5. 에이전트 행동(메모리가 에이전트의 미래 행동을 바꾼다 = 공격의 진짜 목표)
6. 신원 자산(OIDC 토큰, 에이전트 자격, Slack 서명키, DB 자격)

### 1.2 행위자와 현재 설계의 방어 상태

| 행위자 | 목표 | 현재 설계가 막는가 | 구멍 |
|---|---|---|---|
| 악성/탈취된 에이전트(올바른 자격 보유) | 권한 밖 읽기, 승인 없는 쓰기, 저자 위조 | 읽기: store 교집합으로 **부분** 차단. 쓰기: proposed 강제 ✔ | X1(교집합 NULL), X2(저자 위조), N3(존재 오라클), N4(검열), N6(감사 파괴), N7 |
| 외부 콘텐츠로 프롬프트 인젝션된 정상 에이전트 | 지시문을 공유 메모리에 심어 다른 에이전트 조종(memory-hopping) | 결정적 게이트 + 사람 승인 ✔(최종 방어선) | N11(note 우회), N12(user store 자가 오염), origin 클라이언트 지정, 게이트 키워드 우회 |
| 악의적 내부 contributor | 그럴듯한 출처로 사실 왜곡, 승인 피로 악용, 타인 제안 열람 | 승인 ✔ | 출처 URL 내용 미검증, 묶음 승인·일일 한도의 역이용(§4.3), N7 |
| 부정한 curator | 세탁·소생·저자 변경·감사 흔적 조작 | **거의 못 막음** | N5, N15, 버전 기록이 앱 의존(트리거 없음) |
| 탈취된 앱 서버 | 임의 신원 가장, 권한 자가 부여 | **전혀 못 막음** | X3(grant 쓰기), N1/N2, DB가 앱의 신원 주장을 무조건 신뢰 |
| 교차 테넌트 공격자 | 타 테넌트 데이터 | 못 막음(RLS에 tenant 조건 없음, 설계서 9장도 "추후") | N8 |
| 퇴사/권한 회수된 사용자 | 토큰·SCIM 지연 창 활용 | 못 막음 | X6, SCIM 지연(§4.4) |
| DB 운영자/백업 접근자 | 삭제된 PII 복원 | 못 막음 | N14, 암호화 파쇄 없음 |

### 1.3 신뢰 경계

```text
[외부 문서/웹] --(비신뢰)--> [에이전트 런타임] --(사용자 토큰+에이전트 자격)--> [API/MCP] --(app.* 세션변수 = 앱 주장)--> [Postgres RLS]
                                                                                 ↕ (서명 검증)            ↕ (SCIM, 완전 신뢰)
                                                                          [Slack/Teams 승인 봇]         [IdP]
```

핵심 문제: **DB는 API 서버가 세션 변수에 넣는 신원을 검증 없이 신뢰**하고, API 서버는 에이전트가 넣는 `origin`/`inherit_acl`/`created_by`/`content_hash`/`gate_result`를 검증 없이 저장한다(`schema.sql:71-81`에 모두 일반 컬럼). 즉 신뢰 경계가 두 군데에서 "선언"으로만 존재한다.

---

## 2. 선행 리뷰 X1~X6 확인 (간단히)

모두 원본에서 재현됨.

- X1 `least()` NULL 무시(`schema.sql:158`): Bob(HR curator)+sales-bot → sales=contributor, hr=curator **[재현됨 E1]**. 수정 후 Bob+bot은 어느 store에도 권한 없음(올바름) **[재현됨 F1]**.
- X2 저자 위조: 수정 후 트리거가 세션값으로 덮어씀 **[F5]**.
- X3 `GRANT ... ON ALL TABLES`(`smoke_test.sql:5`): 수정 후 self-grant 거부 **[F8d]**.
- X4 `memory_version`/`review` RLS 없음: Alice(sales)가 HR 스냅샷 열람 **[E6a]** → 수정 후 0행 **[F8e]**.
- X5 redact 비교에 `reason` 누락(`schema.sql:135-136`): `to_jsonb(OLD)-'snapshot' = to_jsonb(NEW)-'snapshot'`로 교체.
- X6 `principal.active` 미검사(`schema.sql:21`): 퇴사자 Eve가 hr curator **[E6d]** → `begin_request`가 거부 **[F3a]**.

---

## 3. 신규 취약점 상세

### 3.1 DB 계층

**N1. 세션 변수 누수 / 풀러 혼선 — Critical [재현됨 E2]**
`SET app.user_id`(LOCAL 아님)를 한 번 쓰면 트랜잭션이 끝나도 남아 다음 트랜잭션에서 curator 권한이 유지됐다. 또 `SET LOCAL`을 트랜잭션 밖에서 호출하면 WARNING만 내고 무시되며, **이전 세션 값이 그대로 쓰인다.** PgBouncer transaction 모드에서는 세션 레벨 `SET`이 다른 클라이언트의 커넥션으로 그대로 넘어간다. 실제 사고 경로: ORM 연결 옵션(`options=-c app.user_id=...`), 재시도 로직이 BEGIN 없이 SET LOCAL 호출, 헬스체크 쿼리가 세션 SET 사용.
현재 `effective_role`은 "값이 비어 있으면 예외"(`''::uuid` 캐스트 오류, E13)로 fail-closed지만 **"값이 남아 있는" 경우는 fail-open**이다.
수정: 컨텍스트를 SECURITY DEFINER 함수로만 설정하고 `pg_current_xact_id()`에 바인딩. 누수·위조된 세션 컨텍스트는 0행 **[F4a]**.

```sql
-- fix.sql 발췌
PERFORM set_config('app.ctx_xid', pg_current_xact_id()::text, true);   -- begin_request 안
CREATE FUNCTION app_sec.ctx_user() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN current_setting('app.ctx_xid', true) = pg_current_xact_id()::text
              THEN nullif(current_setting('app.user_id', true), '')::uuid END $$;
```

주의: `pg_current_xact_id()`는 읽기 트랜잭션에도 xid를 배정하고 hot standby에서는 실행 불가다. 읽기 복제본에는 `app.ctx_until = clock_timestamp()+'15s'` lease 방식 + 풀러 `server_reset_query=DISCARD ALL`을 쓴다. 탈취된 앱 서버에는 이 방식이 소용없다(xid는 누구나 조회 가능). 그 경우는 §6.2의 DB 측 토큰 검증이 답이다.

**N2. principal kind 미검사 — High [재현됨 E18]**
`app.user_id`에 그룹 principal `sales`의 id를 넣으면 그룹의 contributor 권한을 그대로 얻는다. 에이전트 id를 user 자리에 넣어도 통과. API가 OIDC `sub`를 `(tenant, kind='user', external_id)`로 조회하면 평소엔 문제없지만, SCIM `externalId`와 OIDC `sub`가 충돌하거나 external_id를 키로만 조회하는 버그 하나로 즉시 권한 상승이 된다. 수정: `begin_request`가 `kind`와 `active`, 테넌트 일치를 검증 **[F3b, F3c]**.

**N3. FK 존재 오라클 + 크로스 store supersede — Medium [재현됨 E3]**
FK 검사는 RLS를 우회한다. sales contributor가 `supersedes_id`에 HR 메모리 id를 넣으면 INSERT 성공(= 존재 확인), 임의 uuid면 FK 오류. UUIDv4라 무작위 추측은 어렵지만 id는 `memory://` 참조, Slack 카드, 로그로 흔히 샌다. 더 큰 문제는 **sales 제안이 HR active 메모리를 "대체"한다고 선언한 행이 만들어진다**는 것. 정정 전파 worker(설계서 7.2)가 이 링크를 따라가면 HR curator에게 sales 내용이 노출될 수 있다. 수정: 트리거에서 `supersedes_id`는 **같은 store의 active이면서 내가 읽을 수 있는 행**으로 제한. 못 읽는 경우와 없는 경우가 같은 오류 메시지 **[F7a=F7b]**.

**N4. deleted_hash 검열/오라클 — High [재현됨 E4]**
contributor 세션이 HR store에 `deleted_hash`를 삽입할 수 있다(이후 HR의 정당한 제안이 게이트에서 "삭제된 내용"으로 거부됨 = 검열 DoS). PK 충돌로 "이 내용이 HR에서 삭제된 적 있다"를 확인할 수 있고, 해시가 평문 sha256(`schema.sql:81` 주석)이라 추측 가능한 짧은 문장(연봉, 징계 등)에 대해 사전 공격이 된다. 수정: 쓰기 권한 회수 + RLS(curator만 열람) + **HMAC(서버 비밀키)** 해시 + 검사만 SECURITY DEFINER 함수로 **[F8a, F10]**.

**N5. curator 세탁·소생·무버전 수정 — High [재현됨 E5]**
`memory_curate`(`schema.sql:181`)는 UPDATE 전체를 허용하므로 curator가 `origin` external→internal, `created_by`를 타인으로, `source_refs`를 공식 링크로 바꾸고 `version`은 1 그대로 둘 수 있다. `deleted` 행을 `active`로 되돌리며 새 본문을 넣는 것도 된다(CHECK는 "deleted면 body NULL"만 본다, `:87`). 설계서 §3의 "외부 출처 표시는 정리나 요약을 거쳐도 유지한다"가 DB에서 강제되지 않는다. 수정: BEFORE UPDATE 트리거로 불변 컬럼, 상태 기계, origin 단방향(internal→external만), 버전 자동 증가 **[F9b, F9c, F9e]**. 다른 store로 이동은 원본에서도 막혔다(WITH CHECK 생략 시 USING 적용, E5c).

**N6. 감사 로그 파괴·위조 — Critical [재현됨 E6]**
app_rw에 `memory_version`/`review` INSERT·UPDATE가 있으므로 contributor 세션에서 (a) HR 스냅샷 열람, (b) `UPDATE memory_version SET snapshot=NULL` 전체 redact(트리거가 "redact"로 허용), (c) `actor_id=Carol, op='approve'` 가짜 버전과 `reviewer_id=Bob, verdict='approve'` 가짜 리뷰 삽입이 모두 성공했다. "변조 차단 ✔"(설계서 T7)은 UPDATE만 막은 것이다. 수정: 쓰기 권한 회수, 버전 기록은 memory 트리거(SECURITY DEFINER)만 작성, 해시 체인 **[F8b, F8c, F9f]**.

**N7. proposed 가시성 오류 — Medium [재현됨 E7]**
정책(`schema.sql:169`)이 `created_by = app.agent_id`를 보므로 **같은 봇을 쓰는 Dave(reader)가 Alice의 미승인 제안("민감한 초안")을 보고**, Alice 본인은 에이전트 없이 접속하면 못 본다. 미승인 제안은 게이트만 통과한 날것이라 승인 전 노출은 의미가 크다. 수정: `coalesce(on_behalf_of, created_by) = ctx_user()` **[F6]**.

**N8. 테넌트 경계 부재 — High [재현됨 E9]**
타 테넌트 principal에 HR curator grant가 들어가고 즉시 읽힌다. `memory.tenant_id`가 store의 테넌트와 달라도 저장된다. 설계서 9장은 "여러 조직이면 추가"라고 하지만 **단일 테넌트라도 복합 FK는 지금 넣어야** 나중에 데이터 정합성 마이그레이션을 피한다. 수정: `store(tenant_id,id)`/`principal(tenant_id,id)` UNIQUE + 복합 FK, 정책에 `tenant_id = ctx_tenant()`.

**N9. 정책 평가 비용 — High(가용성) [재현됨 exp_perf]**
`memory_read`는 `effective_role()`을 최대 3회 호출하고 함수가 인라인돼 행마다 `store_grant` 조회가 돈다. 200k행에서 `count(*)` 8ms(owner) → 8,067ms(app_rw). 수정: 실효 권한을 SRF `my_store_roles()`로 묶고 정책에서 `store_id IN (SELECT ...)`로 쓰면 **hashed SubPlan으로 쿼리당 1회** 평가 → 83ms **[F11]**.

**N10. non-LEAKPROOF 연산자와 GIN 인덱스 — High(가용성) [재현됨 leak.sql]**
RLS가 걸린 테이블에서 사용자 조건의 연산자가 LEAKPROOF가 아니면 정책 조건 뒤에 평가돼야 하므로 인덱스 조건으로 못 쓴다. `ts_match_vq`(`@@`)와 `jsonb_contains`(`@>`)는 모두 `proleakproof=false`. 결과: `memory_search_idx`(`:92`)와 `memory_sources_idx`(`:93`)가 **app_rw에서는 한 번도 쓰이지 않는다**(seq scan, cost 486,755). `ALTER FUNCTION ts_match_vq LEAKPROOF` 후 즉시 Bitmap Index Scan. 선택지: (a) 검색/역방향 계보를 SECURITY DEFINER 함수로 제공하되 **정책과 동일한 `my_store_roles()`로 필터**(권장: 랭킹·한도·레이트리밋도 여기서), (b) `ts_match_vq`를 LEAKPROOF로 표시(에러를 내지 않는 함수라 실무상 흔하지만 공식 보증 없음), (c) `memory://` 참조는 `memory_ref(memory_id, ref_id)` 정규화 테이블로 옮겨 `uuid_eq`(LEAKPROOF) 인덱스 사용.

**기타 [분석]**

- `smoke_test.sql:29`는 superuser로 접속해 `SET ROLE app_rw`한다. 실서비스가 이 패턴이면 SQL 인젝션 한 번에 `RESET ROLE`로 superuser. 앱은 `app_rw LOGIN NOBYPASSRLS NOINHERIT`로 직접 접속하고, 테이블 소유자는 별도 `app_owner`, `ALTER TABLE ... FORCE ROW LEVEL SECURITY`.
- `pg_stats`는 RLS 테이블을 숨긴다(E8a=0, 안전). `pg_class.reltuples`/`pg_stat_user_tables`로 전체 행 수·변경량은 보인다(저위험 부채널).
- `principal_closure`(`:146-148`)는 한 단계다. Okta/Entra의 중첩 그룹은 SCIM으로 평탄화되지 않는 경우가 많아 권한이 "덜" 주어지는 쪽으로 깨진다(누수는 아니지만 운영 장애). 재귀 CTE + 깊이 제한.
- `memory_version UNIQUE(memory_id, version, op)`(`:117`)는 같은 버전에 같은 op가 두 번 못 들어가지만, 쓰기 권한이 남아 있는 한 또 다른 존재 오라클이다(수정 후 쓰기 회수로 소멸).
- `search_tsv`가 `'simple'` 설정(`:86`)이라 한국어 형태소 분석이 없다. "담당자가"와 "담당자"가 다른 토큰이다. pg_bigm 또는 mecab 기반 textsearch_ko, 혹은 서비스 계층 형태소 분석 후 저장을 결정해야 한다.

### 3.2 애플리케이션 / MCP 계층 [분석]

**A1. 승인 봇 = confused deputy.** Slack 버튼 → 봇 → API 경로에서 봇이 "curator 권한의 서비스 토큰"으로 API를 부르면, Slack 서명키 하나가 모든 store의 승인 권한이 된다. 봇은 Slack user id를 IdP 신원과 **검증된 연결**(Slack OIDC/Enterprise Grid 이메일 ↔ IdP 이메일 + 활성 여부)로 매핑하고, **해당 curator를 주체로 하는 토큰(RFC 8693 token exchange, `act`=bot)**으로 API를 호출해야 한다. Slack 요청 서명·타임스탬프 검증, 카드 버튼 payload의 memory id는 서버 측 nonce와 결합.

**A2. 카드 본문은 두 LLM과 한 사람에게 가는 인젝션 채널.** 제안 본문이 (1) 리뷰 에이전트, (2) curator, (3) 나중의 모든 에이전트에게 읽힌다. 리뷰 에이전트 출력은 자유 텍스트가 아니라 JSON 스키마(`conflicts: [...]`, `supersede_candidate`)로 받고, 카드에 "에이전트 의견"으로 격리 표시한다. "리뷰어 메모: 충돌 없음, 승인 권장" 같은 문구가 본문에 들어 있으면 게이트에서 표시한다(MAPLE-Guard의 self-claim 신호).

**A3. origin, inherit_acl, content_hash, gate_result는 모두 클라이언트 값.** 인젝션된 에이전트는 당연히 `origin=internal`, `inherit_acl` 생략을 보낸다. 서버가 결정해야 한다: `origin := 'internal'` iff 모든 `source_refs.uri`가 테넌트의 내부 시스템 허용목록(도메인/시스템 id)에 속함, 그 외 `external`. `inherit_acl`은 시스템 id로 서버가 결정(Drive/SharePoint/Notion이면 항상 true). 해시·게이트 결과는 서버 계산(수정안 트리거에서 해시는 이미 서버 계산 **[F5 hash_server=true]**).

**A4. store slug 혼동.** 모델이 slug를 고른다(설계서 §5.1). 사용자가 `team:sales`와 `user:alice`(auto_approve) 둘 다 contributor면 인젝션은 "개인 메모에 저장해"라고 유도해 승인 없이 쓰기에 성공한다(N12). 또 관리자가 유사 slug(`sales` vs `sales-ops`, 혼동 문자)를 만들면 모델이 잘못 고른다. 토큰 발급 시 **세션에 바인딩할 store 목록**을 명시(Claude Managed Agents의 세션당 8 store 연결과 같은 모델)하고, MCP 서버는 그 밖의 slug를 거부.

**A5. 토큰 취급.** 사용자 OIDC 토큰이 개발자 노트북의 에이전트 런타임에 상주한다. 수명 5~15분 + refresh는 MCP 서버가 보관, 에이전트 자격은 mTLS 또는 DPoP로 발신자 구속, 교환 토큰에 `aud=memory-core`, `scope=store:sales:propose`, `act.client_id=sales-bot`. 테넌트는 토큰 issuer/claim에서만 결정하고 파라미터로 받지 않는다.

**A6. SSRF.** `inherit_acl` 검사 어댑터가 `source_refs.uri`를 그대로 fetch하면 내부망 탐색 도구가 된다. 시스템별 호스트 허용목록 + URL 정규화 + 리다이렉트 금지.

**A7. 사용자 없는 백그라운드 에이전트.** worker(만료, 정정 전파, 주간 정리)와 리뷰 에이전트는 `app.user_id`가 없다. 현재 함수는 예외를 낸다(E13). 서비스 principal(kind='agent', 전용 grant)과 별도 정책 경로가 필요하며, "관리 역할로 RLS 우회"는 금지(정리 작업이 범위를 넘는 정보 흐름이 되는 AgentCore 경고).

**A8. 레이트리밋·멱등성.** `propose`에 멱등 키(session_ref + content hash), principal별·store별 분당 한도. 설계서 11장의 "store당 일일 제안 한도"는 그대로 두면 **공격자가 한도를 채워 정당한 제안을 막는 DoS**가 된다 → 한도는 principal 단위, store 단위는 알림만.

### 3.3 메모리 오염 / LLM 계층 [분석]

**P1. note→fact 세탁 사슬 (N11).** `CHECK (kind='note' OR jsonb_array_length(source_refs)>0)`(`:88`)와 `origin DEFAULT 'internal'`(`:73`) 때문에 외부 문서를 읽은 에이전트가 지시문을 `note`로 제안하면 출처 없음·internal로 통과하고, 게이트의 "external+지시문" 규칙(설계서 7.1.2)은 origin이 internal이라 발화하지 않는다. 이후 다른 제안이 `memory://<note-id>`를 근거로 `fact`를 올리면 완전히 세탁된다(Misattribution 논문의 summary-mediated laundering). 수정: (1) `memory://` 근거의 origin을 보수적으로 상속(수정안 트리거에 구현: 하나라도 external이면 파생도 external), (2) note도 origin은 서버 결정, (3) 지시문 패턴 검사는 origin 무관하게 모든 제안에 적용하고 external이면 거부·internal이면 표시.

**P2. user store 자가 오염 (N12).** memory-hopping 논문의 핵심은 "사람이 승인한 일상 read/write만으로 전파"다. 이 설계에서 승인 없이 쓰이는 유일한 곳이 user store이고, 에이전트는 다음 세션에 그것을 읽는다. 따라서 user store는 **지속성(persistence) 확보 지점**이다. user store 쓰기도 결정적 게이트(비밀값·지시문)를 통과시키고, user store 메모리를 근거로 한 team 제안은 `origin=unverified`로 표시하며 user store 메모리만을 근거로는 fact를 올릴 수 없게 한다.

**P3. 게이트 우회.** 키워드 정규식은 NFKC 정규화·zero-width 제거·한국어 완곡 명령("~하도록 합니다", "~이 원칙입니다") 처리 없이는 무력하다(설계서 11장도 인정). 정규화 → 정규식 → 소형 분류기(지시문/정책 문서 형태 탐지) 3단으로 하되, **분류기 결과는 표시(flag)만, 거부는 결정적 규칙만**이라는 원칙은 유지.

**P4. 승인 피로의 역이용.** 20개의 무해한 제안 사이에 1개를 섞고, "묶음 승인"(설계서 11장)을 기다린다. 대책: 묶음 승인은 `origin=internal`·게이트 clean·`kind∈{note}`·supersede 아님인 것만; supersede/decision/org store는 항상 개별 승인 + 기존 항목과의 diff 표시; 승인된 것 중 무작위 5% 2차 검토.

**P5. supersede 사슬 공격.** 권위 있는 사실(예: 결제 승인 한도)을 "정정"하는 제안은 출처 링크만 그럴듯하면 통과하기 쉽다. 링크 존재만 검사하고 내용은 보지 않는다. (1) `inherit_acl` 어댑터가 있는 시스템은 **링크 내용의 해시/발췌를 서버가 가져와 카드에 첨부**, (2) supersede 대상이 curator가 직접 쓴 것이거나 `decision` kind면 2인 승인, (3) A→B→A 순환 검사.

**P6. 14일 자동 반려 = 사람 반려와 동일 상태.** `rejected`를 사람이 거부한 것으로 오해하면 재제안 억제·지표 오염이 생긴다. `rejected_by=system` 또는 `review_expired` 상태.

**P7. superseded/expired 읽기 허용**(`:168`)은 설계상 맞지만, API 기본값 "active만"은 앱 계층 약속일 뿐이다. 검색 함수(§3.1 N10 대책)에서 status 필터를 기본 강제하고 agent에게 status를 항상 노출.

### 3.4 운영 [분석]

**O1. inherit_acl 캐시.** "짧게 캐시"의 숫자를 정해야 한다(권장 60~300초, (user, uri) 키). 어댑터 오류·레이트리밋 시 **fail-closed(메모리 숨김 + "권한 확인 불가" 표시)**. 그리고 에이전트가 자체 커넥터 자격(서비스 계정)으로 원천을 읽는다면 교집합 원칙이 원천 읽기에도 적용돼야 한다(Asana의 "트리거한 사용자로 범위 고정").

**O2. SCIM 지연.** Entra ID SCIM 프로비저닝 주기는 40분, Okta는 수 초~수 분이지만 그룹 변경은 더 느리다. 퇴사 처리 후 최대 40분 + 토큰 수명 동안 접근이 남는다. 토큰 교환 시점에 `active` 재확인, 토큰 수명 ≤ 15분, IdP 이벤트 훅(Okta Event Hooks, SSE/CAEP)으로 즉시 비활성화.

**O3. 삭제가 닿지 않는 사본 (N14).** 본문은 다음에 남는다: PITR 베이스백업·WAL 아카이브, 논리 백업, 복제 슬롯, `log_statement`/느린 쿼리 로그의 INSERT 리터럴, Slack/Teams 카드(워크스페이스 보존 정책은 보통 무기한), LLM 리뷰어 제공자 로그(ZDR 계약 없으면 30일), 에이전트 런타임 트랜스크립트(Claude Code 로컬 세션, Hermes 메모리). "삭제 요청 대응" 범위를 계약적으로 정의하고(§6.6), Slack 카드에는 **제목+링크만** 싣고 본문은 앱에서 ephemeral로 보여주며, 삭제 시 카드도 API로 삭제.

**O4. PITR 복원 = 삭제 취소.** 복원 후 삭제 저널(외부 WORM에 (memory_id, deleted_at, reason))을 재적용하는 절차가 없으면 복원 자체가 규정 위반이 된다.

**O5. 리오그·매트릭스 조직.** 사람이 5개 팀에 속하고, 그룹이 이름을 바꾸고, 팀이 합쳐진다. group principal이 SCIM에서 삭제되면 `ON DELETE CASCADE`(`:27`, `:53`)로 grant가 소리 없이 사라진다(감사 흔적 없음). grant 변경도 append-only 이력이 필요하다.

**O6. 법적 보존(legal hold).** 소송·감사 중에는 삭제가 금지된다. `memory.delete`가 무조건 redact하면 반대 방향 규제 위반. store/tenant 단위 hold 플래그.

---

## 4. 설계 비평: 핵심 추상이 맞는가

**store = 경계 — 맞다. 단, 평면 구조와 "요약 = 사본"을 인정해야 한다.**

- 실제 조직에서는 "이 사실은 팀 리드만"이 바로 나온다. 행 단위 ACL을 추가하고 싶어질 텐데 **하지 말고 store를 더 만들어라**(Databricks·Claude 모두 store가 경계). 대신 store 폭발을 감당할 **부모 상속(org ⊃ team ⊃ project, 상위 store의 reader는 하위 store의 reader)**과 자동 프로비저닝(SCIM 그룹 ↔ store)이 필요하다.
- "링크만, 복사 안 함"은 절반만 맞다. 본문은 원천의 요약 = 정보의 사본이다. 진짜 불변식은 **청중 포함(audience containment): store의 reader 집합 ⊆ 모든 출처의 reader 집합**이다. `inherit_acl` 조회는 읽는 사람이 원천을 볼 수 있는지만 보지만, 그 전에 "더 좁은 집단만 보는 원천을 더 넓은 store에 요약해 올리는" 행위 자체를 승인 시점에 경고해야 한다(AkasicMEM의 계보 교집합이 말하는 것). `memory://`로 타 store를 인용하는 경우도 동일(수정안은 못 읽는 메모리 인용을 막지만, 두 store를 다 보는 사람이 옮기는 경로는 curator 경고로만 대응 가능).
- 민감도 라벨(public/internal/confidential/restricted)이 없다. 컴플라이언스 매핑과 DLP, 카드 표시, 보존 정책이 모두 이 라벨에 걸린다. store 속성으로 두고 메모리는 상속.

**제안/승인 — 맞다(MAPLE-Guard에서 promotion gate 제거 시 성능 하락 최대). 단, 단일 승인·사람 병목·자기 승인이 문제.**

- 직무 분리: 제안자 ≠ 승인자(N15). org store·decision kind는 2인.
- 승인은 "내용 승인"이지 "출처 검증"이 아니다. curator가 출처를 열어보지 않는다는 전제로 설계해야 한다 → 서버가 출처 발췌를 첨부.
- 승인율·대기 시간을 설계 지표로 삼는 것은 좋다. 그러나 **"저위험 kind는 리뷰 에이전트 통과 시 자동 승인"(설계서 10장)은 신뢰 점수 없이 열면 안 된다.** MAPLE-Guard식 provenance trust(에이전트별 승인 이력에 따른 점수, 실패 시 비대칭 감점)를 먼저 쌓고, 자동 승인은 trust ≥ 임계 + internal + note에 한정.

**교집합 권한 — 맞다. 그러나 선형 역할 격자와 관리 부담이 문제.**

- `least()`는 reader<contributor<curator가 전순서일 때만 성립한다. "reader + delete(개인정보 담당자)" 같은 역할이 생기는 순간 깨진다. 역할을 **권한 비트 집합**으로 바꾸고 교집합을 `&`로 계산하면 확장이 쉽다.
- 에이전트마다 store마다 grant를 주면 N_agents × N_stores 관리가 된다. 에이전트에는 **상한 역할(ceiling)** 속성 하나 + 선택적 store 거부목록이 현실적이다. 세션 토큰의 store 바인딩(A4)이 세 번째 축이다.
- "사용자 권한 ∩ 에이전트 권한"에 **세션 목적(purpose)**이 빠져 있다. 같은 사용자+같은 봇이라도 "영업 보고서 작성" 세션이 HR store를 읽을 이유가 없다. 토큰 scope가 답이다.

**링크 우선 — 맞다. 그러나 출처 링크 신뢰 모델이 없다.** 어떤 시스템의 링크는 권위(ERP, 결재), 어떤 것은 아무나 쓰는 위키다. 종합 문서 1.5절의 "권위를 반영한 충돌 해결"이 필요하다: 시스템별 authority 등급을 두고, 낮은 등급 출처가 높은 등급 사실을 supersede하려면 2인 승인.

**규모와 현실 조직에서 깨지는 지점**

- N9/N10(정책 비용, 인덱스 불가)은 수천 행에서 이미 체감된다.
- `memory_version`이 무한 증가, 파티셔닝·아카이브 없음. 테넌트/월 단위 파티션 + 콜드 스토리지 export(Claude의 30일 보관과 같은 문제를 스스로 만들지 말 것).
- Slack 카드 기반 승인은 하루 수십 건까지다. 검토 대기함 UI(diff, 묶음, 필터)가 없으면 curator는 카드를 무시한다.
- 상태 기계·버전·감사가 앱 코드 의존이면 **두 번째 클라이언트(관리 UI, worker, 마이그레이션 스크립트)**가 생기는 순간 어긋난다. DB 트리거로 내려야 한다(수정안).
- `jsonb source_refs`는 FK·인덱스·ACL 상속이 모두 약하다. `memory_ref(memory_id, kind, uri, ref_memory_id, system, inherit_acl)` 테이블로 정규화.

---

## 5. 수정안 검증 결과 (`fix.sql` + `fixtest.sql`, Postgres 16)

| 테스트 | 내용 | 결과 |
|---|---|---|
| F1 | Bob(hr curator)+sales-bot | 어느 store도 권한 없음(NULL-safe 교집합) ✔ |
| F2 | Alice+bot / Carol+bot / Carol | contributor / contributor / curator ✔ |
| F3 | 비활성 Eve, group-as-user, agent-as-user | 모두 `begin_request` 거부 ✔ |
| F4 | 세션 레벨 SET으로 위조·누수된 컨텍스트 | 0행 ✔ |
| F5 | created_by=Carol, status=active, tenant=타사, hash=임의로 INSERT | 트리거가 세션값·proposed·서버 해시로 덮어씀 ✔ |
| F6 | Dave+bot / Alice 단독의 proposed 가시성 | 0 / 1 ✔ |
| F7 | HR 메모리를 supersedes·memory://로 인용 | 존재/비존재 동일 오류 ✔ |
| F8 | deleted_hash·memory_version·store_grant 직접 쓰기, HR 버전 열람 | 모두 거부 / 0행 ✔ |
| F9 | 승인→origin 세탁→created_by 변경→삭제→소생→체인 검증 | 자동 버전 2, 세탁·변경·소생 차단, 스냅샷 redact + deleted_hash 등록, 체인 valid ✔ |
| F10 | 삭제된 본문(공백 변형) 재제안 | HMAC 정규화 해시로 차단 ✔ |
| F11 | 200k행 count(*) | 8,067ms → 83ms ✔ |

수정안의 핵심 SQL(전문은 `exp/fix.sql`):

```sql
-- 1) 요청 컨텍스트: DB가 principal 검증 후 LOCAL 설정, xid 바인딩
CREATE FUNCTION app_sec.begin_request(p_user uuid, p_agent uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE t uuid;
BEGIN
  SELECT tenant_id INTO t FROM principal WHERE id = p_user AND kind = 'user' AND active;
  IF t IS NULL THEN RAISE EXCEPTION 'unknown or inactive user' USING ERRCODE='28000'; END IF;
  IF p_agent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM principal WHERE id=p_agent AND kind='agent' AND active AND tenant_id=t)
    THEN RAISE EXCEPTION 'unknown or inactive agent' USING ERRCODE='28000'; END IF;
  PERFORM set_config('app.user_id', p_user::text, true);
  PERFORM set_config('app.agent_id', coalesce(p_agent::text,''), true);
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM set_config('app.ctx_xid', pg_current_xact_id()::text, true);
END $$;

-- 2) 실효 권한 집합 (NULL-safe 교집합, archived/tenant 반영). 정책에서는 IN (SELECT ...) 로 1회 평가
CREATE FUNCTION app_sec.my_store_roles() RETURNS TABLE (store_id uuid, role store_role) LANGUAGE sql STABLE AS $$
  WITH ctx AS (SELECT app_sec.ctx_user() u, app_sec.ctx_agent() a, app_sec.ctx_tenant() t),
  ur AS (SELECT g.store_id, max(g.role) role FROM ctx, store_grant g
          WHERE ctx.u IS NOT NULL AND g.tenant_id = ctx.t AND g.principal_id IN (SELECT principal_closure(ctx.u)) GROUP BY 1),
  ar AS (SELECT g.store_id, max(g.role) role FROM ctx, store_grant g
          WHERE ctx.a IS NOT NULL AND g.tenant_id = ctx.t AND g.principal_id IN (SELECT principal_closure(ctx.a)) GROUP BY 1)
  SELECT ur.store_id, CASE WHEN ctx.a IS NULL THEN ur.role ELSE least(ur.role, ar.role) END
  FROM ctx, ur JOIN store s ON s.id = ur.store_id AND s.archived_at IS NULL
  LEFT JOIN ar ON ar.store_id = ur.store_id
  WHERE ctx.a IS NULL OR ar.role IS NOT NULL
$$;

-- 3) INSERT 정책: 저자·대리·테넌트·상태를 세션에 묶음
CREATE POLICY memory_propose ON memory FOR INSERT WITH CHECK (
  status = 'proposed' AND version = 1 AND tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT r.store_id FROM app_sec.my_store_roles() r WHERE r.role >= 'contributor')
  AND created_by = coalesce(app_sec.ctx_agent(), app_sec.ctx_user())
  AND on_behalf_of IS NOT DISTINCT FROM (CASE WHEN app_sec.ctx_agent() IS NULL THEN NULL ELSE app_sec.ctx_user() END));

-- 4) 감사 체인 (append-only + redact 가능: 해시는 snapshot_hash 위에 계산)
row_hash = sha256(prev_hash | memory_id | version | op | actor_id | snapshot_hash | at)
```

수정안에 **남아 있는** 한계: 탈취된 앱 서버 대응(§6.2), 백그라운드 에이전트 경로, 검색 함수(N10), 역할 비트 집합, 청중 포함 검사, 직무 분리는 PoC에 없다.

---

## 6. 프로덕션 로드맵

### 6.1 P0 — 파일럿 전 필수

1. **권한 모델 재작성**: `fix.sql`의 1)~4) 적용. 역할 분리(`app_owner` 소유 / `app_rw LOGIN NOBYPASSRLS NOINHERIT`, `FORCE ROW LEVEL SECURITY`). app_rw는 `memory` INSERT/UPDATE와 SELECT만.
2. **트리거로 내린 불변식**: 저자/테넌트 바인딩, 상태 기계, 불변 컬럼, origin 단방향, 버전 자동 증가, 버전 기록 자동 작성, 삭제 시 redact + HMAC deleted_hash.
3. **테넌트 복합 FK + 정책 tenant 조건** (단일 테넌트라도).
4. **서버 결정 메타데이터**: origin(출처 허용목록), inherit_acl(시스템별), content_hash, gate_result. 클라이언트 값은 무시.
5. **note 세탁 차단**: 지시문 검사를 origin 무관 적용, memory:// 근거 taint 상속, user store 메모리만을 근거로 한 fact 금지.
6. **검색/계보 경로 성능**: SECURITY DEFINER 검색 함수(동일 `my_store_roles()` 필터) 또는 LEAKPROOF 결정 + `memory_ref` 정규화 테이블.
7. **승인 봇 신원**: curator 주체 토큰으로 호출(A1), 카드에 본문 대신 제목+링크(O3), 직무 분리(제안자≠승인자).
8. **감사 체인 + 외부 앵커**: 일 1회 테넌트별 Merkle root를 S3 Object Lock(WORM) 또는 외부 로그 서비스에 기록, `verify_chain` worker.
9. **삭제 의미 정의서**: 무엇이 지워지고(본문, 스냅샷, 카드) 무엇이 남는지(메타, 해시, 백업 N일) 문서화. 파일럿 참여자에게 고지.
10. **테스트 게이트**: §6.3의 pgTAP + property 테스트가 CI에서 통과해야 마이그레이션 머지.

### 6.2 P1 — GA 전

- **authN/Z**: OIDC(사용자) + 클라이언트 자격(에이전트) → **RFC 8693 token exchange**로 `sub=user, act={client_id: agent}, aud=memory-core, scope=store:<slug>:<role>` 발급. MCP 서버는 교환 토큰만 수락. 가능하면 **DB 측 토큰 검증**(`begin_request(jwt)`가 pgcrypto/pgjwt로 서명 검증, 키는 app_rw가 못 읽는 테이블) → 탈취된 앱 서버가 신원을 만들어낼 수 없게. 에이전트 자격은 mTLS/DPoP.
- **백그라운드 에이전트**: 서비스 principal + 전용 정책(읽기는 grant로, 쓰기는 proposed만, 정리 결과는 새 store로 출력).
- **역할 비트 집합**으로 전환(reader/propose/approve/delete/grant), 교집합 = AND.
- **store 상속·자동 프로비저닝**: SCIM 그룹 ↔ team store, 사용자 ↔ user store, grant 변경 이력 테이블.
- **민감도 라벨·DLP**: store 속성, 카드·검색 결과에 표시, 게이트 PII 규칙을 라벨별로 차등.
- **승인 UX**: 검토 대기함(diff, 출처 발췌, 게이트 결과, 묶음 승인 제한 규칙 P4), 무작위 2차 검토, 2인 승인(org/decision/supersede of curator-authored).
- **trust 점수**: 에이전트·사용자별 승인/반려 이력 기반, 자동 승인 옵션은 그 이후.
- **보존/삭제**: 암호화 파쇄(메모리별 DEK, 테넌트 KEK; 삭제 = DEK 파기 → 백업 복원해도 본문 복호 불가), 백업 보존 ≤ 30일, 로그에서 본문 리터럴 제거(`log_statement=none`, 바인드 파라미터 로깅 금지), 삭제 저널 WORM + 복원 후 재적용 절차, legal hold.
- **멀티테넌시**: 토큰 issuer → tenant, 테넌트별 KEK·쿼터, 규제 고객은 DB 분리 옵션. `memory_version` 테넌트/월 파티션.
- **관측성·SLO** (§6.4), **DR** (§6.7).

### 6.3 P2 — 이후

- 청중 포함 검사 자동화(원천 ACL 조회로 store reader ⊆ source reader 근사), 정정 전파 UI, 권위 등급 기반 충돌 규칙, 하이브리드 검색(pgvector, 같은 정책 함수 재사용), Graphiti projection, SOC2 Type II.

### 6.4 테스트 전략

- **pgTAP 회귀**: 이 보고서의 E/F 시나리오 전부를 고정 테스트로.
- **속성 기반 RLS 테스트**(Hypothesis + psycopg): 무작위 tenant/principal/group/grant/memory 상태를 생성 → 파이썬 오라클이 "보여야 할 집합"을 계산 → RLS 결과와 비교. 메타모픽 불변식: grant 추가는 가시성을 줄이지 않는다, 제거는 늘리지 않는다, **에이전트를 붙이면 가시성이 절대 늘지 않는다**, 테넌트가 다르면 항상 0, 비활성 principal은 항상 0.
- **적대적 오염 평가**(주간 CI): memory-hopping 재현(외부 문서 → 제안 → 다른 에이전트 읽기), SND식 "정책 문서" trust laundering, note→fact 사슬, 동형문자/zero-width 게이트 우회, 승인 홍수 + 묶음 승인. 지표: 공격 성공률(ASR), 게이트 오탐률, curator가 잡은 비율.
- **MCP 퍼징**: slug 혼동, 거대 source_refs, memory:// 순환, uuid 아닌 memory://.
- **복원 훈련**: 분기 1회 PITR 복원 + 삭제 저널 재적용 + 체인 검증.

### 6.5 관측성·SLO

- 지표: 제안 수/승인율/반려율/자동만료율(store·principal별), 승인 대기 p50/p90, 게이트 거부 사유 분포, **RLS 0행 UPDATE(승인이 조용히 실패한 경우)**, `begin_request` 거부 수(AWS `NamespaceResolutionFailure`에 해당하는 "신원 없는 요청"), inherit_acl 어댑터 오류율·fail-closed 건수, 체인 검증 실패, memory.get 재사용률, SCIM 동기화 지연.
- SLO(파일럿): 읽기 p95 < 300ms, propose p95 < 1s(게이트 포함), 승인 결정 p90 < 72h, 가용성 99.9%, 삭제 요청 처리 ≤ 5일(개인정보보호법 파기 기준), 체인 검증 100%.
- 감사 로그는 SIEM으로 스트리밍(grant 변경, 승인, 삭제, begin_request 거부).

### 6.6 데이터 보존·삭제·컴플라이언스

| 요구 | 대응 |
|---|---|
| GDPR Art.17 / 개인정보보호법 §21 파기 | 암호화 파쇄 + redact + Slack 카드 삭제 + LLM 제공자 ZDR 계약. 감사 메타는 "법적 의무/정당한 이익"으로 보존 근거 문서화 |
| 개인정보 안전성 확보조치 기준 접속기록 | 접속기록 1년(민감·대규모는 2년) 보관, 월 1회 점검 → `begin_request` 로그가 접속기록 |
| 국외 이전(§28조의8) | LLM 리뷰어가 해외 API면 고지·동의 또는 국내 리전 |
| SOC2 CC6/CC7 | 역할 분리, 변경 관리(마이그레이션 리뷰), 로깅·모니터링, 침해 대응 절차 |
| ISO 27001 A.5.15/A.8.x | 접근 통제 정책 = store grant 절차, 로그 보호 = 해시 체인+WORM |
| DSAR | `created_by`/`on_behalf_of`/`actor_id` 기준 export 쿼리 준비 |

### 6.7 마이그레이션·DR·성능

- 마이그레이션: sqitch/Flyway, expand/contract, **RLS·트리거 변경은 보안 리뷰 필수 + property 테스트 통과**, 정책을 버전 태그로 관리.
- DR: PITR(RPO 5분), 교차 리전 복제본(RTO 1h), 백업 암호화(테넌트 KEK), 복원 후 절차 = 삭제 저널 재적용 → 체인 검증 → 앵커 대조.
- 성능: `my_store_roles()` 1회 평가(검증됨), 검색 함수, `store_grant(principal_id)`·`group_member(member_id)` 인덱스, `memory_version` 파티션, 한국어 토크나이저 결정.

### 6.8 파일럿 성공 지표 (2~4주, 팀 1개)

- 활성 메모리 ≥ 50, 에이전트 제안 비율 ≥ 60%, 승인율 40~80%(너무 높으면 고무도장, 낮으면 게이트 문제), 승인 대기 p90 ≤ 72h, 자동만료 ≤ 20%
- 재사용: 활성 메모리당 주간 get ≥ 1, 에이전트 산출물의 memory 인용률
- 안전: 오염 훈련 5회 중 curator/게이트가 잡은 비율 ≥ 4, RLS property 테스트 0 실패, 삭제 요청 1건 end-to-end ≤ 5일
- 비용: curator 1건당 검토 시간 ≤ 2분

---

## 7. 소유자가 결정해야 할 5가지

1. **DB가 누구를 믿을 것인가**: 앱 서버의 세션 변수 주장(현재) vs. DB 안에서 토큰 서명 검증. 후자는 탈취된 앱 서버·SQL 인젝션에 대한 유일한 실질 방어이며, 복잡도 비용이 있다. 파일럿은 전자+xid 바인딩, GA는 후자를 권고.
2. **origin/taint를 누가 정하나**: 에이전트 선언(현재) vs. 서버 결정(출처 허용목록 + 세션 taint). 서버 결정은 "external 과다 표시"로 승인 부담이 늘지만, 그것 없이는 memory-hopping과 세탁 사슬을 막을 수 없다. 서버 결정을 권고.
3. **승인 모델의 강도**: 단일 curator + user store 자동 승인(현재) vs. 직무 분리 + org/decision 2인 + user store도 게이트 통과 + 자동 승인은 trust 점수 이후. 후자를 권고하되 파일럿에서 승인 대기 지표로 검증.
4. **"삭제"의 계약적 의미**: 본문 redact만(현재) vs. 암호화 파쇄로 백업까지 무효화 + Slack·로그·LLM 로그 범위 포함. 규제 대상 데이터를 다룰 계획이라면 후자 없이는 "삭제 요청에 대응한다"고 말할 수 없다.
5. **호스팅·테넌시·빌드 범위**: 공유 Postgres RLS 멀티테넌트 vs. 고객별 DB, 그리고 Postgres 직접 구축 vs. 관리형 store(Claude memory store / AgentCore) 위에 이 설계를 거버넌스 계층으로 얹기. 관리형은 버전 보관 30일·RLS 부재 같은 한계가 있고, 직접 구축은 이 보고서의 P0/P1을 전부 떠안는다. 파일럿 대상 조직의 규제 수준이 결정한다.

---

### 부록: 실험 파일

- `exp/exp1.sql`, `exp/exp2.sql` — N1~N8, X1/X4/X6 재현
- `exp/exp_perf.sql` — N9 (200k행)
- `exp/leak.sql` — N10 (LEAKPROOF와 GIN)
- `exp/fix.sql` — 수정안 PoC, `exp/fixtest.sql` — F1~F11 검증
