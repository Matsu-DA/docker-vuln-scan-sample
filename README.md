# Docker Vulnerability Scan Sample

## 概要

Dockerイメージの脆弱性スキャンを「入れたけど誰も見てない」にしないためのサンプル。
全部止めると3日で誰も見なくなるので、修正できるCRITICALだけをCIで止めてそれ以外は表示だけにする。

## 試してみる

```bash
git clone https://github.com/Matsu-DA/docker-vuln-scan-sample
cd docker-vuln-scan-sample
docker compose up --build
```

## 何が起きるか

検証として、脆弱な `node:14.21.3-slim`（EOL済み）のイメージをスキャンするとこんな出力が出る。

```
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

CRITICALにはfixコマンドまで表示することで、コピペして直せるようにしました。

## なんで全部止めないの？

脆弱性の自動スキャンのよくある流れ

1. 「全severity FAILにしよう！」→ CIが常に赤 → 誰も見なくなる
2. 「unfixedも全部出そう！」→ 直せないものだらけ → チームが諦める
3. 「スキャン入れてるし大丈夫でしょ」→ 誰も見なくなる

だからこのサンプルでは「CRITICALかつfixがあるもの」だけ止めており、HIGHは表示だけしてbacklog行き。unfixedはデフォルトで非表示。

これはセキュリティを最大化する設計じゃなくて、チームが運用を続けられるラインに合わせた設計。

## 注意点

- fixがある＝対象の脆弱性が修正されているということであり、安全にアプデできるとは限らない。メジャーバージョンが上がって別の箇所が壊れることもある。
- transitive dependencyは直接どうにもできないことがある。
- あくまで「脆弱性検知と停止」のサンプルなので、アップデート戦略は別に考える必要がある。

## 使い方

```bash
# ローカルで動かす（table + JSON出力）
docker compose up --build

# CI用（JSONのみ、CRITICALでexit 1）
docker compose build target && MODE=ci docker compose run --rm scanner
```

### GitHub Actionsに入れる場合

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

CRITICALが見つかるとexit 1でjobが落ちて、PRがマージできなくなる。

## 脆弱性が見つかったら

| 状態 | どうするか |
|---|---|
| CRITICAL + fix有 | 今すぐ直す。`npm install <pkg>@<version>` して `docker compose build target` |
| HIGH | backlogに積む。今は止めない |
| unfixed | 直せないので、リスクとして認識だけしておく |
| 受容する場合 | `.trivyignore` に理由付きで追加 |

## Docker Socketについて

このサンプルでは `/var/run/docker.sock` をマウントしているが、
ホストのroot相当の権限を渡すことになるので、使う場所は選ぶこと。

- ローカル開発: 問題なし
- CI: `aquasecurity/trivy-action` を使えばSocket不要
- 本番: 絶対NG

## 環境変数

| 変数 | デフォルト | 説明 |
|---|---|---|
| `MODE` | `local` | `local`: table+JSON / `ci`: JSONのみ+fail有効 |
| `SEVERITY_LEVELS` | `HIGH,CRITICAL` | フィルタ対象severity |
| `SHOW_UNFIXED` | `false` | 修正版なし脆弱性の表示 |
| `STRICT_LOCAL` | `false` | `true` にするとlocalでもCRITICALでfail |
| `MAX_DISPLAY` | `20` | table表示の最大件数 |
| `TARGET_IMAGE` | `vuln-scan-target:latest` | スキャン対象イメージ |

## カスタマイズ

自分のイメージをスキャンしたいときは `docker-compose.yml` の `TARGET_IMAGE` を変える

```yaml
- TARGET_IMAGE=your-image:tag
```

### .trivyignore

リスク受容済みのCVEをこのファイルに書く。
ただし、ignore ＝「非表示にした」だけで「安全になった」わけではないので注意。

```
CVE-2021-23337  # lodash: 該当関数未使用 / 2026-04-17
```

### failの条件を変えたいとき

`scan/entrypoint.sh` の `evaluate_results()` を編集する。

Trivyの `--exit-code` はseverityでしか制御できず、
「fix有無」みたいな複合条件には対応できないため、自前で判定している。

## この先やりたいこと

- 新しく出たCVEと前からあったCVEの区別をつける
