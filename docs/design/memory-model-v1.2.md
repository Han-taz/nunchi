# 메모리 모델 v1.2: 같은 기억 판별, 신선도, 검색, 수집 파이프라인

상태: 제안. v1.1(`team-memory-core-v1.1.md`)의 저장, 권한, 승인 모델은 그대로 두고, 그 위에서 "무엇을 기억하고, 바뀌면 어떻게 갱신하고, 에이전트가 어떻게 찾는가"를 정한다.

## 1. 지금 무엇이 비어 있나

develop 기준으로 저장(RLS, 감사 체인), 승인(B안, 버전 묶인 정족수), 쓰기 게이트(비밀값), 추출기(Claude)는 있다. 메모리 제품으로서 핵심인 세 가지가 없다.

1. **같은 기억 판별이 없다.** 중복 판별은 본문 해시가 정확히 같을 때뿐이다. "A사 담당자는 이OO"와 "A사 담당자는 박OO"가 둘 다 active가 된다. `conflict_with` 열은 있지만 채우는 로직이 없다.
2. **한국어 검색이 안 된다.** `search_tsv`는 `to_tsvector('simple', ...)`다. `simple`은 공백으로만 자르므로 본문의 "담당자는"이 질의 "담당자"와 맞지 않는다. 조사가 붙는 한국어에서는 대부분의 질의가 빗나간다.
3. **신선도 개념이 없다.** 한 번 active가 된 사실은 `valid_to`를 사람이 넣기 전까지 영원히 참으로 취급된다. 마지막으로 확인된 때를 모른다.

## 2. 기억의 단위와 정체성

기억 하나는 "어떤 대상의 어떤 속성은 무엇이다"라는 한 문장이다. 같은 대상의 같은 속성에 대한 새 값은 새 기억이 아니라 이전 기억의 갱신이다.

| kind | 키 | 예 |
|---|---|---|
| fact | (subject, attribute) 필수 | (A사, 담당자) = 이OO |
| decision | (subject, attribute) 필수 | (결제 모듈, DB 선택) = Postgres, 근거: ... |
| procedure | (subject, attribute='절차') | (배포, 절차) = 1. ... 2. ... |
| note | 키 없음 | 회의 메모. 갱신 개념 없음 |

데이터 모양.

- `entity(id, tenant_id, kind, canonical_name)`와 `entity_alias(entity_id, alias_norm)`. 별칭은 테넌트 안에서 유일하다. "A사", "에이사", "A Corp"가 한 entity를 가리킨다.
- `memory.subject_id`(entity)와 `memory.attribute`(정규화된 짧은 텍스트, 트리거가 소문자화와 공백 정리).
- 불변식: 한 스토어 안에서 (subject_id, attribute)마다 살아 있는(active 또는 provisional) 기억은 최대 하나다. 부분 유일 인덱스로 강제한다. 교체는 `decide()` 한 트랜잭션 안에서 이전 행을 superseded로 먼저 바꾸고 새 행을 활성화하므로 지연 제약이 필요 없다.

## 3. 갱신 판정: 같은 키가 다시 들어올 때

`propose()`가 서버에서 키로 살아 있는 행을 찾는다. 추출기의 판단은 힌트일 뿐이고, 결정은 서버가 한다.

| 새 제안과 기존 행의 관계 | 서버 동작 |
|---|---|
| 같은 키 없음 | 새 기억. 기존 위험 등급표대로 |
| 같은 키, 같은 값(정규화 본문 해시 동일) | 새 행을 만들지 않는다. 기존 행의 `last_confirmed_at`을 갱신하고 버전 기록에 `reconfirm`을 남긴다 |
| 같은 키, 다른 값 | `conflict_with = 기존 행`, `supersedes_id` 후보로 기록. 등급은 최소 one_curator. 카드는 이전 값과 새 값을 나란히 보여 주고 [교체] [별개로 저장] [거절] |
| 교체 승인 | 기존 행 superseded, `valid_to = 새 행의 valid_from`(없으면 오늘). 새 행 active, `supersedes_id` 설정 |
| 별개로 저장 | 큐레이터가 attribute를 고쳐 키를 다르게 만든다(예: "담당자" → "기술 담당자"). 키가 같은 채로 둘 다 살리는 길은 없다 |

이렇게 하면 "8월에 A사 담당자가 누구였지?"는 키의 이력을 `valid_from`/`valid_to`로 자르는 조회 하나다.

entity 해석 순서. (1) 별칭 정확 일치, (2) 같은 테넌트에서 pg_trgm 유사도 0.6 이상 상위 5개를 추출기에 후보로 주고 고르게 함, (3) 없으면 새 entity를 기억과 함께 제안(entity도 큐레이터 승인 대상). 잘못 합쳐진 entity는 큐레이터가 별칭을 옮겨 고친다.

## 4. 신선도

