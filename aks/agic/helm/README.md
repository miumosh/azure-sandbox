# AKS + AGIC (Helm) 構成検証

AKS (Azure Kubernetes Service) + AGIC (Application Gateway Ingress Controller) を Helm でデプロイし、Private / Public の二系統アクセスを実現するための構成パターンを検証した。

---

## 検証サマリ

### 要件

- **Private Ingress**: Hub VNet の VM (オンプレ想定) → VNet Peering → AppGW → Pod
- **Public Ingress**: インターネット (顧客想定) → AppGW → Pod
- **AKS Egress**: Azure Firewall (Basic SKU) 経由
- **WAF**: AppGW WAF_v2 で Private / Public それぞれに WAF Policy を適用

### ディレクトリ一覧

| # | ディレクトリ | 構成 | 結果 | 概要 |
|---|---|---|---|---|
| 1 | `single_access_single_appgw/` | AppGW x1 + AGIC x1 | **OK** | 基本構成。CNI Overlay 疎通検証 (Private のみ) |
| 2 | `multi_access_multi_appgw_default_ns_ng/` | AppGW x2 + AGIC x2 | **NG** | 両 AGIC を `kube-system` にデプロイ → 競合で動作せず |
| 3 | `multi_access_single_appgw/` | AppGW x1 + AGIC x1 | **OK** | 単一 AppGW に Private/Public Frontend を共存 |
| 4a | `multi_access_multi_appgw_multi_ns/` | AppGW x2 + AGIC x2 | **OK** | #2 の修正版。アプリ NS を Private/Public に分離 |
| 4b | `multi_access_multi_appgw_multi_ns_to_common_ns/` | AppGW x2 + AGIC x2 | **OK** | 4a からアプリ NS を `common-apps` に集約 |

### 検証の流れ

```
#1 基本構成 (Private のみ)
 │  CNI Overlay + AGIC の基本動作を確認
 │
 ├─ #2 AppGW x2 + AGIC x2 (default NS)  → NG
 │    同一 NS (kube-system) で AGIC が競合
 │    │
 │    ├─ #3 AppGW x1 で回避  → OK
 │    │    単一 AppGW に Private/Public Frontend を共存
 │    │
 │    └─ #4a AGIC NS 分離で修正  → OK
 │         アプリを app-private / app-public に分離
 │         │
 │         └─ #4b アプリ NS を common-apps に集約  → OK
 │              バックエンドの二重管理を解消
 └──
```

---

## 構成パターン詳細

### 1. single_access_single_appgw — 基本構成 (CNI Overlay 疎通検証)

AKS + AGIC の最小構成。NodePort / ClusterIP の両 Service type に対して AGIC 経由のルーティングを検証する。

- AppGW x1 (Private Frontend のみ)
- AGIC x1
- Ingress x2 (NodePort 用 / ClusterIP 用)
- Hub VNet の VM からの Private アクセスのみ

**結果: OK** — CNI Overlay 環境での AGIC ルーティング (NodePort / ClusterIP 直接) が正常動作することを確認。

### 2. multi_access_multi_appgw_default_ns_ng — AppGW x2 + AGIC x2 (default NS・NG)

Private / Public 各アクセス経路に専用の AppGW + AGIC を割り当てる構成。両 AGIC を `kube-system` にデプロイ。

- AppGW x2 (Private AppGW + Public AppGW)
- AGIC x2 (agic-private + agic-public) → 両方 `kube-system`
- Ingress x2 (`ingressClass` で振り分け)
- アプリは `default` Namespace

**結果: NG** — 以下の 3 点の理由で動作しなかった:

| # | エラー内容 | 詳細 |
|---|---|---|
| 1 | IngressClass リソースの競合 | デフォルト名 `azure-application-gateway` が衝突。`kubernetes.ingressClassResource.name` で変更可能だが未設定だった |
| 2 | watchNamespace が空 | 両 AGIC が全 Namespace の Ingress を監視し、互いの AppGW 設定を上書き |
| 3 | Overlay Extension Config の競合 (CNI Overlay 利用時のみ) | `agic-overlay-extension-config` (固定名) が同一 Namespace 内で衝突。Namespace スコープのリソースだが両方 `kube-system` にデプロイしたため競合。Azure CNI (非 Overlay) や Kubenet では発生しない |

