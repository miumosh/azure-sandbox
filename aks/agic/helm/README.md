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

**結果: NG** — 以下の理由で動作しなかった:

| エラー内容 | 詳細 |
|---|---|
| IngressClass リソースの競合 | 2 つ目の AGIC Helm install 時に同名の IngressClass が衝突 |
| ConfigMap・ClusterRole の競合 | `ingressClassResource.enabled: false` で IngressClass 作成を抑制しても、他の Kubernetes リソースが同名で衝突 |
| 設定の上書き合い | 両方の AGIC Pod が Running になっても、互いの AppGW 設定を上書きし合い正常動作しない |

AGIC Helm chart は同一クラスタへの複数インスタンスデプロイを公式にサポートしていない。

さらに、AGIC 重複を回避するために「AppGW x2 + AGIC x1」も検討したが、AGIC は AppGW と 1:1 の関係で動作し、`agic-values.yaml` の `appgw.name` に指定できる AppGW は 1 つだけであるため、これも実現不可能。

### 3. multi_access_single_appgw — AppGW x1 + AGIC x1 構成 (推奨)

単一の AppGW WAF_v2 に Private Frontend IP と Public Frontend IP の両方を持たせ、Ingress アノテーション `use-private-ip` で振り分ける構成。

- AppGW x1 (Private Frontend 10.2.1.10 + Public Frontend)
- AGIC x1
- Ingress x2 (`use-private-ip: "true"` で Private/Public を切り替え)
- WAF Policy x2 (Ingress アノテーション `waf-policy-for-path` で Ingress ごとに適用)

**結果: OK** — Private / Public の二系統アクセスが正常動作。AGIC の重複問題を回避しつつ要件を満たす。

---

## 検討した構成パターンの比較

| 項目 | single_access (基本) | multi_appgw_NG | multi_access_single_appgw (推奨) |
|---|---|---|---|
| AppGW | 1 | 2 | 1 |
| AGIC | 1 | 2 | 1 |
| Private アクセス | VM → AppGW Private FE | VM → Private AppGW | VM → AppGW Private FE |
| Public アクセス | なし | Internet → Public AppGW | Internet → AppGW Public FE |
| WAF 分離 | — | AppGW 単位 (完全分離) | `waf-policy-for-path` (ルール単位) |
| 可用性 | — | 独立障害分離 | 単一障害点 |
| コスト (WAF_v2) | ~$0.36/hr | ~$0.72/hr | ~$0.36/hr |
| 動作 | **OK** | **NG** | **OK** |

---

## AGIC の設計制約まとめ

本検証を通じて判明した AGIC の設計制約:

| 制約 | 内容 | 影響 |
|---|---|---|
| AppGW と 1:1 マッピング | `appgw.name` に指定できる AppGW は 1 つだけ。1 AGIC で複数 AppGW の管理は不可 | AppGW x2 + AGIC x1 構成が不可能 |
| 複数インスタンス非サポート | 同一クラスタに AGIC Helm chart を複数インストールすると IngressClass・ConfigMap・RBAC 等が競合 | AppGW x2 + AGIC x2 構成が不可能 |
| Private/Public Frontend の共存 | 単一 AppGW 内で `use-private-ip` アノテーションにより Frontend を切り替え可能 (v1.5.0+) | 単一 AppGW で二系統アクセスを実現可能 |

---

## 結論

**Private / Public の二系統アクセスを AGIC で実現するには、単一 AppGW + 単一 AGIC + Ingress x2 (`use-private-ip` アノテーション) が唯一の実現可能な構成。**

AppGW を分離したい場合 (可用性・独立運用・WAF 完全分離) は、AGIC 以外の Ingress Controller (NGINX Ingress Controller 等) の採用、または Gateway API への移行を検討する必要がある。