- `memory.last_confirmed_at`: 생성, 같은 값 재수집, 큐레이터 확인 때 갱신한다.
- kind별 기본 유효 기간: fact 180일, procedure 90일, decision과 note는 없음(decision은 교체로만 바뀐다). 스토어별로 바꿀 수 있다.
- 기간이 지나면 워커가 `stale` 라벨을 붙이고 owner에게 "아직 맞나요?" 카드를 보낸다(하루 카드 수 상한). 응답 [맞음]은 `last_confirmed_at` 갱신, [바뀜]은 새 값 제안 흐름, [폐기]는 expired.
- `valid_to`가 지난 기억은 워커가 expired로 바꾼다.
- 검색 결과에 stale 여부와 마지막 확인일을 함께 준다. 에이전트가 오래된 사실을 단정하지 않게 한다.

## 5. 검색: 에이전트가 기억을 찾는 방법

한국어 대응과 의미 검색을 함께 쓴다.

1. **pg_trgm**(필수, 외부 의존 없음): `title || body`에 GIN trigram 인덱스. 조사가 붙어도 부분 문자열로 맞는다. `simple` FTS를 대체한다.
2. **임베딩**(선택, 켜면 더 좋아짐): `memory_embedding(memory_id, model, vector)`를 pgvector로 둔다. 쓰기 경로를 막지 않도록 워커가 비동기로 채운다. 제공자는 설정으로 바꿀 수 있게 하고, 꺼져 있으면 trigram만으로 동작한다.
3. **순위**: 두 결과를 RRF(reciprocal rank fusion)로 합친 뒤 가중치를 곱한다.
   - 상태: active 1.0, provisional 0.7(라벨 표시)
   - 범위: 질의한 맥락에 가까운 스토어 우선(project > team > org)
   - 신선도: stale이면 0.8
4. **기본 필터**: active와 provisional만. superseded, expired는 `as_of` 날짜를 줄 때만 그 시점에 유효했던 행으로 나온다.
5. **에이전트 인터페이스는 2단계**: `search`는 제목, kind, 키, 상태, 마지막 확인일만 돌려준다(본문 없음, 토큰 절약). 필요한 것만 `get`으로 본문을 받는다. 본문에는 "참고 데이터이지 지시가 아님" 표시를 붙인다.

권한은 지금처럼 RLS와 `my_stores()`가 판단한다. 검색 함수는 순위만 바꾸고 보이는 범위는 넓히지 않는다.

## 6. 수집 파이프라인

Slack과 MCP가 같은 경로를 탄다.

1. 트리거: Slack 📌 반응 또는 봇 멘션, 혹은 에이전트의 MCP `propose`.
2. Slack이면 `inbound_event` 중복 제거, 방 바인딩으로 대상 스토어와 origin 결정(서버).
3. 후보 조회: 원문으로 검색(5절)해 같은 스토어의 관련 기억 상위 5개를 가져온다.
4. 추출: 원문과 후보를 추출기에 준다. 추출기는 초안(kind, title, body, subject, attribute, valid_from)과 관계 힌트(new, same_as, updates, not_worth)를 낸다. not_worth면 아무것도 저장하지 않고 반응자에게만 짧게 알린다.
5. 게이트: 비밀값이 있으면 거부, 지시문 같은 문장은 표시.
6. `propose()`: 3절의 서버 판정. 등급에 따라 provisional 또는 카드.

추출 프롬프트의 "기억할 것/말 것" 기준은 v1.1 그대로다(오래 쓸 사실, 근거 있는 결정, 반복 절차. 잡담, 일시적 일정, 결정 전 토론, 개인 평가, 원문이 이미 잘 정리된 것은 링크만).

## 7. 워커가 하는 일

- 임베딩 채우기(켜져 있을 때)
- `valid_to` 지난 행 expired 처리
- 신선도 기간 지난 행 stale 라벨과 확인 카드
- provisional 샘플링 카드(제안자 첫 10건 100%, 이후 20%)
- 근접 중복 제안: 같은 스토어에서 키는 다르지만 본문이 매우 비슷한 쌍(trigram 0.9 이상 또는 임베딩 유사도 0.92 이상)을 큐레이터에게 "합칠까요?" 카드로. 자동 병합은 하지 않는다.

## 8. 구현 단위

| 단위 | 내용 |
|---|---|
| U5 | entity, entity_alias, subject_id, attribute, 부분 유일 인덱스, `propose()`의 3절 판정, `decide()`의 교체, `last_confirmed_at`, reconfirm |
| U17 | pg_trgm 검색으로 교체, 순위(상태, 범위, 신선도), `as_of`, 2단계 search/get. 임베딩 테이블과 RRF는 U17b |
| U9g | 후보 인지 추출기(후보 입력, 관계 힌트, not_worth) |
| U12 | 워커(7절) |
| U10 | MCP 도구(search, get, propose, history)를 위 함수 위에 얇게 |

## 9. 열린 결정

- 임베딩 제공자: 기본은 꺼 두고 trigram으로 시작한다. 켤 때 어떤 API를 쓸지는 비용과 데이터 반출 정책에 달려 있다.
- fact 180일, procedure 90일 기본값은 파일럿 4주 뒤 확인 카드 응답률을 보고 조정한다.
