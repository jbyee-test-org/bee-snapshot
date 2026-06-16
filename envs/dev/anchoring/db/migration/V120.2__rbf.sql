-- =============================================================================
-- 0002_rbf.up.sql  —  Phase 1.6 Track C · Replace-By-Fee tracking
-- =============================================================================
--
-- Adds the bookkeeping anchor_txs needs to support BIP-125 RBF (mempool
-- bumpfee) when a reveal sits in `pending` longer than the configured
-- threshold. The actual bumpfee call happens in services/anchoring (see
-- src/bitcoin/rbf.rs). chain-monitor watches both the original reveal_txid
-- and replaced_by_txid so a confirmed replacement walks the original row's
-- status to `replaced` instead of `confirmed`.
--
-- Status lifecycle additions (the original `anchor_txs_status_chk` already
-- enumerates broadcasting/pending/confirmed/reorged/failed; we extend it
-- with `replaced`):
--
--   pending --(bumpfee)--> pending [bumpfee_count++, replaced_by_txid set]
--   pending --(replacement confirmed)--> replaced
--
-- The replacement chain is single-link (`replaced_by_txid` points at one
-- successor). Multi-bump is handled by overwriting the field — earlier
-- replacements are reflected via `bumpfee_count`.
--
-- Helm hook weight: 21 (after 0001 anchor_txs at weight 20).
-- =============================================================================

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

ALTER TABLE anchor_txs
  -- The 32-byte txid of the bumped replacement reveal tx (the new mempool
  -- entry created by `bumpfee`). NULL until an RBF replacement is published.
  ADD COLUMN IF NOT EXISTS replaced_by_txid BYTEA;

ALTER TABLE anchor_txs
  -- How many times this anchor has been bumped. Bumps a CHECK ceiling so
  -- a runaway loop (or a misconfigured RBF policy) gets caught at the DB.
  ADD COLUMN IF NOT EXISTS bumpfee_count INTEGER NOT NULL DEFAULT 0;

-- Replaced txid is 32 bytes when set.
ALTER TABLE anchor_txs DROP CONSTRAINT IF EXISTS anchor_txs_replaced_by_txid_length_chk;
ALTER TABLE anchor_txs
  ADD CONSTRAINT anchor_txs_replaced_by_txid_length_chk
    CHECK (replaced_by_txid IS NULL OR octet_length(replaced_by_txid) = 32);

-- Bumpfee count cap.
ALTER TABLE anchor_txs DROP CONSTRAINT IF EXISTS anchor_txs_bumpfee_count_chk;
ALTER TABLE anchor_txs
  ADD CONSTRAINT anchor_txs_bumpfee_count_chk
    CHECK (bumpfee_count >= 0 AND bumpfee_count <= 10);

-- Extend the status vocabulary with `replaced`. Drop + recreate so the
-- new value joins the CHECK set.
ALTER TABLE anchor_txs DROP CONSTRAINT IF EXISTS anchor_txs_status_chk;
ALTER TABLE anchor_txs
  ADD CONSTRAINT anchor_txs_status_chk
    CHECK (status IN ('broadcasting', 'pending', 'confirmed', 'reorged', 'failed', 'replaced'));

-- A `replaced` row must carry the successor txid. Without this constraint
-- a buggy chain-monitor write could mark a row replaced without recording
-- which tx replaced it, breaking the audit chain.
ALTER TABLE anchor_txs DROP CONSTRAINT IF EXISTS anchor_txs_replaced_consistency_chk;
ALTER TABLE anchor_txs
  ADD CONSTRAINT anchor_txs_replaced_consistency_chk
    CHECK (
      (status = 'replaced' AND replaced_by_txid IS NOT NULL)
      OR status <> 'replaced'
    );

-- Index for chain-monitor: "find me anchors that have been replaced and
-- need their successor's confirmation polled".
CREATE INDEX IF NOT EXISTS anchor_txs_replaced_by_txid_idx
  ON anchor_txs (replaced_by_txid) WHERE replaced_by_txid IS NOT NULL;

-- Index for the RBF monitor: "give me pending anchors older than N minutes".
-- Reuses the worker_queue index when status='pending'; this dedicated index
-- is for the RBF policy task that scans by created_at within the pending set.
CREATE INDEX IF NOT EXISTS anchor_txs_pending_age_idx
  ON anchor_txs (created_at) WHERE status = 'pending';

COMMENT ON COLUMN anchor_txs.replaced_by_txid IS
  'BIP-125 RBF: the 32-byte txid that replaced this reveal in the mempool. '
  'NULL until a bumpfee call publishes a replacement. Set by services/anchoring.';
COMMENT ON COLUMN anchor_txs.bumpfee_count IS
  'How many times this anchor has been fee-bumped. Capped at 10 by CHECK to '
  'catch runaway RBF loops. Ops alarm fires above 3.';

COMMIT;
