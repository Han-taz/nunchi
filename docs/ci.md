# CI 가이드

nunchi의 CI는 `.github/workflows/ci.yml` 하나다. PR(`develop`, `main` 대상)과 `develop`/`main` push, 매일 18:17 UTC 스케줄에서 돈다. `develop` 브랜치 보호는 **`ci-gate`와 `independent-verify` 두 체크**를 요구한다. 나머지 job은 `ci-gate`가 묶어서 판정한다.

## 공통 원칙

- 모든 action은 전체 커밋 SHA로 고정하고 옆에 버전 주석을 단다. 갱신은 Dependabot이 주 1회 PR로 올린다(7일 cooldown).
- 워크플로 최상단은 `permissions: {}`이고 job마다 필요한 최소 권한만 준다. 대부분 `contents: read`, CodeQL만 `security-events: write`가 추가된다.
- 모든 job에 `timeout-minutes`가 있고, PR 실행은 같은 PR의 이전 실행을 취소하는 `concurrency` 그룹을 쓴다.
- checkout은 전부 `persist-credentials: false`다.
- Python/Node 도구는 `.github/tools/`의 잠금 파일(해시 포함 `requirements.txt`, `package-lock.json`)로만 설치한다. 버전 변경은 Dependabot PR을 거친다. 로컬에서 CI와 같은 도구를 쓰려면 같은 잠금 파일로 설치한다.
- 규칙을 끄거나 제외할 때는 설정 파일에 한 줄 이유를 적는다. 이 문서 끝의 표가 전체 목록이다.

## 게이트별 설명

| job | 무엇을 | 왜 |
|---|---|---|
| `db-tests` | `postgres:16` 서비스에 새 DB를 만들어 `db/schema.sql`을 적용하고 `db/tests/smoke_test.sql`을 실행한다. 두 번, 각각 새 DB에서 돈다. 두 실행의 결과 파일이 달라도 실패한다. | RLS가 권한 경계의 전부이므로 회귀가 곧 보안 사고다. 두 번 도는 이유는 순서 의존이나 flaky 테스트를 잡기 위해서다. |
| `mutation-gate` | 같은 테스트를 알려진 취약 스키마(`db/tests/fixtures/schema_v1_0_vulnerable.sql` + 권한 shim)에 돌리고, X 시리즈가 레지스트리가 말한 대로 실패하는지 확인한다. | 취약점이 있는 스키마에서 통과하는 테스트는 아무것도 지키지 못한다. 테스트가 이빨을 잃으면 이 job이 잡는다. |
| `sql-lint` | `sqlfluff`(postgres 방언)로 `db/`를 검사하고, `squawk`으로 `db/schema.sql`을 검사한다. | 스키마 스타일과 위험한 DDL 패턴을 기계로 고정한다. |
| `markdown` | `markdownlint-cli2`, 그리고 `lychee --offline`으로 상대 링크와 앵커를 검사한다. | 문서 이동(리네임) 뒤 깨진 링크를 막는다. |
| `secrets` | `gitleaks`로 전체 히스토리(`fetch-depth: 0`)와 작업 트리를 검사한다. | 공개 저장소다. 한 번 올라간 비밀값은 지울 수 없다. |
| `workflow-lint` | `actionlint`, `zizmor`(기본 persona, 온라인 감사 포함). | 워크플로 자체가 공급망 공격면이다. 인젝션, 과한 권한, 고정되지 않은 action을 잡는다. |
| `shell` | `scripts/` 아래 모든 `*.sh`에 `shellcheck -S style`. | CI와 테스트 러너가 셸이다. |
| `hygiene` | `editorconfig-checker`(후행 공백, 마지막 개행, 줄바꿈, 들여쓰기 규칙), `typos`. | 노이즈 diff를 막는다. |
| `commits` | PR 범위의 모든 커밋이 conventional commit 형식인지, 병합 커밋이 없는지, AI 공동 저자 표기(`Co-Authored-By:` Claude/Anthropic 등, "Generated with Claude")가 없는지 검사한다. 스크립트: `scripts/ci/check-commits.sh`. | 히스토리를 선형으로 읽히게 하고, 이 저장소의 커밋 정책을 강제한다. |
| `pr-size` | `docs/research/**`, `docs/reviews/**`, 그리고 생성되는 도구 잠금 파일(`.github/tools/package-lock.json`, `.github/tools/requirements.txt`)을 뺀 변경이 800줄(추가+삭제)을 넘으면 실패한다. 스크립트: `scripts/ci/pr-size.sh`. | 리뷰 가능한 크기를 유지한다. 두 디렉터리는 참고용 산문이다. |
| `codeql` | CodeQL, 언어 `actions`. | 워크플로의 알려진 취약 패턴을 GitHub의 쿼리로 한 번 더 본다. |
| `ci-gate` | 위 job 전부를 `needs`로 걸고 `if: always()`로 돈다. 하나라도 `success`가 아니면(실패, 취소, **건너뜀** 포함) 실패한다. | 브랜치 보호에는 이 체크 하나만 등록하면 된다. job을 추가해도 보호 설정을 바꿀 필요가 없다. |
| `external-links` | 스케줄 실행에서만 `lychee`로 외부 링크를 검사한다. 429는 허용한다. | 외부 사이트는 일시적으로 죽는다. PR을 막지 않고 매일 한 번만 확인한다. `ci-gate`에는 포함되지 않는다. |

