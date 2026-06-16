-- =============================================================================
-- 0001_batches.up.sql  —  BitCert Batching Domain · Merkle Batches
-- =============================================================================
--
-- Owner service (writes): services/batching  (Phase 2 Real; Stub in Phase 1)
-- Readers:                services/anchoring (picks status='sealed' batches to
--                         commit-reveal on Bitcoin), services/verification
--                         (rebuilds Merkle root from leaves + proofs),
--                         services/reporting, apps/portal-web.
--
-- Helm hook weight: 15  (runs AFTER ingestion (10) so the batching/0003 link
--                        file can ALTER attestations; BEFORE anchoring (20)
--                        since anchoring.anchor_txs.batch_id -> batches(id).)
--
-- =============================================================================
-- DELIBERATE DEPARTURE FROM CLAUDE.md TENANT-FK RULE — READ THIS
-- =============================================================================
-- The standing hard-constraint is "every product-domain table carries a
-- tenant FK (exchange_id or audit_firm_id) NOT NULL + indexed". `batches`
-- INTENTIONALLY HAS NO TENANT COLUMN.
--
-- Rationale:
--   * A Merkle batch aggregates attestations from MULTIPLE exchanges into
--     ONE on-chain anchor. This is the core fee-amortisation feature of the
--     platform — one commit-reveal pair on Bitcoin L1 carries attestations
--     from ~10-500 tenants, turning a per-tenant anchor cost of $50-200
--     into a fraction of that per tenant.
--   * Forcing a single tenant dimension on batches would either (a) break
--     cross-tenant batching and destroy the cost model, or (b) require a
--     synthetic "platform" tenant which defeats the safety intent of the
--     rule.
--
-- How tenant isolation is preserved end-to-end:
--   * attestations.exchange_id is the canonical tenant key and IS NOT NULL
--     + FK + indexed (ingestion/0001).
--   * merkle_proofs.attestation_id -> attestations(id) — tenant reachable
--     via the join. Row-level tenant filter in reporting/verification uses
--     `attestations.exchange_id = $1` with a JOIN through merkle_proofs /
--     batches, not a direct batches.exchange_id column.
--   * Any "list my batches" endpoint must SELECT DISTINCT batches.id FROM
--     batches JOIN attestations ... WHERE attestations.exchange_id = $1 —
--     which is what services/reporting does.
--
-- Documented in ingestion/README.md §4 and deploy/migrations/README.md §1
-- as well as the session log at
-- docs/session-log/2026-04-21-product-migrations.md.
-- =============================================================================
--
-- Primary key:
--   id BYTEA with CHECK octet_length = 16. This is UUIDv7 raw bytes, matching
--   vc_models::BatchId. Application code (services/batching) generates the
--   UUIDv7 via the vc-models crate; the DB does NOT default this PK. We
--   deliberately do NOT use UUID here so the column type matches the on-wire
--   batch id exactly.
-- =============================================================================

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

CREATE TABLE IF NOT EXISTS batches (
  id            BYTEA        PRIMARY KEY,
  merkle_root   BYTEA        NOT NULL,
  leaf_count    INT          NOT NULL,
  status        TEXT         NOT NULL DEFAULT 'assembling',
  sealed_at     TIMESTAMPTZ,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  -- 16-byte UUIDv7 raw bytes, matches vc_models::BatchId. Application-
  -- generated (no DB default — see header).
  CONSTRAINT batches_id_length_chk
    CHECK (octet_length(id) = 16),

  -- Merkle root is SHA-256 = 32 bytes.
  CONSTRAINT batches_merkle_root_length_chk
    CHECK (octet_length(merkle_root) = 32),

  -- Non-empty batch.
  CONSTRAINT batches_leaf_count_positive_chk
    CHECK (leaf_count > 0),

  -- Status lifecycle:
  --   assembling -> sealed -> anchoring -> confirmed
  --                              \->       failed
  -- `failed` is terminal; re-anchor requires a new batch id.
  CONSTRAINT batches_status_chk
    CHECK (status IN ('assembling', 'sealed', 'anchoring', 'confirmed', 'failed')),

  -- sealed_at set iff status has passed 'assembling'.
  CONSTRAINT batches_sealed_consistency_chk
    CHECK (
      (status IN ('sealed', 'anchoring', 'confirmed', 'failed') AND sealed_at IS NOT NULL)
      OR status = 'assembling'
    )
);

-- Indexes -------------------------------------------------------------------
-- Anchoring worker queue: "sealed batches ready for commit-reveal" plus
-- "failed" for retry runbook.
CREATE INDEX IF NOT EXISTS batches_worker_queue_idx
  ON batches (status) WHERE status IN ('assembling', 'sealed', 'anchoring', 'failed');

-- Reporting / admin listing.
CREATE INDEX IF NOT EXISTS batches_created_idx
  ON batches (created_at DESC);

COMMENT ON TABLE batches IS
  'Merkle batches aggregating attestations across tenants for amortised '
  'Bitcoin L1 anchoring. INTENTIONALLY tenant-agnostic — tenant dimension '
  'lives on attestations.exchange_id (join via merkle_proofs.attestation_id). '
  'See header comment of this migration for rationale.';
COMMENT ON COLUMN batches.id IS
  'UUIDv7 raw bytes (16B), matches vc_models::BatchId wire form. '
  'APPLICATION-GENERATED by services/batching — no DB default.';
COMMENT ON COLUMN batches.merkle_root IS
  'SHA-256 Merkle root over leaves in canonical order. Committed on-chain '
  'inside the OP_RETURN v30 envelope at anchor time. 32 bytes.';

COMMIT;
