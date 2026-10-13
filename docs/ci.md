# CI 가이드

nunchi의 CI는 `.github/workflows/ci.yml` 하나다. 모든 PR(대상 브랜치와 무관하게, 스택된 자식 PR 포함)과 `develop`/`main` push, 매일 18:17 UTC 스케줄에서 돈다. `develop` 브랜치 보호는 **`ci-gate`와 `independent-verify` 두 체크**를 요구한다. 나머지 job은 `ci-gate`가 묶어서 판정한다.

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
| `sql-lint` | `sqlfluff`(postgres 방언)로 저장소 전체(`.`)를 검사하고, `squawk`으로 `db/schema.sql`을 검사한다. 크기 때문에 건너뛰는 파일은 없다(`large_file_skip_byte_limit = 0`). 커버리지 단언: `sqlfluff lint . --format json`이 실제로 검사한 파일 목록을 `git ls-files '*.sql'`에서 `.sqlfluffignore`에 적힌 경로를 뺀 목록과 비교하고, 빠진 파일이나 예상 밖의 파일이 있으면 실패한다. `.sqlfluffignore`에는 정확한 경로와 `dir/` 접두사만 쓸 수 있다(그 밖의 패턴은 단언이 거부한다). | 스키마 스타일과 위험한 DDL 패턴을 기계로 고정한다. sqlfluff 기본값은 20000바이트를 넘는 파일을 경고만 남기고 조용히 건너뛰므로, 큰 `db/schema.sql`이 린트 없이 통과할 수 있었다. 단언은 같은 일이 설정 변경이나 새 파일로 다시 생기는 것을 막는다. 마지막으로 `scripts/gen-unicode-ignorables.py --check db/schema.sql`이 고정된 UCD 18.0.0 파일(버전과 sha256이 스크립트에 박혀 있다)에서 보이지 않는 문자(일반 범주 Cf 전체, Default_Ignorable_Code_Point, 공백이 아닌 Cc)의 정규식 클래스를 다시 만들어 `schema.sql`의 생성 블록과 비교한다. 유니코드 버전을 올릴 때는 스크립트의 버전과 해시를 바꾸고 새 마이그레이션으로 함수를 다시 만든다. |
| `markdown` | `markdownlint-cli2`, 그리고 `lychee --offline`으로 상대 링크와 앵커를 검사한다. | 문서 이동(리네임) 뒤 깨진 링크를 막는다. |
| `secrets` | `gitleaks`로 전체 히스토리(`fetch-depth: 0`)와 작업 트리를 검사한다. | 공개 저장소다. 한 번 올라간 비밀값은 지울 수 없다. |
| `workflow-lint` | `actionlint`, `zizmor`(기본 persona, 온라인 감사 포함). | 워크플로 자체가 공급망 공격면이다. 인젝션, 과한 권한, 고정되지 않은 action을 잡는다. |
| `shell` | `scripts/` 아래 모든 `*.sh`에 `shellcheck -S style`. | CI와 테스트 러너가 셸이다. |
| `hygiene` | `editorconfig-checker`(후행 공백, 마지막 개행, 줄바꿈, 들여쓰기 규칙), `typos`. | 노이즈 diff를 막는다. |
| `commits` | PR 범위의 모든 커밋이 conventional commit 형식인지, 병합 커밋이 없는지, AI 공동 저자 표기(`Co-Authored-By:` Claude/Anthropic 등, "Generated with Claude")가 없는지 검사한다. 스크립트: `scripts/ci/check-commits.sh`. | 히스토리를 선형으로 읽히게 하고, 이 저장소의 커밋 정책을 강제한다. |
| `pr-size` | 변경이 800줄(추가+삭제)을 넘으면 실패한다. 저장소 속성(`.gitattributes`)은 무시하고 센다. 면제는 셋뿐이다. (1) `docs/research/**`와 `docs/reviews/**`의 `*.md` 중 텍스트인 것(git numstat이 숫자를 내고 blob이 NUL 없는 유효한 UTF-8이어야 한다. 이름만 `.md`인 바이너리는 바이너리로 센다. `.sql.md`, `.py.md`, `.s-ql.md`, `..md`처럼 확장자가 겹친 파일은 숫자만으로 된 `gatemem-2606.18829.md` 꼴이 아니면 센다. 다른 확장자도 센다), (2) 잠금 파일(`uv.lock`, `.github/tools/package-lock.json`, `.github/tools/requirements.txt`)은 같은 PR에서 원본 매니페스트(`pyproject.toml`, `package.json`, `requirements.in`)가 함께 바뀐 경우에만 줄 수에서 빠지며, 이때도 NUL 바이트 없는 유효한 UTF-8 텍스트여야 하고 파일당 2 MiB, 잠금 파일 합계 4 MiB를 넘으면 실패한다(바이너리나 UTF-8이 아닌 잠금 파일은 실패. 잠금 파일은 정당한 의존성 갱신이 막히지 않도록 일반 합계 1 MiB에서는 따로 센다. `uv.lock`은 develop에서 약 216 KB다), (3) 바이너리 허용 목록(png, jpg, gif, svg, pdf, ico)은 10 KB마다 50줄(최소 50줄)로 센다. 줄 수만으로는 CR만 있는 파일이나 한 줄짜리 거대 파일을 막지 못하므로 바이트도 제한한다. HEAD blob 기준으로 파일당 512 KB, 변경된 모든 파일의 합계 1 MiB를 넘으면 실패한다(`.md` 면제는 줄 수에만 적용되고 바이트 한도는 그대로 적용된다. 매니페스트가 함께 바뀐 잠금 파일은 줄 수만 면제이고 위의 잠금 파일 전용 한도를 따른다). 허용 목록에 없는 바이너리는 실패한다. 스크립트: `scripts/ci/pr-size.sh`. | 리뷰 가능한 크기를 유지한다. 경로나 속성으로 파일을 숨길 수 없게 한다. |
| `codeql` | CodeQL, 언어 `actions`. | 워크플로의 알려진 취약 패턴을 GitHub의 쿼리로 한 번 더 본다. |
| `app-lint` | `ruff check`(규칙: E F W I S B UP SIM PL RUF ANN), `ruff format --check`, `mypy --strict src tests`, `deptry`. | 타입과 스타일, 선언되지 않았거나 쓰지 않는 의존성을 기계로 고정한다. |
| `app-tests` | `postgres:16` 서비스에 대해 `pytest`를 `-W error`(경고는 오류)로 돌린다. 마이그레이션 러너(적용, 재적용은 무동작, 변조 감지)와 Hypothesis 속성 테스트, RLS 테스트(`request_tx`가 만든 컨텍스트를 RLS 쿼리가 보는지)가 여기서 돈다. 스켈레톤 전체 커버리지 100%(분기 포함)가 아니면 실패하고, PR에서는 `diff-cover`로 변경된 줄의 80%를 추가로 요구한다. | 앱 코드가 늘어도 변경분이 테스트 없이 들어오지 못하게 한다. |
| `schema-drift` | 새 DB 둘을 만든다. 하나는 `db/schema.sql`, 다른 하나는 `python -m nunchi.migrate`로 만들고 `pg_dump --schema-only`(`schema_migrations` 제외, 매번 바뀌는 `\restrict` 줄 제거) 결과를 비교한다. 스크립트: `scripts/ci/schema-drift.sh`. | `schema.sql`을 고치고 마이그레이션을 빼먹는 일을 막는다. |
| `migrations-immutable` | PR의 base에 있는 `db/migrations/` 아래 모든 파일이 head에서 같은 모드와 blob 해시로 남아 있는지 `git ls-tree`로 비교한다. 수정, 삭제, 이름 변경이 모두 실패한다. `0001_baseline.sql`도 예외가 아니다. `db/migrations/SHA256SUMS`는 `*.sql` 전체의 sha256과 정확히 같아야 하고(다시 만들어 diff), base의 줄이 head에서 사라져도 실패한다. head가 추가한 마이그레이션의 버전은 base의 최대 버전보다 엄격히 커야 하고(건너뛰는 것은 허용), `db/migrations` 아래 도트 파일(`.keep`, `.0003_x.sql` 등)은 실패한다. 셸 glob이 도트 파일을 건너뛰어 SHA256SUMS를 빠져나가기 때문이다. 스크립트: `scripts/ci/migrations-immutable.sh`, 자체 테스트 `scripts/ci/migrations-immutable-selftest.sh`(0001 수정, 매니페스트 재생성 후 수정, 삭제, 이름 변경, 매니페스트 누락이 실패하고 새 마이그레이션 추가는 통과). | 병합된 마이그레이션을 고쳐 쓰면 이미 적용된 DB와 새 DB가 조용히 갈라진다. 베이스라인 생성기 비교(`cmp`)는 0001을 처음 추가하는 PR에서만 의미가 있었고 그 PR은 이미 병합되었으므로 삭제했다. 생성기 `scripts/migrate-baseline.sh`도 함께 지웠다. |
| `app-mutation` | `mutmut`. PR에서는 변경된 `src/nunchi` 모듈만, 그 밖의 실행(push, 스케줄)에서는 전부 돌려 죽인 뮤턴트 비율이 80% 미만이면 실패한다(timeout은 죽인 것으로 센다). 스크립트: `scripts/ci/mutation-gate.sh`. | 커버리지만으로는 단언 없는 테스트를 못 잡는다. |
| `app-audit` | `uv export`로 잠금 파일의 전체 의존성(개발 그룹 포함)을 뽑아 `pip-audit`로 검사한다. 알려진 취약점이 하나라도 있으면 실패한다. | 공급망 취약점은 예외 없이 막는다. |
| `semgrep` | `p/python`, `p/secrets`와 자체 규칙 `.semgrep/sql-injection.yml`(f-string, `%`, `.format`, `+`로 만든 SQL을 `execute`/`executemany`에 넘기면 실패). 자체 규칙은 `.semgrep/sql-injection.py`의 `ruleid`/`ok` 주석으로 먼저 테스트한다. | 파라미터 바인딩을 우회하는 SQL 조립을 기계로 금지한다. |
| `docker-build` | `Dockerfile`(멀티 스테이지, slim, 비루트 uid 10001, 기본 이미지와 uv는 다이제스트 고정)이 빌드되는지만 본다. | Trivy와 SBOM은 릴리스 파이프라인(U14)에서 켠다. |
| `ci-gate` | 위 job 전부를 `needs`로 걸고 `if: always()`로 돈다. 하나라도 `success`가 아니면(실패, 취소, **건너뜀** 포함) 실패한다. | 브랜치 보호에는 이 체크 하나만 등록하면 된다. job을 추가해도 보호 설정을 바꿀 필요가 없다. |
| `external-links` | 스케줄 실행에서만 `lychee`로 외부 링크를 검사한다. 429는 허용한다. | 외부 사이트는 일시적으로 죽는다. PR을 막지 않고 매일 한 번만 확인한다. `ci-gate`에는 포함되지 않는다. |

