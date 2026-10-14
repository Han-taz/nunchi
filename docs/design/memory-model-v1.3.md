# 메모리 모델 v1.3: 사람 없는 쓰기 경로 (자율 큐레이션)

상태: 제안. 소유자 결정(2026-10-14)을 구현할 설계다. v1.1(`team-memory-core-v1.1.md`)의 5절 승인 모델 B(위험 등급표, 정족수, 승인 카드, 신뢰 점수)와 v1.2(`memory-model-v1.2.md`)의 3절 "교체 승인", 4절 확인 카드, 7절 큐레이터 카드를 대체한다. 저장, 권한(RLS, 사용자 ∩ 에이전트), 감사 해시 체인, 쓰기 게이트, 검색은 그대로 둔다.

## 1. 결정과 근거

소유자 결정은 하나다. 쓰기 경로에 사람이 없다. 승인 카드, 큐레이터 DM, 사람에게 넘기는 보류함, 매일 해야 하는 검토가 없다. 무엇을 기억하고, 언제 확정하고, 언제 바꾸고, 언제 철회할지는 nunchi가 대화를 근거로 정한다. 사람과 에이전트는 대화로, 또는 MCP `decide`로 결과를 되돌린다. 승인 UI는 없다.

이 결정을 낳은 증거는 agent-desk 시뮬레이션(Mattermost 채널에서 에이전트 6명이 약 2시간 대화)의 로컬 스택이다.

| 관찰 | 원인 (develop 코드) |
|---|---|
| `proposed` 결정 6건이 쌓였다. 그중 4건이 같은 결정 "스타일: CSS Modules + CSS 커스텀 프로퍼티"다 | `kind = decision`은 위험 등급표 3행에서 언제나 `two_curators`이고 최초 상태가 `proposed`다 |
| 4건 중 3건은 키가 같다 (`foundation.md`, `스타일 방식`) | 키 판정 트리거 `memory_key_decide`와 유일 인덱스 `memory_live_key_uidx`는 `active`와 `provisional`만 본다. `proposed`끼리는 같은 키로 몇 개든 쌓인다 |
| 1건은 주체가 다르다 (`프론트 스타일링 방식`) | 추출기 후보 목록(`capture/service.py::_candidates`)도 `active`와 `provisional`만 검색한다. 먼저 생긴 `proposed` 행을 추출기가 보지 못해 주체를 새로 지었다 |
| 승인 카드 12장이 나갔다 (기억 6건 × 큐레이터 2명) | U26 `send_proposal_cards`. 한 명이 6장을 눌렀고 결과는 모두 `pending_quorum:1/2`다. 나머지 6장은 페르소나 계정(김민지)에게 갔다 |

마지막 줄은 별도의 문제도 드러낸다. 페르소나가 store curator라서 카드 DM을 받았다. 이 DM은 페르소나 격리 규칙 밖의 정보 통로다. v1.3에서 카드가 없어지면 이 통로도 없어진다.

## 2. 상태

| 상태 | 뜻 | 검색 기본값 | 키 유일성에서 |
|---|---|---|---|
| `provisional` | 저장했지만 합의 증거가 아직 없다. 라벨 "미확정" | 나온다 (가중치 0.7) | 살아 있음 |
| `active` | 합의 증거가 있거나, 반박 없이 승격 기간이 지났다 | 나온다 | 살아 있음 |
| `challenger` (새 값) | 살아 있는 행과 같은 키, 다른 값이고 합의 증거가 없다. 라벨 "변경 제안 (미확정)" | 살아 있는 행에 붙어서 나온다 | 키마다 최대 하나, 살아 있음과 별도 |
| `superseded` | 같은 키의 새 값으로 교체됐다. `valid_to`가 있다 | `as_of`로만 | 아님 |
| `expired` | `valid_to`가 지났거나, active였던 기억을 대화가 철회했다 | `as_of`로만 | 아님 |
| `rejected` | provisional이나 challenger였던 기억을 대화가 철회했다. 사실이었던 적이 없다 | 나오지 않는다 | 아님 |
| `deleted` | 관리자 삭제(본문 파기). 쓰기 경로가 아니다 | 나오지 않는다 | 아님 |
| `proposed` | 쓰지 않는다. 10절의 이전 뒤에는 행이 없다 | | |

`proposed`는 enum 값으로만 남긴다. PostgreSQL에서 enum 값을 빼려면 타입을 새로 만들고 그 타입을 쓰는 열, 함수, 정책을 모두 다시 만들어야 한다. 그 비용에 비해 얻는 것이 없다. 대신 `CHECK (status <> 'proposed')`를 `NOT VALID`로 걸고, 이전(10절)이 끝난 뒤 `VALIDATE`한다. 전이 표에도 `proposed`로 들어가거나 나가는 행이 없다.

`challenger`는 새 enum 값이다(`ALTER TYPE ... ADD VALUE`, 비용 작음). 13절의 1번이 이 상태가 필요한 이유다.

## 3. 데이터 모양

### 3.1 바뀌는 열과 표

