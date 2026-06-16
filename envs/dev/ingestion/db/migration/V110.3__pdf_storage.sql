-- =============================================================================
-- 0003_pdf_storage.up.sql  —  Phase 1.13 Track E · PDF upload + widget meta
-- =============================================================================
--
-- Adds six columns to `attestations` so the Phase 1.13 PDF-upload flow
-- (console-web /exchange/attestations/new → services/storage signed-URL →
-- services/ingestion auto-VC) plus the Phase 1.14 widget API has every field
-- it needs without a second-pass migration.
--
-- Column-by-column:
--
--   pdf_storage_pointer_id      — FK → storage_pointers(id). The PDF audit
--                                 report artifact uploaded via signed-URL.
--                                 Distinct from the existing nullable
--                                 `storage_pointer_id`: the latter pre-dates
--                                 1.13 and is used by the legacy direct-VC
--                                 flow (where the client supplied an already-
--                                 hashed report). 1.13 flow populates the new
--                                 PDF-specific column to make the data lineage
--                                 explicit. Existing rows leave it NULL.
--
--   batch_mode                  — `single` = anchor this attestation alone
--                                 (1-leaf Merkle, immediate flush); `shared` =
--                                 cross-tenant Merkle batch (opt-in, GDPR
--                                 consent recorded in audit_log). Default
--                                 `single` per plan §3.1 (safe default).
--
--   snapshot_at                 — Wall-clock instant the snapshot was taken
--                                 by the auditor / exchange. Distinct from
--                                 `submitted_at` (DB ingest time). Surfaced
--                                 in widget SUMMARY tab.
--
--   btc_block_height            — Bitcoin block height at the time of
--                                 ingestion (current chain tip from
--                                 services/chain-monitor). Phase 1.14 widget
--                                 displays this as "anchored at block N".
--                                 Differs from `anchor_txs.block_height`
--                                 (which is set when the reveal tx confirms);
--                                 this column is the snapshot tip, used for
--                                 freshness UX before confirmation.
--
--   asset_summary               — JSONB array of {asset, total_owed, on_chain,
--                                 reserve_ratio} entries. Populated from
--                                 console-web upload form. The widget renders
--                                 this verbatim — keeping it as JSONB lets
--                                 the form evolve without a schema migration.
--                                 Default `[]` so Phase 1.14 widget does not
--                                 need NULL handling.
--
--   audit_firm_display_name     — Denormalised display name copied from
--                                 audit_firms at ingest time. Avoids a join
--                                 in the public widget API path (which is
--                                 anonymous and rate-limited).
--
-- Idempotent (per memory `feedback_migrations_idempotent.md`): every column
-- ADD uses IF NOT EXISTS, the CHECK constraint is guarded by a
-- pg_constraint lookup, and the new index is guarded by pg_indexes.
-- =============================================================================

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

ALTER TABLE attestations
  ADD COLUMN IF NOT EXISTS pdf_storage_pointer_id UUID REFERENCES storage_pointers(id);

ALTER TABLE attestations
  ADD COLUMN IF NOT EXISTS batch_mode TEXT NOT NULL DEFAULT 'single';

ALTER TABLE attestations
  ADD COLUMN IF NOT EXISTS snapshot_at TIMESTAMPTZ;

ALTER TABLE attestations
  ADD COLUMN IF NOT EXISTS btc_block_height BIGINT;

ALTER TABLE attestations
  ADD COLUMN IF NOT EXISTS asset_summary JSONB NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE attestations
  ADD COLUMN IF NOT EXISTS audit_firm_display_name TEXT;

-- batch_mode vocabulary guard.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'attestations_batch_mode_chk'
  ) THEN
    ALTER TABLE attestations
      ADD CONSTRAINT attestations_batch_mode_chk
      CHECK (batch_mode IN ('single', 'shared'));
  END IF;
END $$;

-- btc_block_height non-negative guard (chain tip is always >= 0).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'attestations_btc_block_height_chk'
  ) THEN
    ALTER TABLE attestations
      ADD CONSTRAINT attestations_btc_block_height_chk
      CHECK (btc_block_height IS NULL OR btc_block_height >= 0);
  END IF;
END $$;

-- Lookup index for the PDF-specific FK ("attestations referencing this
-- storage pointer"). Sparse — most rows have NULL.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname  = 'attestations_pdf_storage_pointer_idx'
  ) THEN
    EXECUTE 'CREATE INDEX attestations_pdf_storage_pointer_idx
             ON attestations (pdf_storage_pointer_id)
             WHERE pdf_storage_pointer_id IS NOT NULL';
  END IF;
END $$;

-- Batch-mode dispatch index — the batching worker queries
-- "pending + batch_mode='single'" for immediate flush; the old
-- attestations_worker_queue_idx stays in place for the broader pending scan.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname  = 'attestations_single_pending_idx'
  ) THEN
    EXECUTE 'CREATE INDEX attestations_single_pending_idx
             ON attestations (submitted_at)
             WHERE status = ''pending'' AND batch_mode = ''single''';
  END IF;
END $$;

COMMENT ON COLUMN attestations.pdf_storage_pointer_id IS
  'Phase 1.13: FK to the PDF audit report uploaded via signed-URL flow. '
  'Distinct from storage_pointer_id (legacy direct-VC flow). NULL for '
  'pre-1.13 attestations and for ZK-only flows (por_run_id non-NULL).';
COMMENT ON COLUMN attestations.batch_mode IS
  'Phase 1.13: single = anchor alone (1-leaf Merkle, immediate); shared = '
  'cross-tenant Merkle (opt-in, GDPR consent recorded in audit_log). Default '
  'single — safe default per plan §3.1.';
COMMENT ON COLUMN attestations.snapshot_at IS
  'Phase 1.14 widget meta: wall-clock instant the auditor took the snapshot. '
  'Distinct from submitted_at (DB ingest time).';
COMMENT ON COLUMN attestations.btc_block_height IS
  'Phase 1.14 widget meta: Bitcoin chain tip height at ingestion time (from '
  'services/chain-monitor). NOT the confirmation block height — that lives '
  'in anchor_txs.block_height once the reveal tx confirms.';
COMMENT ON COLUMN attestations.asset_summary IS
  'Phase 1.14 widget meta: JSONB array of per-asset {asset, total_owed, '
  'on_chain, reserve_ratio} rows. Rendered verbatim by the widget. Default '
  '[] so the public widget API never needs NULL handling.';
COMMENT ON COLUMN attestations.audit_firm_display_name IS
  'Phase 1.14 widget meta: denormalised display name from audit_firms at '
  'ingest time. Avoids a tenant-table join on the anonymous widget API path.';

COMMIT;