스케줄 실행은 위의 모든 job을 돌리되, 범위를 정할 PR이 없어서 `commits`와 `pr-size`는 검사 step을 건너뛴다.

## independent-verify

`independent-verify`는 이 워크플로의 job이 **아니다**. 별도의 검증 에이전트가 PR 헤드 SHA에 직접 게시하는 **커밋 상태(commit status)** 이고, 브랜치 보호가 `ci-gate`와 함께 요구한다. 그러므로 CI가 모두 초록이어도 이 상태가 올라오기 전까지 PR 체크 목록에 "Expected / waiting"으로 보인다. 이것은 실패가 아니다.

- 워크플로를 만들거나 이 상태를 CI에서 게시하면 안 된다. 게시 주체가 독립적이라는 점이 이 체크의 의미다.
- 새 커밋을 push하면 헤드 SHA가 바뀌므로 상태가 무효가 된다. 검증을 다시 받아야 한다.

## DB 테스트 레지스트리

`scripts/db-test.sh`는 `db/tests/expectations.tsv`를 기준으로 판정한다.

- 등록된 id가 출력에 없으면(테스트가 조용히 건너뛰어졌으면) 실패한다.
- 등록되지 않은 id가 출력되면 실패한다. 테스트를 추가하면 레지스트리에도 추가해야 한다.
- `on_vulnerable` 열이 `fail`이면 취약 스키마에서 반드시 실패해야 하고, `pass`면 반드시 통과해야 한다. X 테스트를 `pass`로 두려면 이유를 note에 적어야 한다.

취약 스키마에서도 통과하는 X 테스트 9개는 모두 이유가 있다.

- 양성 대조군(정상 동작이 계속 되는지 확인): X1g, X2e, X2h, X4c, X4i, X5f.
- X3c, X3f(DELETE 거부): 취약 스키마용 grant shim이 애초에 DELETE 권한을 주지 않아서 스키마와 무관하게 거부된다. shim에 DELETE를 주면 `store_grant`가 통째로 지워져 이후 테스트 상태가 망가지므로 주지 않았다.
- X5e(redact 해제 거부): v1.0 트리거가 이미 막고 있었다.

## 로컬 실행

```sh
docker run -d --rm --name nunchi-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16
export PG_URL=postgres://postgres:postgres@localhost:5432/postgres
scripts/db-test.sh --url "$PG_URL"                       # db-tests와 같음
scripts/db-test.sh --url "$PG_URL" --profile vulnerable  # mutation-gate와 같음
```

`psql` 클라이언트가 필요하다.

## 규칙 제외 목록

