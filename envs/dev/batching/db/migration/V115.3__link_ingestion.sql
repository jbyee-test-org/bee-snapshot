-- =============================================================================
-- 0003_link_ingestion.up.sql
--   Connect ingestion (attestations) to batching (batches) via deferred FK.
-- =============================================================================
--
-- Why this lives here, not in ingestion/:
--   ingestion runs at Helm hook weight 10, batching at 15. Declaring a FK
--   from attestations.batch_id -> batches(id) inside ingestion would break
--   the standalone property of the ingestion directory (it could not run
--   before batches exists). Same rationale as audit-firm/0003 and
--   exchange/0002 for the identity links.
--
-- Pattern: ADD CONSTRAINT ... NOT VALID, then VALIDATE CONSTRAINT.
--   Postgres best practice — NOT VALID takes a fast SHARE UPDATE EXCLUSIVE
--   lock; VALIDATE CONSTRAINT takes only ROW SHARE (concurrent reads OK).
--   On Phase 1 (empty tables) both steps are instant; the pattern is kept
--   for Phase 2 consistency.
--
-- ON DELETE behaviour:
--   ON DELETE SET NULL — deleting a batch leaves the attestation rows
--   intact with batch_id = NULL, reverting their status relationship.
--   This matches the audit-trail intent (attestation rows are evidence;
--   they should survive a batch being purged for any operational reason).
--
-- Down path: drop ONLY the constraint added here. Never touch attestations
-- columns (ingestion owns them). Mirrors audit-firm/0003 down symmetry.
-- =============================================================================

-- Idempotency: see audit-firm/0003 — runner has no tracking table, so the
-- ADD is guarded by a pg_constraint existence check. VALIDATE is a no-op
-- when already validated.

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

-- attestations.batch_id -> batches(id) --------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'attestations_batch_fk'
      AND conrelid = 'attestations'::regclass
  ) THEN
    ALTER TABLE attestations
      ADD CONSTRAINT attestations_batch_fk
      FOREIGN KEY (batch_id) REFERENCES batches(id)
      ON DELETE SET NULL
      NOT VALID;
  END IF;
END $$;

ALTER TABLE attestations VALIDATE CONSTRAINT attestations_batch_fk;

COMMENT ON CONSTRAINT attestations_batch_fk ON attestations IS
  'Added by batching/0003. ON DELETE SET NULL preserves attestation audit '
  'trail if a batch is purged. batch_id shape (BYTEA(16)) already CHECKed '
  'in ingestion/0001.';

COMMIT;
