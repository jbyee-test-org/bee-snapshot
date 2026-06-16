-- =============================================================================
-- 0001_anchor_txs.up.sql  —  BitCert Anchoring Domain · Bitcoin Commit-Reveal
-- =============================================================================
--
-- Owner service (writes): services/anchoring  (Phase 2 Real; Stub in Phase 1)
-- Readers:                services/chain-monitor (updates confirmations on new
--                         blocks), services/verification (resolves a batch to
--                         its on-chain anchor), services/reporting.
--
-- Helm hook weight: 20  (runs AFTER batching (15) so the inline FK
--                        batch_id -> batches(id) resolves; BEFORE audit-trail
--                        (25) and chain-monitor (30).)
--
-- Tenant posture:
--   NO tenant column. Anchors are cross-tenant by construction (one anchor
--   covers a cross-tenant batch — see batching/0001 header). Tenant
--   isolation at query time joins back through batches -> attestations ->
--   exchanges.
--
-- OP_RETURN v30 witness structure (proprietary):
--   The actual Taproot commit-reveal payload construction lives in the
--   anchoring-engine crate and is PATENT-PROTECTED (see CLAUDE.md §1.5).
--   This migration stores only the resulting txids / block metadata / MuSig2
--   aggregate signature — nothing about the v30 witness encoding itself.
--
-- Reorg handling:
--   When chain-monitor detects a reorg that unwinds the anchor block, the
--   status transitions confirmed -> reorged, reorged_at is stamped, and
--   services/anchoring either re-broadcasts or assembles a fresh anchor.
--   The row is NOT deleted — auditors need the history.
-- =============================================================================

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

CREATE TABLE IF NOT EXISTS anchor_txs (
  id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id            BYTEA        NOT NULL REFERENCES batches(id),
  network             TEXT         NOT NULL,

  commit_txid         BYTEA,
  reveal_txid         BYTEA,
  block_height        BIGINT,
  block_hash          BYTEA,
  confirmations       INTEGER      NOT NULL DEFAULT 0,
  fee_paid_sats       BIGINT,

  status              TEXT         NOT NULL DEFAULT 'broadcasting',
  musig2_signature    BYTEA,

  broadcast_at        TIMESTAMPTZ,
  confirmed_at        TIMESTAMPTZ,
  reorged_at          TIMESTAMPTZ,

  created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  -- batch_id shape (same BYTEA(16) invariant as batches.id).
  CONSTRAINT anchor_txs_batch_id_length_chk
    CHECK (octet_length(batch_id) = 16),

  -- Bitcoin network vocabulary.
  CONSTRAINT anchor_txs_network_chk
    CHECK (network IN ('mainnet', 'testnet', 'regtest', 'signet')),

  -- Txids are 32-byte SHA-256 double-hashes.
  CONSTRAINT anchor_txs_commit_txid_length_chk
    CHECK (commit_txid IS NULL OR octet_length(commit_txid) = 32),
  CONSTRAINT anchor_txs_reveal_txid_length_chk
    CHECK (reveal_txid IS NULL OR octet_length(reveal_txid) = 32),

  -- Block height non-negative when set.
  CONSTRAINT anchor_txs_block_height_nonneg_chk
    CHECK (block_height IS NULL OR block_height >= 0),

  -- Block hash is 32 bytes when set.
  CONSTRAINT anchor_txs_block_hash_length_chk
    CHECK (block_hash IS NULL OR octet_length(block_hash) = 32),

  -- Confirmation counter.
  CONSTRAINT anchor_txs_confirmations_nonneg_chk
    CHECK (confirmations >= 0),

  -- Fee is positive when set (zero-fee txs are not RBF-safe for anchoring).
  CONSTRAINT anchor_txs_fee_positive_chk
    CHECK (fee_paid_sats IS NULL OR fee_paid_sats > 0),

  -- Status lifecycle:
  --   broadcasting -> pending (seen in mempool) -> confirmed
  --                                           \-> reorged (unwound)
  --                      \-> failed (rejected / feemarket lost)
  CONSTRAINT anchor_txs_status_chk
    CHECK (status IN ('broadcasting', 'pending', 'confirmed', 'reorged', 'failed')),

  -- Schnorr signature for Taproot key-path spend = 64 bytes.
  -- MuSig2 aggregates to a single Schnorr sig.
  CONSTRAINT anchor_txs_musig2_signature_length_chk
    CHECK (musig2_signature IS NULL OR octet_length(musig2_signature) = 64),

  -- Confirmed implies block_height AND reveal_txid present.
  CONSTRAINT anchor_txs_confirmed_consistency_chk
    CHECK (
      (status = 'confirmed'
         AND block_height IS NOT NULL
         AND reveal_txid  IS NOT NULL)
      OR status <> 'confirmed'
    ),

  -- Reorged implies reorged_at stamped.
  CONSTRAINT anchor_txs_reorged_consistency_chk
    CHECK (
      (status = 'reorged' AND reorged_at IS NOT NULL)
      OR status <> 'reorged'
    )
);

