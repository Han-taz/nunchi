# 국내 그룹웨어·메신저 연동 API 조사 (팀 에이전트 메모리 시스템용)

조사 기준일: 2026-10-12. 공식 개발자 문서만 근거로 삼았고, 확인하지 못한 항목은 "확인 못 함"으로 표기했다. 개별 페이지에 수정일이 없는 경우가 많아 "오래됨 의심"은 별도로 표시했다.

범례: ● 공식 문서로 확인됨 / ◐ 부분 확인 또는 제약 있음 / ✘ 없음 또는 공개 근거 없음(확인 못 함 포함)

**조사 한계**

- Dooray 공식 API 문서(helpdesk.dooray.com 공유 페이지)는 JS 렌더링이라 본문을 읽지 못했다. docs.nhncloud.com Dooray 가이드도 열리지 않았다. Dooray의 1~7번은 "없다"가 아니라 "미확인"이다. 직접 열람 URL: <https://helpdesk.dooray.com/share/pages/9wWo-xwiR66BO5LGshgVTg/2939987647631384419> (출처: <https://github.com/ariri48/dooray-mcp> 가 이 위치를 안내)
- 다우오피스 OpenAPI 스펙은 고객 전용이고 API 센터(openapi.daouoffice.co.kr)는 HTTP 403이었다.
- JANDI Open API는 영업 문의 후에만 문서를 받는 것으로 보인다.
- Teams와 Slack 일부 항목은 검색 요약으로 확인했고 해당 칸에 표시했다.
- "CSAP", "망분리" 관련 정보는 대부분 언론 보도이며 공식 개발자 문서가 아니다.

---

## 1. 비교표

