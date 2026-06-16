-- slice-stubs: attest 슬라이스 out-of-slice FK 타겟 최소 스텁(#5). forward-only·idempotent.
-- public 에 생성 — 슬라이스 마이그레이션(search_path = attest, public)이 unqualified FK 를 해석.
-- 실 시스템: identity(exchanges·audit_firms)·storage(storage_pointers) 모듈 + identity/0001 의 트리거.
-- 실 마이그레이션에선 이 스텁이 진짜 모듈 + dependsOn 으로 교체(depth-wave 가 순서 보장).

CREATE TABLE IF NOT EXISTS exchanges        (id UUID PRIMARY KEY);
CREATE TABLE IF NOT EXISTS audit_firms      (id UUID PRIMARY KEY);
CREATE TABLE IF NOT EXISTS storage_pointers (id UUID PRIMARY KEY);

-- 공유 트리거 함수(실: identity/0001) — anchoring anchor_txs 가 BEFORE UPDATE 로 사용.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- dev 테넌트 행(Level 2 ingest 용 — 고정 UUID, ingestion env Secret 과 일치시킬 값).
INSERT INTO exchanges   (id) VALUES ('00000000-0000-0000-0000-000000000001') ON CONFLICT DO NOTHING;
INSERT INTO audit_firms (id) VALUES ('00000000-0000-0000-0000-000000000002') ON CONFLICT DO NOTHING;