스케줄 실행은 위의 모든 job을 돌리되, 범위를 정할 PR이 없어서 `commits`와 `pr-size`는 검사 step을 건너뛴다.

## independent-verify

`independent-verify`는 이 워크플로의 job이 **아니다**. 별도의 검증 에이전트가 PR 헤드 SHA에 직접 게시하는 **커밋 상태(commit status)** 이고, 브랜치 보호가 `ci-gate`와 함께 요구한다. 그러므로 CI가 모두 초록이어도 이 상태가 올라오기 전까지 PR 체크 목록에 "Expected / waiting"으로 보인다. 이것은 실패가 아니다.

- 워크플로를 만들거나 이 상태를 CI에서 게시하면 안 된다. 게시 주체가 독립적이라는 점이 이 체크의 의미다.
- 새 커밋을 push하면 헤드 SHA가 바뀌므로 상태가 무효가 된다. 검증을 다시 받아야 한다.

## gate-integrity

`pull_request`로 도는 `ci.yml`은 **PR 헤드의 워크플로와 스크립트**를 실행한다. 그래서 PR이 `scripts/ci/*.sh`, 셀프테스트, `ci.yml`의 job, `ci-gate`의 `needs`를 같은 PR에서 약하게 고치면 약해진 게이트로 자기 자신을 통과시킬 수 있다(#2, #3, #14의 검증자가 확인). `.github/workflows/gate-integrity.yml`은 이 구멍을 베이스에서 한 번 더 막는다. job 이름은 `gate-integrity`이고, 브랜치 보호의 필수 체크 등록은 병합 뒤에 코디네이터가 한다.

| 단계 | 하는 일 |
|---|---|
| 베이스 체크아웃 | `pull_request.base.sha`만 체크아웃한다(`persist-credentials: false`, `contents: read`). 신뢰하는 스크립트는 전부 여기서 나온다. |
| 헤드 가져오기 | `git fetch origin pull/<n>/head`로 객체만 `refs/remotes/pr/head`에 받는다. 작업 트리에 풀지 않는다. |
| gate files report | `.github/**`, `scripts/ci/**`, `scripts/db-test.sh`, 린트 설정(`.sqlfluff`, `.squawk.toml`, `.semgrep/**` 등), `pyproject.toml`, `expectations.tsv`, `SHA256SUMS`를 건드렸으면 job 로그와 step summary에 파일 목록을 크게 찍는다. 이것만으로는 실패하지 않는다. 검증자가 어떤 게이트가 바뀌었는지 바로 보게 하려는 것이다. |
| 베이스 `pr-size.sh` | 베이스의 스크립트로 헤드의 크기를 센다. 헤드가 스크립트를 `exit 0`으로 바꿔도 소용없다. |
| 베이스 `migrations-immutable.sh` | 베이스의 스크립트로 베이스의 마이그레이션이 헤드에서 그대로인지 본다. |
| 베이스 `check-commits.sh` | 커밋 제목 규칙, 머지 커밋 금지, AI 표기 금지를 베이스의 스크립트로 검사한다. |
| `expectations-guard.sh` | `expectations.tsv`에서 행을 지우면 실패한다. 단 같은 PR이 `db/tests/*.sql`에서 그 테스트(주석이 아닌 줄에서 따옴표 바로 뒤에 정확히 그 id 토큰이 오는 문자열, 즉 `db-test.sh`가 출력 줄의 첫 토큰으로 읽는 것)도 지웠으면 허용하고 무엇이 지워졌는지 출력한다. `X1a`를 지울 때 `X1ab`는 남아 있어도 무방하고, 주석에 적힌 `'X1a'`는 존재로 치지 않으며, id 뒤가 공백이 아니라 탭이어도 존재로 친다. 헤드의 레지스트리가 없거나, 형식이 틀린 id(`T1`, `X3a`, `F11` 꼴이 아닌 것)나 중복 id가 있어도 실패한다. 베이스에서 `on_vulnerable = fail`이던 행을 다른 값으로 바꾸는 것도 실패다. |

### 헤드를 실행하지 않는다는 불변식

`pull_request_target`은 시크릿과 쓰기 토큰이 있는 컨텍스트에서 돈다. 여기서 PR 헤드의 코드를 한 줄이라도 실행하면 외부 기여자가 저장소 권한을 얻는다. 그래서 이 워크플로는 헤드를 **데이터로만** 읽는다.

- 체크아웃은 한 번이고 베이스 SHA다. `path`, `repository`, `submodules`, `working-directory`를 쓰지 않는다.
- 쓰는 action은 `actions/checkout` 하나다. `uv sync`, `pip install`, `npm ci`, `bash <헤드 경로>`는 없다.
- `run:`의 모든 줄은 읽기 전용 git(`fetch`, `diff`, `ls-tree`, `cat-file`, `log`, `rev-parse`, `show`, `rev-list`, `merge-base`)이거나 베이스 체크아웃의 `scripts/ci/<이름>.sh`다. 명령 연결(`;`, `&&`, `|`), 치환(`$(…)`, 백틱), 리다이렉션은 허용하지 않는다.
- PR 번호와 SHA는 `env:`로만 넘기고 `run:` 본문에 `${{ }}`를 쓰지 않는다.

`scripts/ci/gate-integrity-lint.sh`가 위 규칙을 YAML에서 기계로 검사하고, `gate-integrity-lint-selftest.sh`가 규칙마다 위반하는 변형 워크플로를 만들어 거부되는지(그리고 기대한 이유로 거부되는지) 증명한다. 린트는 따옴표로 감싼 키(`"uses":`), 흐름 매핑과 시퀀스(`{}`와 단어 목록 제외), 앵커, 별칭, 태그, `shell:`, `defaults:`를 거부하고, 파일 어디에 있든 `${{ }}` 표현식은 `github.event.pull_request.number`, `...base.sha`, `!cancelled()` 셋만 허용한다(env의 head 유래 값 차단). `run`의 git 옵션은 읽기 전용 허용 목록(`--no-tags`, `--name-only`, `--numstat`, `--diff-filter=` 등)만 쓸 수 있어 `--output`(파일 쓰기), `--upload-pack`, `--ext-diff`와 이들의 약어가 막힌다. 둘 다 `ci.yml`의 `workflow-lint` job에서 돈다. `expectations-guard.sh`와 `gate-files-report.sh`의 동작은 `gate-integrity-selftest.sh`가 임시 저장소에서 증명한다.

zizmor의 `dangerous-triggers`는 `pull_request_target` 자체를 경고한다. 위 불변식이 그 위험을 막으므로 `.github/zizmor.yml`에서 이 워크플로 한 곳(`gate-integrity.yml:3`, `on:` 블록)만 제외한다. 다른 워크플로나 다른 규칙은 제외하지 않는다.

### 한계

- `pull_request_target`은 항상 **베이스 브랜치의 워크플로 사본**을 실행한다. 이 파일을 새로 추가하는 PR에서는 아직 베이스에 없으므로 자기 자신에게는 돌지 않는다. 병합된 뒤에 열리는 PR부터 적용된다.
- 이 job은 `ci-gate`의 `needs`에 없다. 별도의 필수 체크로 등록해야 하며 등록은 병합 뒤에 한다.
- 헤드가 `ci.yml` 자체를 지우거나 약하게 만드는 것은 `ci-gate`가 아니라 이 job도 막지 못한다. 그 변경은 gate files report에 나타나고 검증자가 읽어야 한다.

## DB 테스트 레지스트리

`scripts/db-test.sh`는 `db/tests/expectations.tsv`를 기준으로 판정한다.

- 등록된 id가 출력에 없으면(테스트가 조용히 건너뛰어졌으면) 실패한다.
- 등록되지 않은 id가 출력되면 실패한다. 테스트를 추가하면 레지스트리에도 추가해야 한다.
- `on_vulnerable` 열이 `fail`이면 취약 스키마에서 반드시 실패해야 하고, `pass`면 반드시 통과해야 한다. X 테스트를 `pass`로 두려면 이유를 note에 적어야 한다.

취약 스키마에서도 통과하는(`on_vulnerable = pass`) 테스트의 목록과 이유는 `expectations.tsv`의 `on_vulnerable`, `note` 열이 유일한 출처다. 이 문서에 개수나 id를 복사하지 않는다.

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
| typos | 단어 `anc`, `EHR`, `NAMS`, `RTO`, `LAF`, `IIT`, `FPR`, `caf` | 논문 약어와 기호다(ancestor 함수, 전자건강기록, Neo4j Agent Memory Service 등). `caf`는 테스트 문자열 `café`를 `E'caf\u00e9'`로 적을 때 남는 어간이다. |
| gitleaks | 정규식 `family/partner`, 파일 `gatemem-2606.18829.md` | 벤치마크 설명의 산문이 `generic-api-key` 규칙에 걸린다. |
| ruff | `tests/**`에서 `S101`(assert), `PLR2004`(매직 값) | assert는 테스트의 문법이고, 기대값 리터럴이 곧 단언이다. |
| deptry | `DEP002`: `psycopg-binary` | `psycopg[binary]` extra가 끌어오는 C 가속기이고 import하지 않는다. |
| ruff | 파일 제외: `.semgrep/` | Semgrep 규칙 테스트 픽스처는 일부러 나쁜 SQL을 담고 있고 타입 주석이 필요 없다. |
| shellcheck | 없음 (`-S style`) | |
| zizmor | 없음 (기본 persona, 온라인) | |

`pr-size`에는 우회 장치가 없다. 라벨을 포함해 어떤 입력도 한도를 바꾸지 못한다. 한도(800줄)를 넘으면 규칙은 하나다. PR을 쪼갠다. 게이트 자체는 `scripts/ci/pr-size-selftest.sh`가 합성 diff로 검증한다(800줄 통과, 801줄 실패, `* -diff`와 `*.sql binary` 속성 아래 5000줄 .sql 실패, NUL 바이트가 있는 .sql 실패, `docs/research`의 5000줄 .sql 실패와 5000줄 .md 통과, 이름만 `.md`인 NUL 바이트 파일과 8000바이트 뒤에 NUL이 있는 .md와 유효하지 않은 UTF-8 .md 실패, 500 KB `.md` 10개 합계 초과 실패, `x.sql..md`와 `x.s-ql.md`와 `x.1sql.md` 실패, png 통과, CR만 있는 600 KB 파일과 한 줄 600 KB 파일 실패, 400 KB 파일 4개(합계 초과) 실패와 200 KB 파일 4개 통과, `.sql.md`와 `.py.md` 5000줄 실패와 숫자 확장자(`2606.18829.md`) 통과, 100 KB png는 550줄로 계산, 매니페스트 없는 잠금 파일 5000줄 실패와 매니페스트가 함께 바뀐 경우 통과, 매니페스트가 함께 바뀌어도 3 MiB `uv.lock`, 3 MiB `package-lock.json`, 3 MiB `requirements.txt`는 파일당 한도로, 바이너리 `uv.lock`과 유효하지 않은 UTF-8 `uv.lock`은 텍스트 조건으로, 1.5 MiB 잠금 파일 3개는 잠금 합계 한도로 실패하고 현실적인 300 KB `uv.lock` 갱신과 일반 파일 800 KB 옆의 1.5 MiB `uv.lock`은 통과, 5000줄 `0001_baseline.sql` 추가와 수정은 `schema.sql` 동반 여부와 무관하게 실패). 이 self-test는 `pr-size` job에서 매번 돈다.

속성 무시는 `git --attr-source=<빈 트리>`와 `core.attributesFile=/dev/null`, `GIT_ATTR_NOSYSTEM=1`로 한다(git 2.40 이상). 잠금 파일은 CI에서 다시 잠가 비교하는 방식 대신 매니페스트 동반 변경을 요구하는 방식을 골랐다. 다시 잠그려면 네트워크와 pip-tools/npm 해석 결과가 시점마다 달라져 게이트가 불안정해지기 때문이다. 남는 틈은 매니페스트를 건드리면서 잠금 파일을 부풀리는 경우인데, 잠금 파일 전용 바이트 한도(파일당 2 MiB, 합계 4 MiB)와 텍스트 조건이 그 크기를 막는다. 한도 안에서의 줄 수는 리뷰어가 diff로 본다.

도구 의존성에는 `npm audit`가 보고하는 알려진 취약점(개발용 린터의 파서 DoS)이 있다. 신뢰하는 입력에만 돌리고 산출물에 들어가지 않으므로 게이트로 삼지 않았다.

## 앱 게이트 (활성)

위 표의 `app-*`, `schema-drift`, `semgrep`, `docker-build`가 애플리케이션 코드 게이트다. 도구는 `uv.lock`(`uv sync --locked`)로만 설치한다. 로컬에서는 `uv sync --locked`로 CI와 같은 환경을 만든다.

- 마이그레이션: `db/migrations/NNNN_slug.sql`을 `python -m nunchi.migrate`가 순서대로 적용하고 `schema_migrations(version, checksum, applied_at)`에 기록한다. 다시 돌리면 아무것도 하지 않고, 적용된 파일이 수정되었거나 사라졌거나 적용된 것보다 앞 번호의 새 파일이 생기면 실패한다. 러너는 `db/migrations/SHA256SUMS`(`sha256sum` 형식)도 읽어 디스크의 `*.sql`과 파일 이름 집합, 해시가 모두 같은지 확인하고 다르면 아무것도 적용하지 않는다. 그래서 새 DB에서 파일만 고쳐 조용히 적용하는 길이 없다. 새 마이그레이션을 추가하면 `cd db/migrations && sha256sum *.sql > SHA256SUMS`로 매니페스트를 다시 만든다. `0001_baseline.sql`은 동결이다. `schema.sql` 변경은 항상 새 번호의 마이그레이션으로 함께 낸다. 러너는 SQL에서 주석, 문자열(`E''` 포함), 따옴표 식별자, 달러 인용을 걷어낸 뒤 최상위 `BEGIN`/`COMMIT`/`ROLLBACK`/`ABORT`/`START TRANSACTION`과 `CONCURRENTLY`가 있는 파일을 거부한다(러너가 마이그레이션마다 트랜잭션 하나를 열기 때문이다). 마이그레이션이 psycopg 오류로 실패하면 실패한 파일 이름을 담은 `MigrationError`로 바꿔 `migrate: 0002_x.sql: ...`를 stderr에 찍고 exit 1로 끝난다. DB에 연결하지 못해도 같다.
- `pr-size`: `db/migrations/`의 어떤 파일도 면제가 아니다. 동결된 `0001_baseline.sql`을 고치면 `migrations-immutable`이 먼저 실패하므로 크기 면제로 숨길 이유가 없다. 자체 테스트는 `scripts/ci/pr-size-selftest.sh`다.
- `pr-size`: `uv.lock`은 같은 PR에서 `pyproject.toml`이 바뀐 경우에만 줄 수가 면제다. 다른 잠금 파일과 같은 이유(생성 파일, 리뷰어는 매니페스트를 본다)이며, 같은 잠금 파일 바이트 한도(UTF-8 텍스트, 파일당 2 MiB, 합계 4 MiB)를 따른다.
- `app-tests`의 100% 커버리지는 스켈레톤이 작을 때의 기준이다. 코드가 늘면 `fail_under`를 낮추지 말고 diff-cover 80%를 주 게이트로 삼을지 별도 PR에서 정한다. `if __name__ == "__main__"` 줄만 커버리지에서 제외한다.

## 아직 적용 대상이 없는 게이트

| 게이트 | 도구 | 기준 |
|---|---|---|
| 컨테이너/이미지 스캔 | Trivy | 높음 이상 취약점 시 실패 |
| SBOM과 서명 | Syft로 SBOM 생성, cosign으로 서명 | 릴리스 산출물에 첨부 |
| 성능 회귀 | 벤치마크 비교 | RLS 정책 비용(`count(*)` 등)이 기준 대비 악화되면 실패 |
| API 호환성 | OpenAPI breaking-change 검사 | 하위 호환을 깨는 변경 시 실패 |
| 뮤테이션 테스트(TypeScript) | Stryker | TypeScript 코드가 생기면 켠다 |