| 플랫폼 | 1 버튼 카드·콜백·클릭 사용자 | 2 콜백 보안 | 3 디렉터리·SCIM·SSO | 4 사용자 ID | 5 콘텐츠 소스·항목별 권한 | 6 인증 | 7 한도·거주·공공/금융 | 8 MCP·AI |
|---|---|---|---|---|---|---|---|---|
| NAVER WORKS | ◐ Flex/Carousel 등 + postback, `source.userId` 제공. Button Template의 postback 허용은 확인 못 함 | ● `X-WORKS-Signature` HMAC-SHA256(Base64). IP 공개는 확인 못 함 | ● SCIM 2.0(유료) + Directory API. IdP 여부 확인 못 함 | ● `userId`, `userExternalKey`, `email` | ◐ 게시판·드라이브 읽기 가능. 메시지 읽기 확인 못 함. 판정 전용 API 없음(사용자 토큰으로 호출 시 그 사용자 권한 적용) | ● OAuth2(사용자) + 서비스계정 JWT. 드라이브는 서비스계정 불가 | ◐ 분당 60~240/API. CSAP(2022 보도). 국내 거주 확인 못 함 | ◐ 공식 확인 못 함, 커뮤니티 MCP 있음 |
| 카카오워크 | ● Block Kit 버튼 `submit_action`, `react_user_id` 제공 | ✘ 서명 확인 못 함, IP 확인 못 함 | ◐ Okta 가이드상 SCIM+SAML, 디렉터리 조회 API. 문서 2023 이후 갱신 없음 | ● `id`, email(`identifications`) | ✘ 메시지·게시판·문서 읽기 확인 못 함 | ◐ 봇 App Key(Bearer)만. 관리자 개발자 등록·노출 필요 | ◐ 429, 예시 분당 200. 거주·CSAP 확인 못 함 | ✘ 확인 못 함 |
| Dooray | ✘ 확인 못 함(문서 미열람) | ✘ 서명·발신 IP 확인 못 함 | ◐ 공공판 LDAP(`ldap.gov-dooray.com`) 존재. SCIM·SAML·OIDC 확인 못 함 | ◐ 멤버 조회 API 있음, 필드명 확인 못 함 | ◐ 업무·위키·드라이브 등 API 존재(비공식 MCP 경유 간접 확인). 권한 판정 확인 못 함 | ◐ 개인 API 토큰. 헤더 형식 등 확인 못 함 | ◐ 공공판(gov-dooray.com), CSAP/금융 평가는 2025 보도. Rate limit 확인 못 함 | ◐ 커뮤니티 MCP 다수, 공식 확인 못 함 |
| JANDI | ✘ 버튼 없음(웹훅은 텍스트·`connectInfo`) | ◐ outgoing `token` 필드 비교. HMAC·IP 확인 못 함 | ◐ Open API로 구성원·부서·직책 동기화(1,000명 이상 팀, 영업 문의). SCIM·SSO 확인 못 함 | ◐ outgoing `writer`(id/name/email) | ✘ 확인 못 함 | ◐ Open API 키(영업 발급). 웹훅은 URL | ✘ 확인 못 함 | ✘ 확인 못 함 |
| 플로우(Flow) | ✘ 버튼 확인 못 함 | ◐ `x-flow-webhook-token` 토큰. 서명·IP 없음 | ◐ 구성원·부서 API(v1 쓰기, v2 조회). SCIM·SSO 확인 못 함 | ◐ 구성원 조회 있음, 필드명 확인 못 함 | ◐ 게시글·업무·위키·드라이브 검색은 MCP로 제공(로그인 사용자 권한 범위). OpenAPI 권한 판정 확인 못 함 | ● API Key(`x-flow-api-key`, 관리자 발급), MCP는 OAuth | ◐ MCP 사용량 한도 있음(수치 확인 못 함). 거주·공공 확인 못 함 | ● 공식 MCP(도구 39개) |
| 다우오피스 | ✘ 공개 근거 없음 | ✘ 확인 못 함 | ◐ 조직정보 API. SSO 언급만. SCIM·SAML·OIDC 확인 못 함 | ◐ 이메일 조회 언급, 필드 명세 확인 못 함 | ✘ 근태·결재·알림·Works·조직정보 5종만 확인 | ◐ 관리자 발급 API 인증키, 다우기술 문의 필요 | ◐ ISMS(2024-04~2027-04), GCP. CSAP·국내 리전 확인 못 함 | ✘ MCP 언급 없음(자체 AI 에이전트만) |
| 하이웍스 | ✘ 링크 이동형 알림만 | ✘ 확인 못 함 | ◐ 조직 연동 API(밀어넣기) + SSO. SCIM·SAML·OIDC 확인 못 함 | ● SSO 응답 `user-no`, `user-id`, `employee-no`, `extKey` | ✘ 게시판·드라이브·메신저 읽기 없음. 결재·인사 일부 조회 | ● officeToken(관리자 발급), OAuth는 deprecated. 앱 사전 검수 | ◐ 오피스당 일 1,000건. CSAP(2022 보도). 금융 적합성 확인 못 함 | ✘ 확인 못 함 |
| Teams(기준) | ● Adaptive Card `Action.Execute`, invoke에 `from.id`/`aadObjectId` | ● Bot Framework JWT 검증. 고정 IP 없음 | ● Entra SCIM 2.0(프로비저닝) | ● `aadObjectId`, MRI | ● Graph + RSC. 사용자별 판정 절차는 확인 못 함 | ● Entra 앱(client credentials) | ● Graph throttling, 한국 geo 저장 | ◐ 공식 Teams MCP(preview, 신규 비권장) |
| Slack(기준) | ● Block Kit `block_actions`, `user.id` | ● `X-Slack-Signature` HMAC-SHA256 v0, mTLS 옵션. IP 비공개 | ● SCIM 1.1/2.0(Business+) | ● Slack user ID | ● Events API, conversations.*, Real-time Search. 비마켓 앱 history 제한 | ● OAuth2 bot/user token | ● Tier별 한도, 서울 데이터 거주 지원 | ● 공식 MCP 서버 |

---