| 도구 | 제외한 규칙 | 이유 |
|---|---|---|
| sqlfluff | `references.keywords` (RF04) | 컬럼 `name`, `role`, `version`, `snapshot`, `at`는 스키마 계약이고 테스트가 쓴다. Postgres는 따옴표 없이 허용한다. |
| sqlfluff | 파일 제외: `db/tests/smoke_test.sql`, `docs/reviews/exp/`, `db/tests/fixtures/` | smoke test와 실험 스크립트는 psql 스크립트라서(`\set`, `SET LOCAL app.x = '...'`) sqlfluff postgres 방언이 파싱하지 못한다. fixture는 취약 스키마 원본이라 그대로 두어야 한다. |
| squawk | `require-lock-timeout`, `require-statement-timeout` | 스키마 파일은 빈 DB에 한 번 적용하는 부트스트랩이다. 락을 두고 다툴 트래픽이 없다. |
| squawk | `require-concurrent-index-creation` | `CREATE INDEX CONCURRENTLY`는 트랜잭션 안에서 못 쓰고, 빈 테이블에서는 이득이 없다. |
| squawk | `prefer-robust-stmts` | 파일은 새 DB에 한 번 실행한다. 중간에 실패하면 DB를 지우고 다시 만든다. |
| squawk | `prefer-bigint-over-int` | `memory.version`, `memory_version.version`은 행별 개정 카운터이지 id 공간이 아니다. |
| markdownlint | `MD013` (줄 길이) | 한국어 문단과 넓은 표는 한 줄이다. |
| markdownlint | `MD060` (표 열 스타일) | 가져온 리서치 표 전체를 다시 정렬하라는 규칙이다. |
| markdownlint | `MD036` (강조를 제목으로) | 출처 노트가 굵은 글씨 한 줄로 하위 블록을 표시한다. 제목으로 바꾸면 모든 노트의 개요가 바뀐다. |
| markdownlint | `MD025` 설정 `front_matter_title: ""` | YAML front matter의 `title`과 본문 H1이 함께 있는 것이 의도다. |
| typos | 단어 `anc`, `EHR`, `NAMS`, `RTO`, `LAF`, `IIT`, `FPR` | 논문 약어와 기호다(ancestor 함수, 전자건강기록, Neo4j Agent Memory Service 등). |
| gitleaks | 정규식 `family/partner`, 파일 `gatemem-2606.18829.md` | 벤치마크 설명의 산문이 `generic-api-key` 규칙에 걸린다. |
| shellcheck | 없음 (`-S style`) | |
| zizmor | 없음 (기본 persona, 온라인) | |

`pr-size`에는 우회 장치가 없다. 라벨을 포함해 어떤 입력도 한도를 바꾸지 못한다. 한도(800줄)를 넘으면 규칙은 하나다. PR을 쪼갠다. 게이트 자체는 `scripts/ci/pr-size-selftest.sh`가 합성 diff로 검증한다(800줄은 통과, 801줄은 실패). 이 self-test는 `pr-size` job에서 매번 돈다.

도구 의존성에는 `npm audit`가 보고하는 알려진 취약점(개발용 린터의 파서 DoS)이 있다. 신뢰하는 입력에만 돌리고 산출물에 들어가지 않으므로 게이트로 삼지 않았다.

## 애플리케이션 코드가 들어오면 켤 게이트

지금 저장소에는 애플리케이션 코드가 없어서 아래 게이트는 적용 대상이 없다. 코드가 들어오는 PR에서 같은 방식으로(실제로 도는 것만, `ci-gate`의 `needs`에 추가) 켠다.

| 게이트 | 도구 | 기준 |
|---|---|---|
| diff coverage | diff-cover 등 | 변경된 줄의 커버리지 80% 이상 |
| 뮤테이션 테스트 | mutmut(Python), Stryker(TypeScript) | 살아남은 뮤턴트가 임계 이하 |
| 속성 기반 RLS 테스트 | Hypothesis | 임의의 user/agent/grant 조합에서 "실효 권한 = 교집합" 불변식 |
| 의존성 취약점 | pip-audit, osv-scanner | 알려진 취약점이 있으면 실패 |
| 미사용/누락 의존성 | deptry | 선언과 import가 어긋나면 실패 |
| SAST | Semgrep | 규칙 위반 시 실패 |
| 컨테이너/이미지 스캔 | Trivy | 높음 이상 취약점 시 실패 |
| SBOM과 서명 | Syft로 SBOM 생성, cosign으로 서명 | 릴리스 산출물에 첨부 |
| 성능 회귀 | 벤치마크 비교 | RLS 정책 비용(`count(*)` 등)이 기준 대비 악화되면 실패 |
| API 호환성 | OpenAPI breaking-change 검사 | 하위 호환을 깨는 변경 시 실패 |
