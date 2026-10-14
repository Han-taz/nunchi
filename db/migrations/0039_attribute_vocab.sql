-- Forward migration 0039: 주제마다 속성 어휘표를 둔다 (design v1.4 U41).
-- memory.attribute 는 그대로 키이고, 그 키가 무엇을 묻는지(question)를 이 표가 적어 둔다.
-- 같은 키는 구성상 같은 주제다. 새 키는 register_attribute 로만 늘고, 같은 질문인지는 서버가 질문끼리 비교해 정한다.
CREATE TABLE attribute_vocab (
  tenant_id uuid NOT NULL,
  store_id uuid NOT NULL,
  subject_id uuid NOT NULL,
  key text NOT NULL,        -- app_sec.norm_text() 형태의 짧은 슬러그. memory.attribute 가 이 값을 쓴다
  label text NOT NULL,      -- 사람이 읽는 이름
  question text NOT NULL,   -- 이 속성이 답하는 한 줄 질문 (예: '라이트 테마 border 색의 대비 비율')
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, subject_id, key),
  CONSTRAINT vocab_store_same_tenant FOREIGN KEY (tenant_id, store_id) REFERENCES store (tenant_id, id),
  CONSTRAINT vocab_subject_same_tenant FOREIGN KEY (tenant_id, subject_id) REFERENCES entity (tenant_id, id),
  CONSTRAINT vocab_key_shape CHECK (key = app_sec.norm_text(key) AND char_length(key) BETWEEN 1 AND 40),
  CONSTRAINT vocab_label_shape CHECK (char_length(label) BETWEEN 1 AND 80),
  CONSTRAINT vocab_question_shape CHECK (char_length(question) BETWEEN 1 AND 200)
);

ALTER TABLE attribute_vocab ENABLE ROW LEVEL SECURITY;
ALTER TABLE attribute_vocab FORCE ROW LEVEL SECURITY;
CREATE POLICY attribute_vocab_read ON attribute_vocab FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND store_id IN (SELECT app_sec.my_stores('reader'))
);
GRANT SELECT ON attribute_vocab TO app_rw;

-- 새 어휘 항목: contributor 만 쓴다. 이미 있는 키는 그대로 두고 false 를 돌려준다 (재시도에 안전).
CREATE FUNCTION app_sec.register_attribute(p_store uuid, p_subject uuid, p_key text, p_label text, p_question text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  v_rows integer;
BEGIN
  IF app_sec.ctx_user() IS NULL OR p_store NOT IN (SELECT app_sec.my_stores('contributor')) THEN
    RAISE EXCEPTION 'not a contributor of the store' USING ERRCODE = '42501';
  END IF;
  INSERT INTO attribute_vocab (tenant_id, store_id, subject_id, key, label, question)
  VALUES (app_sec.ctx_tenant(), p_store, p_subject, app_sec.norm_text(p_key), btrim(p_label), btrim(p_question))
  ON CONFLICT (store_id, subject_id, key) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END $$;

GRANT EXECUTE ON FUNCTION app_sec.register_attribute(uuid, uuid, text, text, text) TO app_rw;
