-- Forward migration 0035: 카드 관련 DB 함수를 지운다 (design v1.3 U38).
-- 카드 함수 셋은 호출자가 없다 (U30 이 앱 쪽을 지웠다). approval_card 와 review 표는 감사 기록이라 남기되 app_rw 권한을 모두 거둔다.
DROP FUNCTION app_sec.pending_dm_cards(text);
DROP FUNCTION app_sec.record_card_sent(uuid, text, text);
DROP FUNCTION app_sec.issue_dm_cards(uuid, text);
REVOKE ALL ON approval_card, review FROM app_rw;