## 2. 플랫폼별 노트

### 2.1 NAVER WORKS

1. 버튼 카드: Button, List, Carousel, Image Carousel, Flexible Template 지원. 버튼 최대 10개. 출처 <https://developers.worksmobile.com/kr/docs/bot> , <https://developers.worksmobile.com/kr/docs/bot-send-button> , <https://developers.worksmobile.com/kr/docs/bot-send-flex>
2. Postback action은 `label`(기본 20자), `data`(최대 300자)를 갖고, 콜백 payload에 `source.userId`, `source.channelId`, `source.domainId`, `data`가 있어 클릭 사용자를 식별한다. 서버는 200을 반환해야 하고 실패해도 재전송하지 않는다. 출처 <https://developers.worksmobile.com/kr/docs/bot-actionobject> , <https://developers.worksmobile.com/kr/docs/bot-callback-postback> . 해당 페이지는 postback 이벤트가 Carousel, Image Carousel, Rich Menu에서 발생한다고 설명하고 Button Template 예시는 `uri`, `message`만 보여준다. 승인 카드는 Flex 또는 Carousel로 먼저 실측 검증하는 것이 안전하다.
3. 보안: `X-WORKS-Signature`(HMAC-SHA256, Base64, 키는 Bot Secret). 헤더 대소문자가 바뀔 수 있다는 경고가 있다. Secret 재발급 API 있음. 발신 IP 공개는 확인 못 함. 출처 <https://developers.worksmobile.com/kr/docs/bot-callback> , <https://developers.worksmobile.com/kr/docs/bot-api>
4. 디렉터리: SCIM 2.0(`https://www.worksapis.com/scim/v2`, `/Users`, `/Groups`)은 유료 플랜 전용, 장기 토큰 Bearer, 필터는 `eq`만, Bulk 미지원, 사용자 DELETE는 `active=false`. Directory API는 users, groups, orgunits, positions, levels 등. `userExternalKey`(최대 100자)를 OIDC `sub` 또는 사번에 매핑할 수 있다. SCIM `userName`과 `email`의 대응은 확인 못 함. 플랫폼이 IdP인지는 확인 못 함. 출처 <https://developers.worksmobile.com/kr/docs/scim> , <https://developers.worksmobile.com/kr/docs/directory> , <https://developers.worksmobile.com/kr/docs/user-get>
5. 콘텐츠·ACL: 게시판(글, 댓글, 첨부, 읽은 사람) <https://developers.worksmobile.com/kr/docs/board> , 드라이브(목록, 다운로드, 검색, 공유폴더 permissions) <https://developers.worksmobile.com/kr/docs/drive> . 드라이브는 서비스계정 토큰으로 호출할 수 없고 사용자 토큰이 필요하다("서비스 계정으로 인증하여 얻은 Access Token으로는 API를 호출할 수 없다"). ACL 상속은 사용자 토큰 위임 호출로 우회하는 방식이 되며 전용 "이 사용자가 이 항목을 볼 수 있나" API는 확인 못 함. 메시지 읽기 API도 확인 못 함.
6. 인증·한도: 사용자 OAuth2와 서비스계정(JWT) 병행 <https://developers.worksmobile.com/kr/docs/auth> . 분당 한도 무료 60, 유료 Core/Drive 240, 동시 5, 초과 429 <https://developers.worksmobile.com/kr/docs/rate-limits> . CSAP 2022 보도(공식 문서 아님, 오래됨) <https://byline.network/2022/12/1205_04/> . 국내 거주·금융 클라우드는 확인 못 함. 봇은 외부 사용자가 있는 방에 참여할 수 없다.
7. MCP: 공식 확인 못 함. 커뮤니티 `nworks`(26개 도구, 메시지·캘린더·드라이브·메일·게시판) <https://mcp.so/servers/nworks> , 코드는 검토하지 않았다.

### 2.2 카카오워크

