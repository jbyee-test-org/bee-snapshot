# snapshot — 렌더 매니페스트 SoT (Rendered Manifests Pattern)

> 단일 기준은 워크스페이스 `GENESIS.md`. G5 고정 3 레포 중 하나.
> **단일 SoT, 소비자 둘**(규칙 7): 공유환경 CD(ArgoCD) + 로컬 backdrop(bee).
> 이 레포의 가치는 "**diff = 실질 변경**" 신호다 — 렌더 결과·provenance 외엔 아무것도 섞지 않는다.

## 레이아웃 (G8·G9)

```
envs/<env>/<module>/
  module.yaml              # 사본 동봉(G9) — 리졸버 입력·orient 메타·pull 의 출처
  provenance.yaml          # 렌더 출처 기록 (아래)
  <kind>-<name>.yaml ×N    # 렌더 매니페스트 — 리소스별 파일 분할
  db/ · contracts/         # Phase 3 슬롯 (마이그레이션·API 계약)
```

`envs/local` 은 **존재하지 않는다** — 경계는 dev(규칙 7). 로컬 구성 공유는 워크스페이스 파일로.

## provenance.yaml (G8)

```yaml
module: <name>
repoUrl: <모듈 repo>       # pull 의 해석 소스 (카탈로그 통합)
moduleCommit: <sha>
imageDigest: sha256:…
chartVersion: <bee-module 버전>   # 모듈 pin 의 기록 (G6)
dependsOn: [...]           # module.yaml 사본과 동시 생성 — 허용된 중복 (G9)
# renderedAt 없음 — 무변경 publish 가 diff 를 만들면 안 된다. 시각은 git 이 안다.
```

## 운영 (G8)

| env | 쓰기 경로 | 게이트 |
|---|---|---|
| dev | CI 직접 커밋 (`bee publish` headless) | 게이트1 — 자동 lint |
| prod | PR + 승인 (디렉토리 보호: CODEOWNERS) | 게이트2 — dev-검증 digest 만 pin (승격 = dev provenance 핀 복사, G51) |

env 사다리 = **dev → prod**(G51 — staging 제거, 중간단은 additive). 인너루프는 env 아님(publish 출발점, SoT 밖).
main 단일 브랜치. 쓰기는 publish/promote 가 유일 — 손 편집 금지(부트스트랩 1회 렌더는 계획된 예외로 커밋 메시지에 명시).
