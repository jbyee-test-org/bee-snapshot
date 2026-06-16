-- =============================================================================
-- 0002_merkle_proofs.up.sql  —  BitCert Batching Domain · Merkle Inclusion Proofs
-- =============================================================================
--
-- Owner service (writes): services/batching
-- Readers:                services/verification (stateless inclusion check),
--                         services/reporting, apps/portal-web.
--
-- One row per (batch, attestation). Stores the sibling-hash path and
-- direction markers needed to rebuild the Merkle root from a single leaf.
--
-- vc-models / merkle-batching crate mapping:
--   sibling_path : hex-encoded 32-byte strings   -> merkle_batching::MerkleProof::siblings
--   directions   : array of "left" | "right"     -> merkle_batching::Direction
--
-- Encoding choice (JSONB over BYTEA[]):
--   * JSONB gives us jsonb_array_length() as a CHECK subject and makes
--     introspection queries trivial from psql.
--   * Phase 1 volumes: 500 proofs per batch * 20-32 siblings each * 32 bytes
--     = ~320 KB per batch — immaterial vs. a BYTEA[] which would save
--     perhaps 10-20% space at the cost of readability and CHECK-ability.
--
-- Invariants:
--   * jsonb_array_length(sibling_path) = jsonb_array_length(directions)
--     — Merkle proof length and direction length must match (from
--     merkle_batching::MerkleProof construction).
--   * PRIMARY KEY (batch_id, attestation_id) — one proof per leaf per batch.
--     Prevents duplicate proofs and guards against webhook replays.
-- =============================================================================

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

CREATE TABLE IF NOT EXISTS merkle_proofs (
  attestation_id   UUID         NOT NULL REFERENCES attestations(id) ON DELETE CASCADE,
  batch_id         BYTEA        NOT NULL REFERENCES batches(id),
  leaf_index       INTEGER      NOT NULL,
  sibling_path     JSONB        NOT NULL,
  directions       JSONB        NOT NULL,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  -- Composite PK: one proof per leaf per batch.
  PRIMARY KEY (batch_id, attestation_id),

  -- batch_id is UUIDv7 raw bytes, same shape as batches(id).
  CONSTRAINT merkle_proofs_batch_id_length_chk
    CHECK (octet_length(batch_id) = 16),

  -- Leaf index is a 0-based position in the Merkle tree's leaf array.
  CONSTRAINT merkle_proofs_leaf_index_nonneg_chk
    CHECK (leaf_index >= 0),

  -- Merkle invariant: sibling_path and directions have the same length.
  -- Matches merkle_batching::MerkleProof where each step contributes one
  -- sibling hash and one direction marker.
  CONSTRAINT merkle_proofs_path_direction_length_match_chk
    CHECK (jsonb_array_length(sibling_path) = jsonb_array_length(directions)),

  -- sibling_path must be a JSON array.
  CONSTRAINT merkle_proofs_sibling_path_is_array_chk
    CHECK (jsonb_typeof(sibling_path) = 'array'),

  -- directions must be a JSON array.
  CONSTRAINT merkle_proofs_directions_is_array_chk
    CHECK (jsonb_typeof(directions) = 'array')
);

-- Index -------------------------------------------------------------------
-- "Give me the proof for attestation X" (no batch id required up front —
-- useful for verification endpoints that start from an attestation).
CREATE INDEX IF NOT EXISTS merkle_proofs_attestation_idx
  ON merkle_proofs (attestation_id);

COMMENT ON TABLE merkle_proofs IS
  'Per-attestation Merkle inclusion proofs within a batch. Stateless '
  'verification reconstructs the root from (leaf, sibling_path, directions). '
  'Owner: services/batching. Read-heavy; appended once per leaf at batch seal.';
COMMENT ON COLUMN merkle_proofs.sibling_path IS
  'JSON array of hex-encoded 32-byte sibling hashes, bottom-up, matching '
  'merkle_batching::MerkleProof::siblings. Length equals tree depth for the '
  'leaf position.';
COMMENT ON COLUMN merkle_proofs.directions IS
  'JSON array of "left" | "right" strings matching merkle_batching::Direction, '
  'parallel to sibling_path. Specifies on which side each sibling concatenates '
  'during root reconstruction.';
COMMENT ON COLUMN merkle_proofs.leaf_index IS
  '0-based position of the leaf in the canonical leaf order used to build '
  'the tree. Stored for auditability; not strictly required for verification '
  'since directions encode the path already.';

COMMIT;
