-- =============================================================================
-- 0003_rbf_raw_replacement.up.sql  —  Phase 1.9.1 · Wallet-free RBF columns
-- =============================================================================
--
-- Problem this migration solves
-- -----------------------------
-- Phase 1.6 Track C wired RBF through bitcoind's `bumpfee` RPC. That RPC
-- only operates on transactions the bitcoind wallet itself signed and
-- broadcast, but our reveal tx is signed in-process (BIP-341 key-path
-- spend over a commit output owned by `services/anchoring`'s own
-- keypair), so bitcoind responds with `-5 Invalid or non-wallet
-- transaction id`.
--
-- Phase 1.9.1 replaces that path with a raw-replacement implementation:
-- the service rebuilds the reveal tx with a higher fee, re-signs it
-- locally, and broadcasts via `sendrawtransaction`. To do this offline
-- the service needs to remember the inputs it would otherwise re-derive
-- by querying bitcoind, plus the original signed reveal tx so the next
-- bump round-trips deterministically.
--
-- New columns on `anchor_txs`
-- ---------------------------
-- commit_vout              INTEGER  — the output index inside the commit
--                                     tx that the reveal spends. Always 0
--                                     today (BuiltCommitReveal lays it
--                                     out as output[0]); persisted so a
--                                     future change to the layout can
--                                     bump the value without breaking
--                                     historical anchors.
-- commit_output_value_sats BIGINT   — the sats value of that output. fee
--                                     budget = commit_output_value_sats
--                                     - new_fee on every bump.
-- reveal_raw_hex           TEXT     — the fully-signed reveal tx hex at
--                                     last broadcast. Re-deserialised on
--                                     each bump to inherit the OP_RETURN
--                                     payload + change script verbatim;
--                                     only the change output amount and
--                                     the witness signature change
--                                     between successive replacements.
-- reveal_fee_sats          BIGINT   — fee paid by the broadcast reveal.
--                                     Distinct from `fee_paid_sats`
--                                     (which records the FIRST broadcast
--                                     fee per the audit lineage); this
--                                     column is the running fee that
--                                     `rbf::bump_anchor` reads + writes.
--
-- Idempotency
-- -----------
-- Migration runner has no tracking table (CLAUDE.md feedback memory
-- `feedback_migrations_idempotent`); every .up.sql re-runs on every
-- helm upgrade. All ALTER statements use `ADD COLUMN IF NOT EXISTS`
-- and `DROP CONSTRAINT IF EXISTS` before re-adding so re-runs are safe.
--
-- Helm hook weight: 22 (after 0002_rbf at weight 21).
-- =============================================================================

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

ALTER TABLE anchor_txs
  ADD COLUMN IF NOT EXISTS commit_vout INTEGER;

ALTER TABLE anchor_txs
  ADD COLUMN IF NOT EXISTS commit_output_value_sats BIGINT;

ALTER TABLE anchor_txs
  ADD COLUMN IF NOT EXISTS reveal_raw_hex TEXT;

ALTER TABLE anchor_txs
  ADD COLUMN IF NOT EXISTS reveal_fee_sats BIGINT;

-- vout must be a non-negative integer when set.
ALTER TABLE anchor_txs DROP CONSTRAINT IF EXISTS anchor_txs_commit_vout_chk;
ALTER TABLE anchor_txs
  ADD CONSTRAINT anchor_txs_commit_vout_chk
    CHECK (commit_vout IS NULL OR commit_vout >= 0);

-- Output value strictly positive when set (zero / negative would fail
-- bitcoind's dust check on the rebuild path).
ALTER TABLE anchor_txs DROP CONSTRAINT IF EXISTS anchor_txs_commit_output_value_chk;
ALTER TABLE anchor_txs
  ADD CONSTRAINT anchor_txs_commit_output_value_chk
    CHECK (commit_output_value_sats IS NULL OR commit_output_value_sats > 0);

-- Running fee strictly positive when set.
ALTER TABLE anchor_txs DROP CONSTRAINT IF EXISTS anchor_txs_reveal_fee_chk;
ALTER TABLE anchor_txs
  ADD CONSTRAINT anchor_txs_reveal_fee_chk
    CHECK (reveal_fee_sats IS NULL OR reveal_fee_sats > 0);

COMMENT ON COLUMN anchor_txs.commit_vout IS
  'Output index of the commit tx the reveal spends. Filled at broadcast '
  'so the wallet-free RBF rebuilder (Phase 1.9.1) does not have to query '
  'bitcoind to relocate it.';
COMMENT ON COLUMN anchor_txs.commit_output_value_sats IS
  'sats value of the commit output the reveal spends. Used by '
  'rbf::bump_anchor to compute the new reveal change = '
  'commit_output_value_sats - new_fee.';
COMMENT ON COLUMN anchor_txs.reveal_raw_hex IS
  'Last-broadcast reveal tx hex (signed). Updated on every successful RBF '
  'so the next bump deserialises the current mempool tx, not the '
  'original one.';
COMMENT ON COLUMN anchor_txs.reveal_fee_sats IS
  'Fee in sats paid by the last-broadcast reveal. Phase 1.9.1 RBF base '
  'fee — distinct from fee_paid_sats which retains the first-broadcast '
  'fee for audit lineage.';

COMMIT;