1. 버튼: Block Kit의 Button 블록 `submit_action`(콜백) 및 `call_modal`. 콜백 필드 `type`, `action_time`, `message`, `react_user_id`, `action_name`, `value`. `react_user_id`가 클릭 사용자이며, 200 반환 필요, `application/json`만 지원. 출처 <https://docs.kakaoi.ai/kakao_work/webapireference/reactive/> , <https://docs.kakaoi.ai/kakao_work/botdevguide/bot_dev/>
2. 보안: 콜백 서명 검증과 발신 IP는 확인 못 함. 콜백 URL은 카카오워크 담당자 검증 절차만 있다. <https://docs.kakaoi.ai/kakao_work/botdevguide/process/>
3. 오래됨 의심: 릴리스 노트 최신 항목이 2023-05-10. 종료 공지는 찾지 못했으나 이후 갱신이 없다. <https://docs.kakaoi.ai/kakao_work/release_note/>
4. 디렉터리: `users.list`(최대 100, cursor), `departments.list`, `positions.list` <https://docs.kakaoi.ai/kakao_work/webapireference/users/> , <https://docs.kakaoi.ai/kakao_work/webapireference/organization/> . Okta 가이드에 SCIM + SAML 2.0이 있고 SCIM은 비즈니스 고객 전용, 비활성 사용자는 7일 후 삭제(2023-02 가이드, 오래됨). SCIM URL은 확인 못 함. <https://docs.kakaoi.ai/kakao_work/okta/>
5. 식별자: User의 `id`, `identifications`(email), `users.find_by_email` 있음. 콘텐츠: Messages는 발송·답글·반응·수정만 있고 읽기 API, 게시판, 드라이브는 확인 못 함. <https://docs.kakaoi.ai/kakao_work/webapireference/messages/>
6. 인증은 `Authorization: Bearer {APP_KEY}`. 한도는 워크스페이스 단위 분당, 429, `ratelimit-*` 헤더. <https://docs.kakaoi.ai/kakao_work/webapireference/commonguide/> . 거주·CSAP·금융 확인 못 함. MCP 확인 못 함.

### 2.3 NHN Dooray

1. 공식 문서를 읽지 못해 대부분 확인 못 함(위 한계 참고). Incoming Hook 공식 가이드 URL: <https://docs.toast.com/ko/Dooray/Messenger/ko/incoming-hook-guide/> (미열람).
2. 슬래시 커맨드 응답은 `{"text":..., "responseType":"inChannel"}` 형태라는 비공식 샘플이 있다(2017년 가이드 참조, 오래됨). 버튼과 콜백은 확인 못 함. <https://github.com/jason07289/DoorayBot>
3. 접속 IP 공지(2024-10-31 변경)와 공공판 LDAP 호스트 `ldap.gov-dooray.com`(2026-04 IP 변경 공지)이 있다. 웹훅 발신 IP, 서명은 확인 못 함. <https://doorayhelp.oc.nhncloud.com/dooray/hc/mobile/notice/62/> , <https://doorayhelp.oc.nhncloud.com/dooray/hc/mobile/notice/114/>
4. 공개 API 베이스 `api.dooray.com`에 메신저, 멤버, 업무, 캘린더, 드라이브, 위키 범주가 있다는 것은 비공식 MCP README로만 확인. 개인 토큰 발급(설정 > API), 업무 삭제 미지원 등 제약 기록. <https://github.com/ariri48/dooray-mcp> , <https://github.com/inhobaek/dooray-mcp>
5. 공공/금융: 2019 CSAP, 2025-02 금융보안원 평가 완료는 언론 보도(공식 문서 아님, 2025년 자료). <https://www.youthdaily.co.kr/mobile/article.html?no=194040> , <https://www.youthdaily.co.kr/mobile/article.html?no=186242>
6. MCP: 공식 확인 못 함, 커뮤니티 구현 다수(`ariri48/dooray-mcp` MIT, 150개 이상 도구).