| 대상 | 변경 |
|---|---|
| `memory.basis` (새 열, enum `promotion_basis`) | 현재 상태에 이른 근거. `agreed`(대화 합의), `stated`(한 사람의 진술), `timer`(승격 기간 경과), `agent`(MCP `decide`), `user_store`(개인 store), `migrated`(9절) |
| `memory.promote_at` (새 열, timestamptz) | provisional과 challenger가 반박 없이 active가 되는 시각. 그 외 상태에서는 NULL |
| `memory.tier`, `approval_tier`, `approval_tier_rule`, `app_sec.risk_tier()` | 삭제. 최초 상태는 등급이 아니라 합의 증거가 정한다 (4절) |
| `proposer_trust`, `trust_rule`, `app_sec.quorum()` | 삭제. 신뢰 점수는 등급표의 입력이었고 등급표가 없어진다 |
| `memory_challenger_uidx` (새 부분 유일 인덱스) | `(store_id, subject_id, attribute) WHERE status = 'challenger'`. 키마다 열린 변경 제안은 하나다 |
| `memory_live_key_uidx` | 그대로. 키마다 `active` 또는 `provisional` 행은 하나다 |
| `store_autonomy(store_id PK, promote_after interval NOT NULL DEFAULT '24 hours')` (새 표) | store별 승격 기간. 행이 없으면 24시간. provisional 승격과 challenger 교체가 같은 값을 쓴다 |
| `memory_transition` | 기본 키를 `(from_status, to_status, op)`로 바꾸고, `by_role` 하나 대신 허용 역할 배열 `by_roles transition_role[]`을 둔다. 역할은 `contributor`, `system`, `curator`(삭제만)다. 행은 5.2의 표가 전부다 |
| `memory_evidence` (새 표, append-only) | 6절 |
| `memory_op` | `promote`(타이머 승격)를 더한다. `auto_activate`, `approve`, `reject`는 새로 쓰이지 않고 기존 버전 기록에만 남는다 |

### 3.2 추출기 출력

`ProposalDraft`에 세 가지가 붙는다.

```text
consensus: "agreed" | "stated"
evidence:  tuple[int, ...]     # 창 안 게시물 번호(0부터). 이 항목을 말하거나 동의한 게시물
relation:  new | same_as | updates | retracts | not_worth   # retracts 가 새로 생긴다
```

`render()`는 지금 `이름: 본문` 줄을 낸다. v1.3에서는 줄마다 번호를 붙인다(`[3] yuna.choi: ...`). 모델은 번호만 고른다. 번호를 실제 게시물 id, permalink, 작성자 id로 바꾸는 일은 서버가 Mattermost에서 받은 데이터로 한다. 모델이 작성자나 링크를 지어낼 길은 없다.

`retracts`는 후보 id를 가리킨다. "그거 아니야", "취소", "번복", "없던 걸로" 같은 정정이 그 후보를 향할 때 쓴다.

## 4. 합의 판정

### 4.1 규칙

추출기가 창 단위로 `consensus`를 고르고, 서버가 그 주장을 확인한다. 서버가 확인하지 못한 `agreed`는 `stated`로 내린다.

| 경우 | 서버 확인 조건 | 결과 |
|---|---|---|
| 두 사람 이상의 동의 | `evidence` 게시물의 서로 다른 작성자가 2명 이상 (봇 제외) | `agreed` |
| 한 사람의 결정 선언에 반대가 없음 | `evidence` 게시물 하나가 결정 표지어(`결정`, `확정`, `합의`, `하기로 했`, `으로 가기로`)를 포함하고, 그 게시물 뒤 같은 창에 다른 작성자의 게시물이 하나 이상 있다 | `agreed` |
| 그 밖 | | `stated` |

두 번째 행의 "뒤에 다른 작성자의 게시물이 하나 이상" 조건은 브리프에 없던 것이다. 이유는 13절의 2번에 적었다.

창 안에서 반대가 있었던 항목은 기억하지 않는다. 추출 프롬프트의 "합의 전 토론은 건너뛴다" 규칙이 그대로 이를 맡는다.

### 4.2 단일 메시지 경로

| 경로 | consensus |
|---|---|
| 📌 반응, 핀 찍은 사람 ≠ 게시물 작성자 | `agreed` (두 사람) |
| 📌 반응 또는 @멘션, 작성자 본인 | `stated` |
| MCP `remember` | `stated` |
| 개인 store(`store.kind = user`) | 언제나 active, `basis = user_store` |

## 5. 상태 기계

### 5.1 쓰기 판정 (`app_sec.remember`)

쓰기는 SECURITY DEFINER 함수 `app_sec.remember(draft, consensus, evidence)` 하나로 한다. 지금 `INSERT` 트리거 셋(`memory_key_decide`, `memory_set_tier`, reconfirm용 `RETURN NULL`)에 흩어진 판정이 이 함수의 표 하나로 모인다. 함수는 키의 살아 있는 행과 열린 challenger를 `FOR UPDATE`로 잠그고 아래 표에서 첫 일치 행을 실행한다. `relation = retracts`인 항목은 9, 10행만 본다. "같은 값"은 지금의 판정(정규화한 `value`, 존칭 제거, 긴 값은 판정 모델 `ValueJudge`)과 같다.

