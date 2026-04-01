# AKS + AGIC (Helm) 構成検証

AKS (Azure Kubernetes Service) + AGIC (Application Gateway Ingress Controller) を Helm でデプロイし、Private / Public の二系統アクセスを実現するための構成パターンを検証した。

---

## 検証サマリ

### 要件

- **Private Ingress**: Hub VNet の VM (オンプレ想定) → VNet Peering → AppGW → Pod
- **Public Ingress**: インターネット (顧客想定) → AppGW → Pod
- **AKS Egress**: Azure Firewall (Basic SKU) 経由
- **WAF**: AppGW WAF_v2 で Private / Public それぞれに WAF Policy を適用

### 検証結果一覧

| # | 構成パターン | ディレクトリ | AppGW | AGIC | Ingress | 結果 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | 基本構成 (単一アクセス) | `single_access_single_appgw/` | 1 | 1 | 2 (NodePort / ClusterIP) | **OK** | CNI Overlay 疎通検証。Private アクセスのみ |
| 2 | AppGW x2 + AGIC x2 | `multi_access_multi_appgw_NG/` | 2 (Private + Public) | 2 | 2 | **NG** | AGIC 重複エラーで動作せず |
| 3 | AppGW x1 + AGIC x1 (推奨) | `multi_access_single_appgw/` | 1 (Private + Public Frontend) | 1 | 2 | **OK** | Private/Public Frontend + `use-private-ip` アノテーションで分離 |
| 4 | AppGW x2 + AGIC x2 (修正版) | `multi_access_multi_appgw/` | 2 (Private + Public) | 2 | 2 | **検証予定** | NG の失敗原因を分析し修正。Namespace 分離 + IngressClass 名分離で競合回避 |

---

## 構成パターン詳細

### 1. single_access_single_appgw — 基本構成 (CNI Overlay 疎通検証)

AKS + AGIC の最小構成。NodePort / ClusterIP の両 Service type に対して AGIC 経由のルーティングを検証する。

- AppGW x1 (Private Frontend のみ)
- AGIC x1
- Ingress x2 (NodePort 用 / ClusterIP 用)
- Hub VNet の VM からの Private アクセスのみ

**結果: OK** — CNI Overlay 環境での AGIC ルーティング (NodePort / ClusterIP 直接) が正常動作することを確認。

### 2. multi_access_multi_appgw_NG — AppGW x2 + AGIC x2 構成

Private / Public 各アクセス経路に専用の AppGW + AGIC を割り当てる構成。

- AppGW x2 (Private AppGW + Public AppGW)
- AGIC x2 (agic-private + agic-public)
- Ingress x2 (`ingressClass` で振り分け)
- 両 AGIC を `kube-system` にデプロイ

**結果: NG** — 以下の 3 点の理由で動作しなかった:

| # | エラー内容 | 詳細 |
|---|---|---|
| 1 | IngressClass リソースの競合 | デフォルト名 `azure-application-gateway` が衝突。`kubernetes.ingressClassResource.name` で変更可能だが未設定だった |
| 2 | watchNamespace が空 | 両 AGIC が全 Namespace の Ingress を監視し、互いの AppGW 設定を上書き |
| 3 | Overlay Extension Config の競合 (CNI Overlay 利用時のみ) | `agic-overlay-extension-config` (固定名) が同一 Namespace 内で衝突。Namespace スコープのリソースだが両方 `kube-system` にデプロイしたため競合。Azure CNI (非 Overlay) や Kubenet では発生しない |