### 2.4 JANDI

1. Incoming webhook: `body`(필수), `connectColor`, `connectInfo[]`. 버튼·인터랙티브 요소 없음. 256KB, 5,000자 표시 제한. <https://support.jandi.com/en/articles/connect-incoming-webhook-21bc249f>
2. Outgoing webhook은 키워드 메시지에서 트리거. 페이로드에 `token`(검증용), `teamName`, `roomName`, `writer`, `text`, `keyword`, `platform`, `ip`. 응답은 200 + JSON. HMAC과 서버 발신 IP 목록은 확인 못 함. 페이로드 `writer`와 `writerName`이 서로 불일치하고 Accept 헤더에 구 사명(`tosslab`)이 있어 문서가 오래됐을 가능성이 크다. <https://support.jandi.com/en/articles/connect-team-outgoing-webhook-aea2650b>
3. Open API는 구성원 1,000명 이상 팀 대상이며 영업 문의 후 개발·Live 키를 받는 절차이고, 구성원·부서·직책·팀 관리를 제공한다. 엔드포인트·인증·한도는 공개 문서에 없다. <https://support.jandi.com/ko/articles/admin-org-open-api-ddeaa481>
4. 콘텐츠 읽기, SCIM, SSO, 거주, MCP는 확인 못 함.

### 2.5 플로우(Flow)

1. 공식 개발자 센터 <https://api.flow.team/docs> : 알림봇, 채팅, 구성원, 부서, 게시글 API. 버튼 언급 없음.
2. 웹훅은 헤더 `x-flow-webhook-token`. 베타이며 스펙 변경 가능. 서명·IP 없음. <https://api.flow.team/docs/webhook>
3. OpenAPI 인증은 `x-flow-api-key`(조직 관리자 발급). 구성원 API는 v1에서 쓰기, v2에서 조회만. 필드명 확인 못 함.
4. 공식 MCP(도구 39개, OAuth 로그인, API 키 불필요). `flow_search`는 게시글·업무·댓글·채팅·드라이브 파일 내용까지 검색, 로그인 사용자 권한 범위로 동작한다고 명시. 사용자별·월별 한도 있으나 수치 확인 못 함. <https://api.flow.team/docs/mcp> , <https://api.flow.team/docs/mcp/tools> , <https://api.flow.team/docs/mcp/usage>
5. ACL 관점: MCP는 호출 사용자 권한으로 동작하므로 사용자별 OAuth 위임이 필요하다. 서비스 계정형 일괄 수집이 가능한지는 확인 못 함. SCIM, SSO, 거주, 공공/금융 확인 못 함.

### 2.6 다우오피스

1. API 페이지가 근태, 전자결재, 알림, Works, 조직정보 5종을 안내. 알림은 단방향 푸시, 메일 전달. 관리자가 시스템 연동에서 인증키를 발급하고 고객센터 문의로 활성화(버전 2.5.5 이상). 엔터프라이즈 고객 무료. <https://daouoffice.com/api.jsp> , <https://daouoffice.com/cloud_guide/etc/Daouoffice_OpenAPI_2025.pdf>
2. 2021년 블로그의 API 소개는 오래된 자료. <https://blog.daouoffice.com/entry/%EB%8B%A4%EC%9A%B0%EC%98%A4%ED%94%BC%EC%8A%A4%EC%99%80-%EC%97%B0%EB%8F%99-%EA%B0%80%EB%8A%A5%ED%95%9C-API%EB%A5%BC-%EC%86%8C%EA%B0%9C%ED%95%A9%EB%8B%88%EB%8B%A4>
3. 다우오피스 커넥트는 Slack과 양방향 연동해 결재·근태 승인을 Slack DM에서 처리한다고 소개(다우 자체 기능, 제3자 공개 API 아님). <https://daouoffice.com/blog/ebsc-2026-daouoffice-connect-integration>
4. ISMS 2024-04-17~2027-04-16, 인프라 GCP. CSAP·국내 리전·SCIM·콜백 서명·MCP는 확인 못 함. 자체 AI 에이전트(GPT/Gemini 선택)는 있으나 외부 에이전트 연동 언급 없음. <https://daouoffice.com/security_2.jsp> , <https://daouoffice.com/ai.jsp>