| # | 키의 현재 모습 | 새 항목 | 동작 | 결과 |
|---|---|---|---|---|
| 1 | 살아 있는 행 없음 | `agreed` | 새 행 active | `created` |
| 2 | 살아 있는 행 없음 | `stated` | 새 행 provisional, `promote_at = now() + promote_after` | `created` |
| 3 | 같은 값 (provisional) | 기존 증거에 없는 작성자의 증거 | 기존 행 provisional → active (`confirm`, `basis = agreed`) | `confirmed` |
| 4 | 같은 값 (active 또는 provisional) | 그 밖 | `last_confirmed_at` 갱신, 증거 기록 (`reconfirm`). 열린 challenger가 있고 이 증거가 challenger 생성 뒤의 게시물이면 challenger → rejected (사유 `reaffirmed`) | `reconfirmed` |
| 5 | 같은 값이 열린 challenger의 값 | `agreed`, 또는 challenger 증거에 없는 작성자 | challenger → active, 살아 있는 행 → superseded | `superseded` |
| 6 | 같은 값이 열린 challenger의 값 | 그 밖 | challenger에 증거 기록 (`reconfirm`). `promote_at`은 그대로 | `reconfirmed` |
| 7 | 다른 값 | `agreed` | 살아 있는 행 → superseded(`valid_to = 오늘`), 새 행 active, `supersedes_id` 설정. 열린 challenger가 있으면 → rejected | `superseded` |
| 8 | 다른 값 | `stated` | 새 행 challenger, `conflict_with = 살아 있는 행`, `promote_at = now() + promote_after`. 열린 challenger가 있으면 → rejected (사유 `replaced`) | `challenged` |
| 9 | `relation = retracts`, 대상 provisional 또는 challenger | | 대상 → rejected | `retracted` |
| 10 | `relation = retracts`, 대상 active | | 대상 → expired, `valid_to = 오늘` | `retracted` |