-- Indexes -------------------------------------------------------------------
-- "Give me all anchor attempts for batch X" (reporting + reorg recovery).
CREATE INDEX IF NOT EXISTS anchor_txs_batch_idx
  ON anchor_txs (batch_id);

-- Txid lookup: chain-monitor maps an observed confirmation back to us by
-- reveal_txid. Partial because commit_txid alone is not enough.
CREATE INDEX IF NOT EXISTS anchor_txs_reveal_txid_idx
  ON anchor_txs (reveal_txid) WHERE reveal_txid IS NOT NULL;

-- Worker queue: things that still need attention.
CREATE INDEX IF NOT EXISTS anchor_txs_worker_queue_idx
  ON anchor_txs (status, created_at)
  WHERE status IN ('broadcasting', 'pending', 'failed', 'reorged');

-- Block-height window queries (reorg audits).
CREATE INDEX IF NOT EXISTS anchor_txs_block_height_idx
  ON anchor_txs (block_height) WHERE block_height IS NOT NULL;

-- updated_at trigger (shared function from identity/0001).
DROP TRIGGER IF EXISTS anchor_txs_set_updated_at ON anchor_txs;
CREATE TRIGGER anchor_txs_set_updated_at
  BEFORE UPDATE ON anchor_txs
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE anchor_txs IS
  'Bitcoin L1 commit-reveal transactions anchoring Merkle batches. One row '
  'per anchor attempt per batch. Patent-sensitive witness encoding is '
  'handled in anchoring-engine crate — this table stores only resulting '
  'txids / block metadata / MuSig2 aggregate signature. Tenant-agnostic; '
  'tenant join via batches -> merkle_proofs -> attestations.';
COMMENT ON COLUMN anchor_txs.commit_txid IS
  'SHA-256d txid of the Taproot commit transaction (locks the funding). '
  '32 bytes. NULL until broadcast succeeds.';
COMMENT ON COLUMN anchor_txs.reveal_txid IS
  'SHA-256d txid of the reveal transaction that publishes the OP_RETURN v30 '
  'payload + witness. 32 bytes. NULL until broadcast succeeds.';
COMMENT ON COLUMN anchor_txs.musig2_signature IS
  '64-byte BIP-340 Schnorr signature aggregated via MuSig2 over the reveal '
  'tx sighash. Populated once the co-signer ceremony completes.';
COMMENT ON COLUMN anchor_txs.confirmations IS
  'Rolling confirmation count maintained by services/chain-monitor. Reset to '
  '0 on reorg. Anchors reach "confirmed" at configured depth (Phase 1: 6 '
  'confs mainnet, 2 confs testnet/signet).';

-- TODO(Phase-2): add view v_anchored_batches joining batches + anchor_txs
-- on batch_id, filtered to status='confirmed'. Deferred here to keep the
-- migration minimal; services/verification queries the tables directly in
-- Phase 1.

COMMIT;