> **注:** MS ドキュメントでは「クラスターごとに複数の AGIC を必要とするデプロイでは、Helm 経由でデプロイされた AGIC を使用します」と明記されている ([参考](https://learn.microsoft.com/ja-jp/azure/application-gateway/ingress-controller-overview))。NG の失敗は AGIC 自体の制約ではなく、デプロイ構成の問題であったことが判明。修正版は `multi_access_multi_appgw/` を参照。

さらに、AGIC 重複を回避するために「AppGW x2 + AGIC x1」も検討したが、AGIC は AppGW と 1:1 の関係で動作し、`agic-values.yaml` の `appgw.name` に指定できる AppGW は 1 つだけであるため、これも実現不可能。

### 4. multi_access_multi_appgw — AppGW x2 + AGIC x2 構成 (修正版・検証予定)

NG 構成の失敗原因を分析し、修正した構成。**未検証のため動作確認はこれから実施する。**

NG からの主な修正点:

| 項目 | NG (失敗) | 修正版 |
|---|---|---|
| AGIC デプロイ先 | 両方 `kube-system` | `agic-private` / `agic-public` (Namespace 分離) |
| IngressClass 名 | デフォルト (`azure-application-gateway`) | `azure-application-gateway-private` / `-public` |
| `watchNamespace` | `""` (全 Namespace) | `"app-private"` / `"app-public"` |
| Overlay Extension Config | 同一 NS で競合 | 別 NS で独立作成 (Namespace スコープのため競合しない) |

Overlay Extension Config (`agic-overlay-extension-config`) は AGIC ソースコードに Go const としてハードコードされており変数注入による名前変更は不可能だが、**Namespace スコープのリソース**であるため AGIC を別 Namespace にデプロイすれば競合を回避できる。

> **参考:**
> - AGIC ソースコード: [`pkg/cni/overlay.go`](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/pkg/cni/overlay.go) — `OverlayExtensionConfigName` 定数定義 (名前変更不可)、`Namespace: r.namespace` (Namespace スコープ)
> - 関連 Issue: [#1524](https://github.com/Azure/application-gateway-kubernetes-ingress/issues/1524)
> - 関連 PR: [#1650](https://github.com/Azure/application-gateway-kubernetes-ingress/pull/1650)
> - MS ドキュメント: [AGIC 複数 Namespace サポート](https://learn.microsoft.com/ja-jp/azure/application-gateway/ingress-controller-multiple-namespace-support)

### 3. multi_access_single_appgw — AppGW x1 + AGIC x1 構成 (推奨)

単一の AppGW WAF_v2 に Private Frontend IP と Public Frontend IP の両方を持たせ、Ingress アノテーション `use-private-ip` で振り分ける構成。

- AppGW x1 (Private Frontend 10.2.1.10 + Public Frontend)
- AGIC x1
- Ingress x2 (`use-private-ip: "true"` で Private/Public を切り替え)
- WAF Policy x2 (Ingress アノテーション `waf-policy-for-path` で Ingress ごとに適用)

**結果: OK** — Private / Public の二系統アクセスが正常動作。AGIC の重複問題を回避しつつ要件を満たす。

---

## 検討した構成パターンの比較

| 項目 | single_access (基本) | multi_appgw_NG | multi_appgw (修正版) | multi_access_single_appgw (推奨) |
|---|---|---|---|---|
| AppGW | 1 | 2 | 2 | 1 |
| AGIC | 1 | 2 | 2 | 1 |
| Private アクセス | VM → AppGW Private FE | VM → Private AppGW | VM → Private AppGW | VM → AppGW Private FE |
| Public アクセス | なし | Internet → Public AppGW | Internet → Public AppGW | Internet → AppGW Public FE |
| WAF 分離 | — | AppGW 単位 (完全分離) | AppGW 単位 (完全分離) | `waf-policy-for-path` (ルール単位) |
| 可用性 | — | 独立障害分離 | 独立障害分離 | 単一障害点 |
| コスト (WAF_v2) | ~$0.36/hr | ~$0.72/hr | ~$0.72/hr | ~$0.36/hr |
| 動作 | **OK** | **NG** | **検証予定** | **OK** |

---

## AGIC の設計制約まとめ

本検証を通じて判明した AGIC の設計制約:

| 制約 | 内容 | 影響 |
|---|---|---|
| AppGW と 1:1 マッピング | `appgw.name` に指定できる AppGW は 1 つだけ。1 AGIC で複数 AppGW の管理は不可 | AppGW x2 + AGIC x1 構成が不可能 |
| 複数インスタンス: 同一 NS 非サポート | 同一 Namespace に AGIC を複数インストールすると IngressClass・Overlay Extension Config 等が競合 | 同一 NS への AppGW x2 + AGIC x2 構成が不可能 |
| 複数インスタンス: 別 NS で可能 (検証予定) | MS ドキュメントでは Helm 経由で複数 AGIC をサポートと明記。Namespace 分離 + IngressClass 名分離 + watchNamespace 限定で競合回避が可能と推定 | `multi_access_multi_appgw/` で検証予定 |
| Overlay Extension Config (CNI Overlay 利用時のみ) | リソース名 `agic-overlay-extension-config` が Go const でハードコード。変数注入不可。ただし **Namespace スコープ** であるため別 NS なら競合しない。Azure CNI (非 Overlay) や Kubenet では本リソース自体が作成されないため問題なし ([ソース](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/pkg/cni/overlay.go)) | CNI Overlay + 同一 NS の場合のみ競合。Namespace 分離で回避可能 |
| Private/Public Frontend の共存 | 単一 AppGW 内で `use-private-ip` アノテーションにより Frontend を切り替え可能 (v1.5.0+) | 単一 AppGW で二系統アクセスを実現可能 |

---

## 結論

### 検証済み (推奨)

**Private / Public の二系統アクセスを AGIC で実現する確実な構成は、単一 AppGW + 単一 AGIC + Ingress x2 (`use-private-ip` アノテーション)。**

### 検証予定

**AppGW x2 + AGIC x2 構成も、Namespace 分離 + IngressClass 名分離 + watchNamespace 限定により実現可能な見込み。** MS ドキュメントでは Helm 経由の複数 AGIC デプロイがサポートされている ([参考](https://learn.microsoft.com/ja-jp/azure/application-gateway/ingress-controller-overview))。NG 構成の失敗は AGIC 自体の制約ではなく、デプロイ構成 (同一 Namespace・デフォルト IngressClass 名・watchNamespace 未設定) の問題であったことが AGIC ソースコード分析により判明した。`multi_access_multi_appgw/` で検証を実施予定。

AppGW を分離したい場合 (可用性・独立運用・WAF 完全分離) は、上記の修正版構成、または AGIC 以外の Ingress Controller (NGINX Ingress Controller 等) の採用、Gateway API への移行を検討する。
