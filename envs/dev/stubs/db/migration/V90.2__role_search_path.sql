-- finding #6: 서비스가 unqualified 테이블명(search_path 가정)인데 bee 는 attest 스키마에 마이그레이션(#2).
-- bee 역할 기본 search_path = attest,public → 서비스 커넥션이 attest.* 를 unqualified 로 해석.
-- (per-service DB URL `?options=-c search_path=attest` 가 더 깔끔한 대안 — 후속.) idempotent·forward-only.
ALTER ROLE bee SET search_path TO attest, public;
