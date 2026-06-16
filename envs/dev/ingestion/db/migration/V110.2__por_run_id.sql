-- =============================================================================
-- 0002_por_run_id.up.sql  —  Phase 1.11 Track G · BB-POR run reference
-- =============================================================================
--
-- Adds a nullable bigint column `por_run_id` to `attestations`. When a
-- jurisdiction profile sets `zk_proof_default = true` (currently only
-- VN-VASP) or the exchange opts in via console-web for any other
-- supported profile, ingestion accepts a `por_run_id` reference into
-- BB-POR (`third_party/bb-por::por_runs.id`) instead of the inline VC
-- payload. The vc_document column stays — services/ingestion stores a
-- thin VC envelope that points at the BB-POR run for downstream verify.
--
-- BIGINT not UUID: BB-POR uses Go bigint auto-increment for por_runs.id,
-- which is the SoT for ZK opt-in attestations. We mirror its native type.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + DO $$ ... $$ guard for the index.
-- =============================================================================

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

ALTER TABLE attestations
  ADD COLUMN IF NOT EXISTS por_run_id BIGINT;

-- Sparse partial index — most attestations have NULL here. Lookups are
-- "give me the attestation for this BB-POR run" (verify path).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname  = 'attestations_por_run_idx'
  ) THEN
    EXECUTE 'CREATE INDEX attestations_por_run_idx
             ON attestations (por_run_id)
             WHERE por_run_id IS NOT NULL';
  END IF;
END $$;

COMMENT ON COLUMN attestations.por_run_id IS
  'BB-POR por_runs.id (bigint). NOT NULL when this attestation was '
  'submitted with ZK-SNARK opt-in (VN-VASP autonomous mode by default; '
  'other jurisdictions opt-in via console-web). NULL for inline VC '
  'attestations. Phase 1.11 Track G.';

COMMIT;