> **注:** MS ドキュメントでは「クラスターごとに複数の AGIC を必要とするデプロイでは、Helm 経由でデプロイされた AGIC を使用します」と明記されている ([参考](https://learn.microsoft.com/ja-jp/azure/application-gateway/ingress-controller-overview))。NG の失敗は AGIC 自体の制約ではなく、デプロイ構成の問題であったことが判明。

さらに、AGIC 重複を回避するために「AppGW x2 + AGIC x1」も検討したが、AGIC は AppGW と 1:1 の関係で動作し、`agic-values.yaml` の `appgw.name` に指定できる AppGW は 1 つだけであるため、これも実現不可能。

### 3. multi_access_single_appgw — AppGW x1 + AGIC x1 構成

単一の AppGW WAF_v2 に Private Frontend IP と Public Frontend IP の両方を持たせ、Ingress アノテーション `use-private-ip` で振り分ける構成。

- AppGW x1 (Private Frontend 10.2.1.10 + Public Frontend)
- AGIC x1
- Ingress x2 (`use-private-ip: "true"` で Private/Public を切り替え)
- WAF Policy x2 (Ingress アノテーション `waf-policy-for-path` で Ingress ごとに適用)

**結果: OK** — Private / Public の二系統アクセスが正常動作。AGIC の重複問題を回避しつつ要件を満たす。

### 4a. multi_access_multi_appgw_multi_ns — AppGW x2 + AGIC x2 (Namespace 分離版)

#2 の失敗原因を分析し、AGIC を別 Namespace にデプロイして競合を回避した構成。アプリ Namespace は Private / Public で分離。

- AppGW x2 (Private AppGW + Public AppGW)
- AGIC x2 → `agic-private` / `agic-public` Namespace に分離
- IngressClass 名を一意に設定 (`azure-application-gateway-private` / `-public`)
- アプリを `app-private` / `app-public` に分離し、各 AGIC が担当 NS のみ監視

| 項目 | #2 NG (失敗) | #4a (修正) |
|---|---|---|
| AGIC デプロイ先 | 両方 `kube-system` | `agic-private` / `agic-public` |
| IngressClass 名 | デフォルト (衝突) | `azure-application-gateway-private` / `-public` |
| `watchNamespace` | `""` (全 NS) | `"app-private"` / `"app-public"` |
| アプリ / Ingress NS | `default` | `app-private` / `app-public` |

**結果: OK** — Private / Public 両方の疎通を確認。

**課題:** 同じバックエンドアプリを `app-private` と `app-public` に重複デプロイする必要があり、バックエンドコンポーネントが増えると二重管理になる。

### 4b. multi_access_multi_appgw_multi_ns_to_common_ns — AppGW x2 + AGIC x2 (common-apps 集約版)

#4a の課題（アプリの二重管理）を解消するため、アプリと Ingress を単一の `common-apps` Namespace に集約した構成。

- AppGW x2 / AGIC x2 の構成は #4a と同じ
- 両 AGIC の `watchNamespace` を `"common-apps"` に統一
- IngressClass アノテーションで処理対象を分離（同一 NS 監視でも干渉しない）
- バックエンドアプリは 1 回のデプロイで済む

| 項目 | #4a (NS 分離) | #4b (common-apps 集約) |
|---|---|---|
| `watchNamespace` | `"app-private"` / `"app-public"` | 両方 `"common-apps"` |
| アプリ NS | `app-private` / `app-public` (重複デプロイ) | `common-apps` (1 回デプロイ) |
| Ingress NS | `app-private` / `app-public` | `common-apps` |
| バックエンド管理 | 二重管理 | 一元管理 |

**結果: OK** — Private / Public 両方の疎通を確認。

> **同一 Namespace を監視しても問題ない理由:** #2 で問題だったのは (1) IngressClass 名衝突 (2) 全 NS 監視 (3) Overlay Extension Config 競合 の組み合わせ。本構成ではすべて解消済みのため、各 AGIC は Ingress の `kubernetes.io/ingress.class` アノテーションで自分の担当のみ処理する。

> **参考:**
> - AGIC ソースコード: [`pkg/cni/overlay.go`](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/pkg/cni/overlay.go) — `OverlayExtensionConfigName` 定数定義 (名前変更不可)、`Namespace: r.namespace` (Namespace スコープ)
> - 関連 Issue: [#1524](https://github.com/Azure/application-gateway-kubernetes-ingress/issues/1524)
> - 関連 PR: [#1650](https://github.com/Azure/application-gateway-kubernetes-ingress/pull/1650)
> - MS ドキュメント: [AGIC 複数 Namespace サポート](https://learn.microsoft.com/ja-jp/azure/application-gateway/ingress-controller-multiple-namespace-support)

---

## 検証済み構成の比較 (星取表)

NG 構成と基本構成を除いた、実運用候補となる 3 構成の比較。#4a と #4b は AppGW/AGIC 構成が同じため Multi AppGW としてまとめる。

`++` = 大きな優位 / `+` = やや優位 / `-` = やや劣位 / `--` = 大きな劣位 / `=` = 同等

| 評価項目 | #3 Single AppGW | #4 Multi AppGW | 備考 |
|---|---|---|---|
| **コスト** | `++` | `--` | WAF_v2 は ~$0.36/hr/台。#4 は 2 台分 (~$0.72/hr) |
| **構成のシンプルさ** | `++` | `-` | #3 は AppGW 1 台 + AGIC 1 台。#4 は各 2 台 + Namespace 設計が必要 |
| **初回デプロイ速度** | `+` | `-` | #4 は AppGW 2 台分の ARM 更新が必要 (各最大 15 分) |
| **障害分離 (可用性)** | `--` | `++` | #3 は AppGW 単一障害点。#4 は Private/Public 独立運用 |
| **WAF Policy 分離** | `-` | `++` | #3 は `waf-policy-for-path` アノテーションでルール単位。#4 は AppGW 単位で完全分離 |
| **スケーリング独立性** | `-` | `++` | #3 は Private/Public が同一 AppGW のオートスケール枠を共有。#4 は独立スケーリング |
| **Private/Public の帯域分離** | `-` | `++` | #3 は同一 AppGW でスループットを共有。#4 は完全分離 |
| **AppGW メンテナンス独立性** | `--` | `++` | #3 は設定変更・証明書更新が全経路に影響。#4 は片方ずつ作業可能 |
| **NSG / ネットワーク分離** | `-` | `+` | #4 は AppGW ごとに専用サブネット + NSG でネットワークレベルの分離が可能 |
| **AGIC 運用リスク** | `+` | `-` | #3 は AGIC 1 台で管理が単純。#4 は 2 台の AGIC の監視・バージョン管理が必要 |
| **Helm / K8s 管理の複雑さ** | `+` | `-` | #4 は IngressClass 分離・watchNamespace 設定など追加の管理ポイントがある |
| **バックエンド管理** | `+` | `=` (#4b) / `-` (#4a) | #4a はアプリ二重デプロイ。#4b は common-apps 集約で #3 と同等 |
| **Namespace 設計の柔軟性** | `=` | `=` | どちらもバックエンドを共通 Namespace に配置可能 |
| **CNI Overlay 互換性** | `+` | `=` | #3 は Overlay Extension Config の競合リスクがない (AGIC 1 台)。#4 は Namespace 分離で回避済み |
| **将来の Gateway API 移行** | `=` | `=` | どちらも移行コストは同等 |

### 選定ガイド

| ユースケース | 推奨構成 | 理由 |
|---|---|---|
| 開発 / 検証環境 | **#3 Single AppGW** | コスト最小・構成がシンプル |
| コスト重視の本番環境 | **#3 Single AppGW** | WAF_v2 の差額 (~$260/月) は大きい |
| Private/Public の障害分離が必須 | **#4b Multi AppGW** | 片方の障害・メンテが他方に影響しない |
| WAF Policy を経路ごとに厳密管理 | **#4b Multi AppGW** | AppGW 単位の完全分離。監査・コンプライアンス要件に対応しやすい |
| Private/Public のトラフィック特性が大きく異なる | **#4b Multi AppGW** | スケーリング・帯域を独立制御できる |
| 運用チームが小規模 | **#3 Single AppGW** | 管理対象が少なく運用負荷が低い |
| Multi AppGW でバックエンドを一元管理したい | **#4b** (over #4a) | common-apps 集約でアプリの二重管理を回避 |

---

## AGIC の設計制約まとめ

本検証を通じて判明した AGIC の設計制約:

| 制約 | 内容 | 影響 |
|---|---|---|
| AppGW と 1:1 マッピング | `appgw.name` に指定できる AppGW は 1 つだけ。1 AGIC で複数 AppGW の管理は不可 | AppGW x2 + AGIC x1 構成が不可能 |
| 複数インスタンス: 同一 NS 非サポート | 同一 Namespace に AGIC を複数インストールすると IngressClass・Overlay Extension Config 等が競合 | 同一 NS への AppGW x2 + AGIC x2 構成が不可能 |
| 複数インスタンス: 別 NS で可能 (**検証済み**) | MS ドキュメントでは Helm 経由で複数 AGIC をサポートと明記。Namespace 分離 + IngressClass 名分離 + watchNamespace 限定で競合回避できることを確認 | `multi_access_multi_appgw_multi_ns/` および `_multi_ns_to_common_ns/` で検証済み |
| Overlay Extension Config (CNI Overlay 利用時のみ) | リソース名 `agic-overlay-extension-config` が Go const でハードコード。変数注入不可。ただし **Namespace スコープ** であるため別 NS なら競合しない。Azure CNI (非 Overlay) や Kubenet では本リソース自体が作成されないため問題なし ([ソース](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/pkg/cni/overlay.go)) | CNI Overlay + 同一 NS の場合のみ競合。Namespace 分離で回避可能 |
| Private/Public Frontend の共存 | 単一 AppGW 内で `use-private-ip` アノテーションにより Frontend を切り替え可能 (v1.5.0+) | 単一 AppGW で二系統アクセスを実現可能 |
| 初回 ARM 更新の遅延 | AGIC の初回 AppGW 設定反映に最大 10〜15 分かかる (Azure ARM API の制約)。2 回目以降は 15〜30 秒 | デプロイ直後の疎通不可は正常な過渡状態。確認フローは `multi_access_multi_appgw_multi_ns_to_common_ns/README.md` Appendix A 参照 |

---

## 結論

**Private / Public の二系統アクセスを AGIC で実現する構成は、Single AppGW (#3) / Multi AppGW (#4a, #4b) いずれも検証済み。すべて正常動作する。**

| 構成 | ディレクトリ | 推奨ケース |
|---|---|---|
| **#3 Single AppGW** | `multi_access_single_appgw/` | コスト・シンプルさ重視。開発/検証環境や小規模本番 |
| **#4a Multi AppGW (NS 分離)** | `multi_access_multi_appgw_multi_ns/` | 障害分離が必要で、Private/Public のアプリを別管理してもよい場合 |
| **#4b Multi AppGW (common-apps)** | `multi_access_multi_appgw_multi_ns_to_common_ns/` | 障害分離が必要で、バックエンドアプリを一元管理したい場合 (**推奨**) |

NG 構成 (`multi_access_multi_appgw_default_ns_ng/`) の失敗は AGIC 自体の制約ではなく、デプロイ構成 (同一 Namespace・デフォルト IngressClass 名・watchNamespace 未設定) の問題であったことが AGIC ソースコード分析と修正版の検証により確定した。

> **判断のポイント:** 「Private/Public どちらかが落ちたとき、もう一方に影響してよいか」で決まる。影響不可なら #4b、許容できるなら #3 がコスト・運用面で有利。