### 2.7 하이웍스

1. 알림 API `POST /office/v2/notify`: `user_list`, `message`, `link`, `mlink` 등. 클릭 시 URL 이동만 가능, 버튼 콜백 없음. 전자결재 기안 API는 `callback_url`로 상태 변경을 받지만 서명·IP 명세 없음. 출처: Postman 문서 <https://documenter.getpostman.com/view/6863253/S1TVWcri> , <https://developers.hiworks.com/docs>
2. 조직 연동 API는 외부에서 하이웍스로 조직·구성원을 밀어 넣는 방향이며 `extKey` 매핑, 이 API 사용 시 관리자 화면의 구성원 관리 기능을 못 쓴다. SSO 응답에 `user-no`, `user-id`, `employee-no`. 하이웍스가 IdP로 쓰이는지, SCIM/SAML/OIDC는 확인 못 함.
3. officeToken 인증, OAuth accessToken은 deprecated. 오피스당 일 1,000건(성공 기준). 앱은 사전 검수(영업일 약 5일), 안내 글이 오래돼 현재와 다를 수 있다. <https://developers.hiworks.com/support/article/2>
4. 인사(`/hrm/v2/users`, `/organizations`), 결재 상태 조회는 가능. 게시판·드라이브·메신저 읽기 없음. CSAP 2022 취득은 가비아 연혁(검색 요약, 원문 미열람) <https://headless-cms.gabia.com/uploads/_840b419f51.pdf> . 금융 적합성, 국내 저장, MCP는 확인 못 함.

### 2.8 기준선: Microsoft Teams

1. `Action.Execute`(Adaptive Card 1.5)가 봇에 `adaptiveCard/action` invoke를 보내고, `Action.Submit` fallback이 필요. 클릭 사용자는 `from.id`/`aadObjectId`로 식별. <https://learn.microsoft.com/en-us/microsoftteams/platform/task-modules-and-cards/cards/universal-actions-for-adaptive-cards/work-with-universal-actions-for-adaptive-cards> , <https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages>
2. 수신 요청 JWT 검증(issuer `https://api.botframework.com`, audience는 봇 App ID, 시계 오차 5분). 고정 IP는 공개하지 않고 `AzureBotService` 서비스 태그 사용. FAQ가 오래됐을 수 있음. <https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-authentication?view=azure-bot-service-4.0> , <https://learn.microsoft.com/en-us/azure/bot-service/bot-service-resources-faq-security?view=azure-bot-service-4.0>
3. Entra SCIM 2.0 프로비저닝 <https://learn.microsoft.com/en-us/entra/identity/app-provisioning/use-scim-to-provision-users-and-groups> . RSC 권한(`ChatMessage.Read.Chat`, `ChannelMessage.Read.Group`) <https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/rsc/resource-specific-consent> . Graph 한도 <https://learn.microsoft.com/en-us/graph/throttling-limits> . 한국 geo 저장은 검색 요약으로 확인 <https://learn.microsoft.com/lv-lv/microsoft-365/enterprise/m365-dr-overview?view=o365-worldwide>
4. 공식 Teams MCP는 preview이고 신규 프로젝트에는 비권장(검색 요약) <https://learn.microsoft.com/en-us/microsoft-agent-365/mcp-server-reference/teams>

### 2.9 기준선: Slack

