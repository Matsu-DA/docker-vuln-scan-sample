# Docker Vulnerability Scan Sample

Dockerイメージの脆弱性を検出し、修正可能なCRITICALでデプロイを止める。

## 30秒で体験する

```bash
git clone https://github.com/<user>/docker-vuln-scan-sample
cd docker-vuln-scan-sample
docker compose up --build
```

初めてでも動く。ただし「CIを壊した経験がある人」に最適化した設計。

## Before / After

- **BEFORE**: HIGHも含めて全部FAILにする。CIが常に赤。誰も見ない
- **AFTER**: "直せる致命傷だけ"確実に止まる。それ以外は表示のみ

この設計はセキュリティを最大化するものではない。**チームが壊れないラインに調整している。**

## なぜこれが必要か

脆弱性スキャンは、導入しても失敗することが多い:

- **入れていない** — 本番に既知の脆弱性がそのまま出る
- **入れているが、CIが常に赤** — 誰も見なくなる
- **スキャン結果は出るが、誰も直さない** — 実質「未導入」と同じ

多くの現場は**「スキャンしているのに守られていない」**状態になっている。

## 実行結果

```
$ docker compose up --build

======================================
 Docker Vulnerability Scanner
======================================

Policy:
  FAIL : CRITICAL + fix available
  WARN : HIGH (visible, no fail)
  HIDE : unfixed (no action possible)

[INFO]  Scanning image: vuln-scan-target:latest
[INFO]  Scan completed.

=== Vulnerability Report (HIGH,CRITICAL) ===
TARGET    CVE              SEVERITY  PACKAGE       INSTALLED  FIXED
app/...   CVE-2022-23529   CRITICAL  jsonwebtoken  8.5.1      9.0.0
app/...   CVE-2024-29041   HIGH      express       4.17.1     4.19.2
...

[INFO]  === Summary ===
[INFO]  Critical fixable: 1 (app: 1, os: 0)
[INFO]  High: 3
[ERROR] CRITICAL vulnerabilities with available fixes:

  [App dependencies]
    CVE-2022-23529 (jsonwebtoken 8.5.1) -> npm install jsonwebtoken@9.0.0

[WARN]  Result: WARN (CI mode would FAIL)
```

## なぜCRITICALだけfailするのか

CIは「毎回止まる」と誰も見なくなるから。

HIGHをfailにすると:
1. 初日は全員直す
2. 3日後は放置
3. 1週間後はCIが赤でも誰も気にしない

結果「スキャンしているのに守られていない」状態になる。だから**「確実に直すものだけをfailする」**。

## よくある失敗

| パターン | 結果 |
|---|---|
| スキャンを入れない | 既知の脆弱性が本番に出る |
| 全部FAILにする | 初日は直す。3日後には誰も見なくなる |
| unfixed含めて全表示 | 「直せない」ものばかりでチームが諦める |

## この設計の制約

- fixがある = 安全にアップデートできる、ではない
- major versionで破壊的変更がある場合がある
- transitive dependencyは直接制御できない場合がある
- このサンプルは「検知と停止」に特化。安全なアップデート戦略は対象外

## クイックスタート

```bash
# ローカル検証（table + JSON出力）
docker compose up --build

# CI用（JSONのみ、CRITICALでfail）
docker compose build target && MODE=ci docker compose run --rm scanner
```

## GitHub Actions（コピペで動く）

```yaml
name: Vulnerability Scan
on: [pull_request]
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build target image
        run: docker compose build target
      - name: Run vulnerability scan
        run: MODE=ci docker compose run --rm scanner
```

exit code=1でjob fail。PRマージ不可になる。

## 判断ルール

現場で迷わないために:

| 状態 | アクション |
|---|---|
| CRITICAL + fix有 | **今すぐ直す。** `npm install <pkg>@<version>` → `docker compose build target` |
| HIGH | backlogに積む。今は止めない |
| unfixed | 今は修正不可。リスクは残るがCIでは止めない（別管理） |
| 受容する場合 | `.trivyignore`に追加（理由記載必須） |

## target imageについて

`node:14.21.3-slim`（EOL）で**現実の脆弱な依存状態を再現**している。OS+npm両方の脆弱性が検出される。

**実務ではLTSバージョンを使用すること。**

## セキュリティに関する注意: Docker Socket

このサンプルは`/var/run/docker.sock`をマウントしている。これはホストのroot権限相当のリスクがある。

| 環境 | 使用 |
|---|---|
| ローカル開発 | OK |
| CI | `aquasecurity/trivy-action`推奨（Socket不要） |
| 本番 | **絶対NG** |

## 環境変数

| 変数 | デフォルト | 説明 |
|---|---|---|
| `MODE` | `local` | `local`: table+JSON / `ci`: JSONのみ+fail有効 |
| `SEVERITY_LEVELS` | `HIGH,CRITICAL` | フィルタ対象severity |
| `SHOW_UNFIXED` | `false` | 修正版なし脆弱性の表示 |
| `STRICT_LOCAL` | `false` | `true`: localでもCRITICALでfail |
| `MAX_DISPLAY` | `20` | table表示の最大件数 |
| `TARGET_IMAGE` | `vuln-scan-target:latest` | スキャン対象イメージ |

## カスタマイズ

### 別のイメージをスキャンする

`docker-compose.yml`の`TARGET_IMAGE`環境変数を変更:

```yaml
- TARGET_IMAGE=your-image:tag
```

### .trivyignore

リスク受容済みのCVEを記載。**ignore = 「非表示」であって「無害」ではない。**

```
CVE-2021-23337  # lodash: 該当関数未使用 / 2026-04-17
```

### ポリシーの変更

`scan/entrypoint.sh`の`evaluate_results()`関数を変更することで、fail条件をカスタマイズ可能。

Trivyの`--exit-code`は意図的に使用していない。severity単位の制御しかできないため、「fix有無」を含む複合条件での判断には独自ポリシーが必要。

## 次のステップ

本記事では最小構成に絞っているが、実運用では以下の課題が発生する:

- **何も変更していないのに結果が変わる** — Trivy DB更新で新しいCVEが追加される
- **HIGHが徐々に増えていく** — 差分監視（baseline比較）が必要
- **新規CVEを見逃す** — 新旧CVEの分離が必要

これらは次のステップで解決する。