키 없는 note는 1, 2, 9, 10행만 탄다. 같은 note 판정은 U27(PR #73)의 `reconfirm_duplicate_note`가 4행 자리를 맡는다.

전이는 같은 트랜잭션 안에서 이전 행을 먼저 `superseded`로 옮긴 뒤 새 행을 `active`로 올린다(5, 7행). 살아 있는 행이 9, 10행으로 철회되거나 `valid_to`가 지나 만료되면, 그 키의 열린 challenger가 키의 임시 살아 있는 행이 된다(`challenger → provisional`, `promote`). `promote_at`과 증거는 그대로이고 `conflict_with`만 비운다. 키마다 살아 있는 행은 여전히 하나다. 외부 출처이거나 지시문 표시가 붙은 기억은 `promote_at`을 두지 않는다. 시간으로 승격하지 않고 3행과 5행의 합의로만 active가 된다(13절의 4번).

동시에 두 창이 같은 빈 키에 쓰면 두 번째 INSERT가 `memory_live_key_uidx`에서 `23505`를 받는다. `remember()`는 한 번 다시 판정하고, 이때는 3행이나 4행이 맞는다. 같은 창은 `inbound_event` 선점으로 한 번만 처리하고, 같은 게시물 증거는 6절의 유일 제약으로 한 번만 센다. 그래서 재시도해도 결과가 같다.

### 5.2 전이 표

`memory_transition`의 행은 아래가 전부다. 표에 없는 `(from, to, op)`는 `P0001`이다. `contributor`는 그 store에 contributor 이상인 요청 컨텍스트(digest 봇, MCP를 쓰는 에이전트나 사람)이고, `system`은 컨텍스트 없는 워커다.

| from | to | op | by_roles | 언제 |
|---|---|---|---|---|
| provisional | active | `confirm` | contributor | 5.1의 3행, MCP `decide confirm` |
| provisional | active | `promote` | system | 승격 기간 경과 (7절) |
| provisional | rejected | `retract` | contributor | 5.1의 9행, MCP `decide retract` |
| provisional | superseded | `supersede` | contributor, system | 5.1의 5행과 7행(contributor), challenger 승격(system, 7절) |
| active | superseded | `supersede` | contributor, system | 위와 같다 |
| active | expired | `retract` | contributor | 5.1의 10행, MCP `decide retract` |
| active | expired | `expire` | system | `valid_to` 경과 |
| challenger | active | `confirm` | contributor | 5.1의 5행, MCP `decide confirm` |
| challenger | active | `promote` | system | 승격 기간 경과 (7절) |
| challenger | rejected | `retract` | contributor | 5.1의 4, 7, 8, 9행, MCP `decide retract` |
| challenger | provisional | `promote` | contributor, system | 5.1의 고아 challenger (아래), 만료 때의 워커 |
| active, provisional, challenger, superseded, expired, rejected | deleted | `delete` | curator | 관리자 삭제 |

`curator`는 삭제 하나에만 남는다. 삭제는 본문을 지우는 관리 작업이지 무엇을 기억할지 정하는 일이 아니다.

같은 `(from, to)`에 op가 둘인 경우(`active → expired`의 `retract`와 `expire`)가 있으므로 표는 op를 보고 행을 고른다. 전이를 일으키는 함수(`remember`, `promote_due`, `decide`)가 트랜잭션 로컬 설정 `app.op`에 op를 넣는다. `memory_bu` 트리거는 `(OLD.status, NEW.status, app.op)`로 행을 찾고, 현재 컨텍스트(요청 컨텍스트가 있으면 contributor, 없으면 system)가 `by_roles`에 드는지 본다. `app.op` 없이 상태를 바꾸는 `UPDATE`는 `42501`이다. 버전 기록의 op도 같은 값을 쓴다.

### 5.3 그림

```text
새 키, agreed ───────────────────────────▶ active
새 키, stated ──▶ provisional ──confirm / promote──▶ active
                  provisional ──retract──▶ rejected
                  active ──retract──▶ expired          active ──expire (valid_to)──▶ expired

같은 키 다른 값, agreed ──▶ 새 행 active, 옛 행 superseded (즉시)
같은 키 다른 값, stated ──▶ challenger ──confirm / promote──▶ active, 옛 행 superseded
                            challenger ──retract / replaced / reaffirmed──▶ rejected
```

## 6. 증거

모든 전이와 reconfirm은 근거 메시지를 남긴다. 누구든 `history`와 `as_of`로 왜 이 값이 지금 이 상태인지 따라갈 수 있다.

```text
memory_evidence(
  id bigint PK,
  memory_id uuid, version integer, op memory_op,   -- 그 증거가 만든 memory_version 행
  uri text,            -- 게시물 permalink 또는 memory://<id>
  post_id text,        -- 플랫폼 게시물 id. MCP 는 NULL
  author text,         -- 플랫폼 사용자 id (Mattermost user id). MCP 는 principal id
  author_name text,    -- 기록 시점의 표시 이름
  said_at timestamptz, -- 게시물 작성 시각
  basis promotion_basis,
  UNIQUE (memory_id, op, post_id)
)
```

- 행은 `remember()`, `promote_due()`, `decide()`가 전이와 같은 트랜잭션에서 쓴다. `app_rw`는 SELECT만 갖는다. `forbid_mutation` 트리거로 수정과 삭제를 막는다.
- 해시 체인과 묶는다. 함수가 그 전이에 쓴 증거 행들의 sha256을 `app.reason`에 `evidence:<hex>`로 넣는다. `reason`은 이미 `row_hash`에 들어가므로 `memory_version` 형식을 바꾸지 않고도 증거를 고치면 `verify_chain`이 `false`가 된다.
- 타이머 승격(`promote`)의 증거는 게시물이 아니라 "기간 동안 반박 없음"이다. `uri`는 NULL이고 `basis = timer`이며, 확인한 digest 커서 값을 `post_id` 자리에 남긴다.
- `memory.source_refs`의 `speakers`(창 전체 화자)는 그대로 둔다. 동의를 셀 때는 증거 행의 `author`만 쓴다.
- 기억을 삭제하면 증거 행의 `author_name`도 NULL로 지운다. `uri`와 `post_id`는 남긴다(원문 접근은 플랫폼 권한이 막는다).

## 7. digest와 워커

### 7.1 digest (창마다, 봇 컨텍스트)

1. 창을 읽는다(지금과 같다). 게시물에 번호를 붙여 렌더한다.
2. 후보: 같은 store에서 `active`, `provisional`, `challenger` 행을 검색해 상위 5개를 준다. 후보마다 상태를 함께 준다. 지금 빠져 있는 provisional과 challenger가 들어가므로 추출기가 기존 주체와 속성을 다시 쓴다.
3. 추출: 항목마다 kind, 키, 값, `relation`, `consensus`, `evidence`.
4. 게이트: 비밀값은 거부하고 저장하지 않는다. 지시문 같은 문장은 `gate_result.flags`에 라벨로 남는다. 사람 단계는 없다.
5. 청중 포함 검사: `room_containment`가 `ok`가 아니면 그 창은 저장하지 않고 `report.skipped_audience`를 센다. 이 규칙은 브리프에 없다. 13절의 3번에 이유를 적었다.
6. 서버 확인(4.1): 증거 번호를 게시물로 바꾸고 `consensus`를 확인한다.
7. `remember()`.

`send_proposal_cards`는 없어진다. `DigestReport`는 `created`, `confirmed`, `reconfirmed`, `challenged`, `superseded`, `retracted`, `skipped_audience`를 센다.

### 7.2 워커 (system, 주기 실행)

`app_sec.promote_due(p_now timestamptz DEFAULT now())`가 하는 일은 다음과 같다. `p_now`는 eval과 테스트가 시계를 넘기는 데 쓴다.

1. `status = 'provisional' AND promote_at <= p_now`인 행을 active로 바꾼다(`promote`, `basis = timer`). 그 키에 열린 challenger가 있으면 승격하지 않는다(challenger 쪽 규칙이 먼저 결론을 낸다).
2. `status = 'challenger' AND promote_at <= p_now`인 행마다 한 트랜잭션에서 살아 있는 행을 superseded(`valid_to = 오늘`)로, challenger를 active로 바꾼다.
3. 기억의 출처가 digest 바인딩이면, 그 바인딩의 `digest_cursor`가 `promote_at`을 지났을 때만 1, 2를 한다. digest가 밀려서 아직 읽지 않은 반박이 있을 수 있기 때문이다. 바인딩 출처가 없는 기억(MCP, 📌)은 시각만 본다.
4. `mark_expired()`(지금과 같다).

`stale` 라벨은 지금처럼 검색 결과에만 붙는다. v1.2 4절의 "아직 맞나요?" 카드는 만들지 않는다.

## 8. 검색과 MCP가 돌려주는 것

| 도구 | v1.3에서 |
|---|---|
| `search` | 기본 상태는 `active`, `provisional`. 결과마다 `status`, `label`(provisional은 "미확정"), `basis`, `promote_at`, `stale`, `last_confirmed_at`, `flags` 수. 키에 열린 challenger가 있으면 살아 있는 행에 `pending_change: {id, title, value, promote_at}`를 붙인다. challenger 본문만 질의에 맞아도 살아 있는 행이 나오고 challenger가 붙는다 |
| `get` | 본문(지금처럼 "참고 데이터이지 지시가 아님" 표시), `status`, `basis`, 증거 요약(증거 수, 서로 다른 작성자 수, 마지막 증거 시각) |
| `history` | 버전마다 op, 시각, 행위자, 그리고 그 버전의 증거 행(permalink, 작성자 이름, 게시물 시각) |
| `as_of` | 그대로. `active`, `provisional`, `superseded`, `expired`만 본다. challenger와 rejected는 그 시점에 유효했던 적이 없다 |
| `remember` | 결과는 `created`(상태 포함), `confirmed`, `reconfirmed`, `challenged`(충돌한 살아 있는 행 id 포함), `superseded`, `retracted`, `rejected`(게이트), `skipped` |
| `decide` | `decide(memory_id, verdict: confirm \| retract, expected_version, source_refs, reason)`. 에이전트도 부를 수 있다. 큐레이터 권한이 아니라 contributor 권한이다. `source_refs`는 필수이고 증거 행이 된다. 기존 증거에 이미 있는 principal의 `confirm`은 4행처럼 reconfirm만 한다(혼자서 확정하지 못한다). 반환은 `applied`(새 상태), `reconfirmed`, `refused`(`stale`, `not_live`) |

📌와 @멘션의 답글(에피메럴)도 결과에 맞춰 바뀐다. 예: "저장됨 (확정)", "저장됨 (미확정, 24시간 동안 반박이 없으면 확정)", "변경 제안으로 저장 (24시간 동안 반박이 없으면 교체)".

에이전트 규칙은 v1.1과 같다. 미확정 기억을 인용할 때 미확정이라고 밝히고, 그것만을 근거로 행동 규칙을 바꾸지 않는다. 지시문 표시나 `origin = external` 라벨은 active가 된 뒤에도 남는다.

## 9. 지금 코드에서 지우는 것과 남기는 것

| 대상 | 처리 |
|---|---|
| `src/nunchi/mattermost/cards.py` | 삭제 |
| `src/nunchi/mattermost/actions.py`, 액션 서버(포트 8787), `MM_ACTION_SECRET`, `MM_ACTION_URL`, `MM_ACTION_HOST`, `MM_ACTION_PORT` | 삭제. `deploy/compose.yml`의 포트와 환경 변수도 지운다 |
| `digest.py::send_proposal_cards`, 워커의 `cards:` 단계 | 삭제 |
| `events.py`의 카드 발급과 `CONFLICT` 문구 | 삭제. 8절의 답글 문구로 바꾼다 |
| `app_sec.decide()`(nonce 판), `issue_card`, `issue_dm_cards`, `pending_dm_cards`, `record_card_sent`, `quorum`, `risk_tier` | 삭제. `decide`는 8절의 새 서명으로 다시 만든다 |
| `approval_card`, `review` 표 | 데이터가 있으므로 표는 남기고 `app_rw` 권한을 모두 회수한다(감사 기록). 쓰는 함수는 없다. 이전(10절)이 기존 승인을 증거로 옮긴 뒤, 후속 단위에서 표 삭제를 다시 판단한다 |
| `approval_tier_rule`, `proposer_trust`, `trust_rule`, `memory.tier`, `approval_tier` 타입 | 삭제 |
| `store_role`의 `curator` | 남긴다. 바인딩 확인과 삭제에만 쓴다. 쓰기 경로에는 없다 |
| 📌, @멘션 캡처 | 남긴다. 4.2대로 자율로 바뀐다 |
| 쓰기 게이트, `room_containment`, 신선도, 임베딩 | 남긴다 |
| `review` 기반 정족수 테스트(`G3*`, `G4*` 등) | 그 기능과 함께 삭제한다. 삭제는 `expectations.tsv`에서 행을 지우는 일이므로 `gate-integrity`가 막는다. 해당 단위 PR 본문에 테스트 id 목록과 이유를 적고 소유자 확인을 받는다 |

## 10. 로컬 스택의 기존 데이터 이전

로컬 스택(2026-10-14 기준) 기억 8건 중 6건이 `proposed`이고, 카드가 12장 있다. 큐레이터 한 명이 6장을 눌러 모두 `pending_quorum:1/2`였고, 페르소나 큐레이터에게 간 6장은 열린 채다. 나머지 2건은 provisional note이고 U27이 다룬다.

이전은 SQL 마이그레이션이 아니라 한 번 실행하는 스크립트(`scripts/migrate-v1.3.py`)다. 같은 값 판정에 판정 모델이 필요하고, 결과를 사람이 미리 볼 수 있어야 하기 때문이다. 스크립트는 기본이 `--dry-run`이고 계획 표를 출력한다. `--apply`는 한 트랜잭션에서 실행한다.

규칙:

1. store마다 `proposed` 행을 `created_at` 순으로 다시 판정한다. 각 행을 같은 store의 앞선 생존 행과 비교한다.
2. 같은 키이고 같은 값(5.1의 판정)이면 뒤 행은 앞 행으로 합친다. 뒤 행은 rejected(사유 `merged:<앞 행 id>`)가 되고, 그 `source_refs`는 앞 행의 증거(`reconfirm`)가 된다.
3. 키는 다르지만 같은 store에서 `attribute`가 같고 값이 같으면(5.1의 판정, 판정 모델 포함) 같은 결정으로 보고 2처럼 합친다. 이 규칙은 이전에서만 쓴다. 평소 쓰기 경로에서 주체가 다른 두 키를 서버가 합치면 "A사 담당자 = 이민수"와 "B사 담당자 = 이민수" 같은 정당한 경우를 잘못 합친다.
4. 남은 행은 소비된 approve 카드가 있고 클릭한 사람이 그 기억의 화자가 아니면 active(`basis = migrated`, 클릭을 `confirm` 증거로 기록)다. 아니면 provisional이고 `promote_at = 이전 시각 + promote_after`다.
5. 열린 카드는 `consumed_at = now()`, `outcome = 'withdrawn:v1.3'`으로 닫는다. 이미 보낸 Mattermost DM은 스크립트가 고치지 않는다. 버튼을 누르면 액션 서버가 없으므로 아무 일도 일어나지 않는다. 지우려면 소유자가 직접 지운다.

이 규칙을 로컬 데이터에 적용하면 결과는 다음과 같다(값은 2026-10-14 읽기 전용 조회 기준).

| 기존 행 (생성 순) | 키 | 결과 |
|---|---|---|
| M1 범위 | (M1 마일스톤, 범위) | 생존, active (승인 1건) |
| 프론트 스타일링 방식으로 CSS Modules + ... | (프론트 스타일링 방식, 스타일 방식) | 생존, active |
| 라이트/다크 테마 전환은 data-theme ... | (프론트 스타일링 방식, 테마 전환 방식) | 생존, active |
| 스타일 방식은 CSS Modules + CSS 변수로 확정 | (foundation.md, 스타일 방식) | 합침 (규칙 3. 값 "css 변수"와 "css 커스텀 프로퍼티"는 판정 모델이 같다고 할 때만) |
| §6 스타일 방식: CSS Modules + CSS 커스텀 프로퍼티 확정 | (foundation.md, 스타일 방식) | 합침 (규칙 3) |
| foundation.md 스타일 방식: ... 확정 | (foundation.md, 스타일 방식) | 합침 (규칙 3) |

결과는 살아 있는 결정 3건이고, 스타일 결정 하나에 증거 4건(원래 행과 합친 3건)이 붙는다. 판정 모델이 "css 변수"를 다른 값이라고 하면, 그 행은 (foundation.md, 스타일 방식)의 생존 행이 되고 나머지 두 행이 그 행에 규칙 2로 합쳐진다. 어느 쪽이든 키마다 살아 있는 행은 하나다.

페르소나 계정(김민지)의 curator 권한은 이전과 별개로 거둘 것을 권한다. 카드가 없어지면 권한의 쓰임이 사라지고, 남겨 두면 삭제 권한이 페르소나에게 있다.

## 11. 측정

eval 하네스(`eval/`)는 지금 메시지 한 건씩 재생하고 `decide()` 결과를 `verdict`로 기록한다. v1.3에서는 대화 창을 재생하고, 시계를 넘기며 `promote_due(p_now)`를 부른다.

코퍼스 확장 (`eval/corpus/windows.jsonl`): 창마다 게시물 목록(작성자, 본문)과 정답을 둔다.

```text
{"id": "w001", "day": 1, "posts": [{"author": "a", "text": "...", "bot": false}, ...],
 "gold": [{"memory": "m30", "status_after": "active" | "provisional" | "challenger",
           "relation": "new" | "same" | "update" | "retract", "target": "m..",
           "consensus": "agreed" | "stated", "evidence": [0, 1]}]}
```

라이브 중복 사례를 `w-live-style-*` 4개 창으로 넣는다. 시뮬레이션 대화를 그대로 옮기지 않고 같은 구조로 다시 쓴다(세 사람이 스타일 방식에 동의하는 창 하나, 그 결정을 문서 이름을 주체로 다시 말하는 창 둘, 같은 결정을 같은 창에서 두 번 요약하는 창 하나). 정답은 기억 하나, 상태 active, 나머지는 `same`이다. 결정 선언 직후 창이 끝나는 사례와 "그거 아니야"로 철회하는 사례도 넣는다.

| 지표 | 정의 | 목표 (시작값) |
|---|---|---|
| 잘못된 active 비율 | active가 된 기억 중 정답이 active가 아닌 것 / active가 된 기억. 승격 정밀도 = 1 − 이 값. `agreed` 즉시 승격과 `timer` 승격을 따로 낸다 | 0.05 이하 |
| 키당 중복률 | 정답 기억 하나에 대응하는 rejected 아닌 행이 2개 이상인 정답 기억 수 / 정답 기억 수. 주체가 다른 중복도 센다 | 0.02 이하 |
| 철회 재현율 | 정답 `retract` 중 대상이 rejected 또는 expired가 된 것 / 정답 `retract` | 0.8 이상 |
| 잘못된 철회 | 정답에 철회가 없는데 rejected 또는 expired가 된 기억 / 기억 | 0.02 이하 |
| 변경 처리 | 정답 `update` 중 challenger가 되었다가 기간 뒤 active가 된 것, 또는 `agreed`로 바로 교체된 것 / 정답 `update` | 0.8 이상 |

v1.1 경로의 기준값(U31, 큐레이터 두 명이 모든 제안을 승인하던 하네스)은 스타일 결정 live 행 3개, 중복률 0.143, 잘못된 active 5건 중 2건(0.4), 철회 재현율 0/2다. U33이 `decide()`를 지운 뒤에는 이 값을 하네스로 다시 만들 수 없어 여기에 문자 그대로 남긴다.

U34 이후 값(2026-10-14, `python -m eval.run --windows`, 창 12개). 쓰기 경로가 아직 `stated`만 보내므로(U35가 합의를 `remember()`에 잇는다) 상태 지표는 그대로이고, 새 줄은 서버 확인(4.1)이 추출기의 주장을 어떻게 다뤘는지다.

| 지표 | v1.1 기준 | fake | noisy |
|---|---|---|---|
| 스타일 결정 live 행 (wm01) | 3 | 3 | 3 |
| 키당 중복률 | 0.143 | 0.143 (1/7) | 0.143 (1/7) |
| 잘못된 active 비율 | 0.4 (2/5) | 없음 (active 0건) | 없음 (active 0건) |
| 철회 재현율 | 0/2 | 0/2 | 0/2 |
| `agreed` 주장 / 낮춘 수 | 해당 없음 | 4 / 0 | 13 / 9 |
| 확인을 통과한 `agreed` 중 정답이 `stated`인 것 | 해당 없음 | 0 | 0 |
| 정답 `agreed` 중 확인이 놓친 것 | 해당 없음 | 0/4 | 0/4 |

fake는 정답의 `consensus`와 `evidence`를 베낀다. noisy는 모든 항목에 `agreed`를 주장해 서버 확인이 있는 이유가 되는 과대 주장을 만든다. 13개 중 9개가 `stated`로 내려갔고, 남은 4개가 정답 `agreed` 4개와 같다. 상태 지표가 움직이지 않는 이유는 두 가지다. 합의가 `remember()`에 닿지 않아 모든 행이 provisional이고, 스타일 결정의 세 행은 주체 이름이 달라(프론트 스타일링 방식, foundation.md) 키가 맞지 않는 것으로 보인다(추정, 확인하지 않았다). 둘 다 U35의 몫이다. Claude 추출기 실행은 Keychain이 필요해 Terminal.app에서만 되므로 이 값에 없다.

목표는 측정값이 아니라 시작값이다. fake/noisy 추출기는 `consensus`를 정답에서 베끼므로 배선만 확인한다. 합의 판정의 실제 정밀도는 Claude 추출기로만 잴 수 있다.

## 12. 구현 단위

순서는 빼기(카드 경로)를 먼저 하고, 측정 도구를 다음에 놓고, 그 위에 DB, 추출기, 배선, 워커, 표면 순으로 쌓는다. 단위마다 400줄 안팎이고 각자 테스트로 끝난다.

| 단위 | 내용 | 테스트 |
|---|---|---|
| U30 | 카드 경로 빼기(앱): `cards.py`, `actions.py`, 액션 서버, `send_proposal_cards`, `MM_ACTION_*`, compose 포트 8787. DB 함수는 아직 남는다(호출자가 없다) | `test_mattermost`, `test_digest`에서 카드 관련 테스트 삭제. digest 한 번 실행 뒤 DM 전송 호출이 0회임을 가짜 클라이언트로 확인 |
| U31 | eval: 창 코퍼스(`windows.jsonl`), 라이브 중복 사례, 시계 진행, 11절의 지표. v1.1 경로에서 기준값을 먼저 잰다(라이브 사례 중복률은 지금 0이 아니어야 한다) | `test_eval_smoke`: 라이브 사례에서 지표가 계산되고 develop 기준 중복 행 수가 문자 그대로 기록됨 |
| U32 | DB: `challenger` 상태(Python 미러 포함), `memory_evidence`, `store_autonomy`, `basis`, `promote_at`, 전이 표 v1.3(기본 키 변경, `app.op`), `memory_challenger_uidx` | `db/tests`: 표에 없는 `(from, to, op)`는 `P0001`, `app.op` 없는 상태 UPDATE는 `42501`, 키당 challenger 2개는 `23505`, 증거 행 수정은 거부. `expectations.tsv` 등록 |
| U33 | DB: `app_sec.remember()`가 5.1의 표 10행을 실행. 증거 기록과 `evidence:<hex>` 체인. 등급, `risk_tier`, `quorum`, 신뢰 점수 삭제 | 5.1의 행마다 DB 테스트 하나(입력 상태 → 결과 상태와 반환값을 문자 그대로). 증거를 고치면 `verify_chain = false` |
| U34 | 추출기: 번호 붙인 렌더, `consensus`, `evidence`, `relation = retracts`, 프롬프트. 서버 확인 함수(4.1)는 순수 함수 | `test_extract`: 스키마와 프롬프트. 새 `test_consensus`: 작성자 2명 → agreed, 1명 표지어 + 뒤 게시물 → agreed, 1명 표지어로 창 끝 → stated, 봇 게시물은 세지 않음 |
| U35 | 배선: `capture`가 `remember()`를 부른다. 후보에 provisional과 challenger. 📌 작성자 ≠ 핀 찍은 사람 → agreed. 청중 포함 실패 → 저장 안 함. 답글 문구 | `test_capture`, `test_mattermost`: 라이브 사례 4개 창 재생 → 행 1개, 증거 4건, 상태 active |
| U36 | 워커: `promote_due(p_now)`, challenger 교체, digest 커서 조건 | `test_worker`: 23시간 59분 → provisional, 24시간 → active. 커서가 밀리면 승격 안 함. challenger 기간 경과 → 옛 행 superseded, `valid_to = 오늘` |
| U37 | 표면: `search`의 `label`, `basis`, `pending_change`. `get`의 증거 요약. `history`의 증거. MCP `decide` 새 서명(contributor, 에이전트 허용, `source_refs` 필수) | `test_mcp`, `test_mcp_write`: 에이전트의 `decide retract` → rejected와 증거 1건. 같은 화자의 `confirm` → reconfirmed |
| U38 | 이전 스크립트 `scripts/migrate-v1.3.py`(10절), `CHECK (status <> 'proposed')` 검증. 카드 관련 DB 함수 삭제, `approval_card`와 `review` 권한 회수 | 로컬 스택과 같은 모양의 고정 데이터(6행, 카드 12장)에서 `--dry-run` 계획 표와 `--apply` 결과가 10절의 표와 같음 |

U31을 U32보다 먼저 두는 이유는, 같은 지표로 v1.1과 v1.3을 비교하기 위해서다. U30을 맨 앞에 두는 이유는 카드 전송이 지금도 사람과 페르소나에게 DM을 보내고 있기 때문이다.

## 13. 브리프 규칙에 대한 이견

1. **규칙 4와 규칙 3이 충돌한다.** 규칙 4는 합의 없는 다른 값을 "provisional로 두고 conflict_with로 잇는다"고 한다. 규칙 3은 provisional과 active를 함께 세서 키마다 살아 있는 행을 하나로 제한한다. 옛 값이 active인 동안 새 값이 provisional이면 살아 있는 행이 둘이 되고, 지금의 `memory_live_key_uidx`가 그 INSERT를 거부한다. 그래서 새 값의 상태를 `challenger`로 분리했다. 검색에서는 살아 있는 행에 붙어 나오고, 키 유일성에서는 따로 센다(키마다 하나). 규칙 4의 나머지(24시간 뒤 교체, 반박되면 철회)는 그대로다.
2. **"결정/확정이라고 말하고 창 안에서 반대가 없으면 즉시 active"는 너무 넓다.** digest 창은 15분 동안 게시물이 없으면 끝난다. 결정을 선언한 게시물이 창의 마지막이면 "반대 없음"은 아무도 읽지 않았다는 뜻일 뿐이다. 라이브 사례의 스타일 결정 중 두 건이 한 사람의 정리 게시물에서 나왔다. 그래서 선언 뒤 같은 창에 다른 작성자의 게시물이 하나 이상 있어야 한다는 조건을 더했다. 조건을 못 채우면 provisional이 되고 24시간 뒤 승격되므로 잃는 것은 지연뿐이다.
3. **청중 포함 검사가 브리프에 없다.** v1.1에서 채널 청중이 store 독자보다 좁으면 사람이 승인해야 했다(좁은 곳에서 넓은 곳으로 올리는 일). 사람이 없으면 이 검사를 라벨로 둘 수 없다. 라벨을 단 채 저장하면 채널에 없던 store 독자가 그 내용을 읽는다. 그래서 비밀값 게이트처럼 자동 거부(저장 안 함)로 바꿨다.
4. **지시문 표시는 라벨로만 남는데, 타이머 승격도 그대로 탄다.** 소유자가 정한 대로 적었다. v1.1이 근거로 든 결과(승격 관문을 뺀 실험에서 피해 16배)는 이 경로에 해당한다. 지시문 표시가 있거나 `origin = external`인 기억을 타이머로 승격하지 않고 대화 합의로만 승격하는 안을 권한다. 사람 단계가 없는 규칙이다. 이 안을 채택했다(U33 구현 결정). `remember()`는 외부 출처와 지시문 표시가 붙은 provisional과 challenger의 `promote_at`을 비우고, `promote_due`(U36)는 `promote_at`이 없는 행을 승격하지 않는다.