1. `block_actions` payload에 `user.id`, `team.id`, `trigger_id`, `response_url`. <https://docs.slack.dev/reference/interaction-payloads/block_actions-payload>
2. `X-Slack-Signature` = `v0=` + HMAC-SHA256(`v0:{timestamp}:{raw body}`), 5분 초과 timestamp 거부. IP 비공개, mTLS 옵션. <https://docs.slack.dev/authentication/verifying-requests-from-slack>
3. SCIM 1.1/2.0(Business+). <https://docs.slack.dev/admins/scim-api> . Events API 3초 응답 <https://docs.slack.dev/apis/events-api/> . 2025-05-29부터 비마켓플레이스 상용 앱은 `conversations.history`가 분당 1회, `limit` 15 <https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps> . 고객 내부 앱은 영향 없음.
4. 한국(서울) 데이터 거주 지원(Business+ 이상, 프로필·채널 멤버십 제외) <https://slack.com/help/articles/360035633934> . 공식 MCP 서버 <https://docs.slack.dev/ai/slack-mcp-server> . CSAP는 확인 못 함.

---

## 3. "버튼 승인 카드" 흐름 가능 여부 그룹

**A. 네이티브 버튼 승인 가능 (카드 + 콜백으로 클릭 사용자 식별)**

- Slack, Teams: 서명/JWT 검증 후 `user.id` 또는 `aadObjectId`로 주체를 확정.
- NAVER WORKS: Flex/Carousel postback의 `source.userId`. Button Template의 postback은 확인 못 함이므로 PoC 필요.
- 카카오워크: `submit_action`의 `react_user_id`. 단 콜백 서명이 확인되지 않아 별도 보완(일회용 `value` 토큰, 서버 상태와 대조)이 필요하고, 문서가 2023년 이후 갱신이 없어 서비스 지속 여부 확인 필요.

**B. 폴백 필요 (링크로 우리 웹 승인 페이지 이동)**

- Dooray: 미확인. 공식 문서 열람 후 재판정. 확정 전까지는 폴백 설계.
- JANDI: 버튼 없음. 웹훅 텍스트 + 링크.
- 플로우: 버튼 확인 못 함. 알림봇/웹훅 + 링크.
- 다우오피스: 링크 이동형 알림(또는 결재 연동). 제3자용 봇 API 없음.
- 하이웍스: `/office/v2/notify`의 `link`/`mlink` 사용.

폴백 설계 메모: 링크는 일회용·단기 토큰으로 만들고, 웹 페이지에서 우리 OIDC 로그인으로 승인자를 확정한다. 서명이 없는 채널(카카오워크 콜백, JANDI, 플로우, 다우, 하이웍스)은 메시지 내용이 아니라 우리 서버가 발급한 토큰으로 신뢰를 세우는 것이 안전하다.

---

## 4. 콘텐츠 소스/ACL 상속 관점 요약

- 사용자 위임 토큰으로 호출해 그 사용자의 권한을 그대로 적용받는 방식이 가능한 곳: NAVER WORKS(드라이브), Flow MCP, Teams/Slack. 항목별 "접근 가능한가" 전용 판정 API가 공식 문서로 확인된 곳은 없다(Slack Real-time Search는 사용자 권한 범위 검색).
- 카카오워크, JANDI, 다우오피스, 하이웍스는 읽기 API 자체가 없거나 확인되지 않아 콘텐츠 소스로는 부적합하다고 판단된다(확인 못 함 포함).

## 5. 후속 확인 필요

1. Dooray 공식 API 문서를 브라우저로 열어 버튼·Command Hook·멤버 API·인증 헤더 확인.
2. NAVER WORKS Button Template에서의 postback 실측, 서비스계정으로 읽을 수 있는 영역 확인, SSO(IdP 역할) 관리자 가이드.
3. 카카오워크 서비스 지속 여부와 콜백 보안 사양은 담당 부서에 문의.
4. 다우오피스 API 센터 스펙은 계약 후 열람. JANDI Open API는 영업 문의.
5. 모든 국내 플랫폼의 데이터 거주, CSAP, 금융 망분리 적합성은 공식 보안 백서 또는 영업 확인이 필요하다.
