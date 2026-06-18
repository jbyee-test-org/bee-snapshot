-- attest schema (B안 — product 소유) + 데모 테이블. forward-only (구 D10).
CREATE SCHEMA IF NOT EXISTS attest;
CREATE TABLE IF NOT EXISTS attest.greetings (
  id   serial PRIMARY KEY,
  msg  text NOT NULL
);
INSERT INTO attest.greetings (msg) VALUES ('hello from flyway') ON CONFLICT DO NOTHING;
