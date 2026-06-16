-- =============================================================================
-- 0001_attestations.up.sql  —  BitCert Ingestion Domain · Attestations
-- =============================================================================
--
-- Owner service (writes): services/ingestion  (Phase 2 Real; Stub in Phase 1)
-- Readers:                services/profile (jurisdiction checks),
--                         services/batching (picks status='pending' into a
--                         batch), services/verification (Merkle proof
--                         reconstruction), services/reporting, services/
--                         notification (invites audit firm to review).
--
-- Helm hook weight: 10  (runs AFTER storage (5) so attestations.
--                        storage_pointer_id FK to storage_pointers(id) is
--                        inline; BEFORE batching (15) so batching can link
--                        attestations.batch_id -> batches(id) via the
--                        batching/0003_link_ingestion.up.sql link file.)
--
-- batch_id posture:
--   Declared here as bare BYTEA with a length CHECK (16 bytes = UUIDv7, matches
--   vc_models::BatchId wire form). The FK constraint pointing at batches(id)
--   is NOT declared in this file — that is added later by
--     batching/0003_link_ingestion.up.sql  (NOT VALID + VALIDATE CONSTRAINT)
--   Same pattern as audit-firm/0003 and exchange/0002 for the identity link
--   FKs. Keeps ingestion directory standalone (can run without batching).
--
-- Tenant isolation:
--   exchange_id NOT NULL + FK + indexed. audit_firm_id NOT NULL + FK + indexed
--   (the audit firm that produced and signed the attestation report).
--
-- Jurisdiction vocabulary:
--   Matches the wire form of vc_models::Jurisdiction. Extend this CHECK when
--   the enum gains a new variant — NOT transparent to the app layer.
--
-- Status lifecycle:
--   pending   — just ingested, awaiting batching
--   batched   — assigned to a batch, Merkle root not yet frozen
--   anchored  — batch committed & revealed on Bitcoin L1
--   failed    — terminal error (malformed VC, storage miss, etc.)
-- =============================================================================

BEGIN;

-- bee 포트(G24 압력#2 해소): manifest schemas:[attest] 실현 — 실 SQL 은 public 가정,
-- bee 는 attest 로 안착(search_path). DDL 본문은 verbatim(압력 보존). 차트 변경 0.
CREATE SCHEMA IF NOT EXISTS attest;
SET search_path TO attest, public;

CREATE TABLE IF NOT EXISTS attestations (
  id                   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  exchange_id          UUID         NOT NULL REFERENCES exchanges(id),
  audit_firm_id        UUID         NOT NULL REFERENCES audit_firms(id),
  jurisdiction         TEXT         NOT NULL,
  vc_document          JSONB        NOT NULL,
  report_hash          BYTEA        NOT NULL,
  storage_pointer_id   UUID         REFERENCES storage_pointers(id),

  status               TEXT         NOT NULL DEFAULT 'pending',

  -- batch_id is BYTEA(16) (UUIDv7 raw bytes), matching vc_models::BatchId.
  -- Declared as bare BYTEA here; FK to batches(id) is added by
  -- batching/0003_link_ingestion.up.sql so ingestion remains standalone.
  batch_id             BYTEA,

  submitted_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  batched_at           TIMESTAMPTZ,
  anchored_at          TIMESTAMPTZ,

  -- Jurisdiction vocabulary — must mirror vc_models::Jurisdiction wire form.
  CONSTRAINT attestations_jurisdiction_chk
    CHECK (jurisdiction IN (
      'KR-DABA',
      'SG-MAS',
      'VN-VASP',
      'EU-MiCA',
      'JP-FIEA',
      'GENERIC'
    )),

  -- Status lifecycle vocabulary.
  CONSTRAINT attestations_status_chk
    CHECK (status IN ('pending', 'batched', 'anchored', 'failed')),

  -- SHA-256 of the audit report artifact — 32 bytes.
  CONSTRAINT attestations_report_hash_length_chk
    CHECK (octet_length(report_hash) = 32),

  -- batch_id shape guard. Must be either NULL or exactly 16 bytes (UUIDv7).
  -- The FK pointing at batches(id) is added in batching/0003.
  CONSTRAINT attestations_batch_id_length_chk
    CHECK (batch_id IS NULL OR octet_length(batch_id) = 16),

  -- Status/timestamp consistency.
  --   anchored  => anchored_at  IS NOT NULL
  --   batched   => batched_at   IS NOT NULL
  -- No requirement for the reverse direction: a late backfill may set
  -- anchored_at without immediately flipping status, and batched_at
  -- persists once set.
  CONSTRAINT attestations_anchored_consistency_chk
    CHECK (
      (status = 'anchored' AND anchored_at IS NOT NULL)
      OR status <> 'anchored'
    ),
  CONSTRAINT attestations_batched_consistency_chk
    CHECK (
      (status = 'batched' AND batched_at IS NOT NULL)
      OR status <> 'batched'
    ),

  -- Deduplicate identical artifacts per tenant. Prevents an ops mistake
  -- where the same PDF is ingested twice and billed twice.
  CONSTRAINT attestations_exchange_report_uniq
    UNIQUE (exchange_id, report_hash)
);

-- Indexes -------------------------------------------------------------------
-- Tenant listing: "my attestations, newest first" (portal-web).
CREATE INDEX IF NOT EXISTS attestations_exchange_submitted_idx
  ON attestations (exchange_id, submitted_at DESC);

-- Audit-firm view: "my firm's signed attestations".
CREATE INDEX IF NOT EXISTS attestations_audit_firm_idx
  ON attestations (audit_firm_id);

-- Batching worker: "unbatched pending/failed" queue.
CREATE INDEX IF NOT EXISTS attestations_worker_queue_idx
  ON attestations (status) WHERE status IN ('pending', 'failed');

-- Reverse lookup: "give me every attestation in this batch".
CREATE INDEX IF NOT EXISTS attestations_batch_idx
  ON attestations (batch_id) WHERE batch_id IS NOT NULL;

COMMENT ON TABLE attestations IS
  'Ingested audit attestations. One row per audit-firm-signed PoR report '
  'ingested into the platform. Owner: services/ingestion. '
  'Tenant FK on exchange_id + audit_firm_id. batch_id FK added by '
  'batching/0003 (NOT VALID + VALIDATE CONSTRAINT pattern).';
COMMENT ON COLUMN attestations.vc_document IS
  'W3C Verifiable Credentials envelope as produced by vc-models crate. '
  'proof.type = "BitcertOpReturnV30Anchor2026" once anchored. Kept as JSONB '
  'to support schema evolution without migration churn.';
COMMENT ON COLUMN attestations.report_hash IS
  'SHA-256 of the raw audit report artifact (PDF/XBRL). 32 bytes. Forms half '
  'of the UNIQUE(exchange_id, report_hash) duplicate guard.';
COMMENT ON COLUMN attestations.batch_id IS
  'UUIDv7 raw bytes (16B), matches vc_models::BatchId. NULL until assigned. '
  'FK to batches(id) added by batching/0003_link_ingestion.up.sql to keep '
  'this directory standalone.';
COMMENT ON COLUMN attestations.storage_pointer_id IS
  'FK to storage_pointers(id). Nullable at ingest start; wired once the '
  'artifact has been persisted by services/storage.';

COMMIT;
