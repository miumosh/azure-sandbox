# Ingress マニフェスト

Private / Public 2つの Application Gateway に対応する Ingress リソース。

## AGIC と IngressClass の関係

本構成では AGIC を 2 つ (agic-private / agic-public) インストールする。
AGIC Helm chart はデフォルトで `IngressClass "azure-application-gateway"` を作成するが、
同名リソースは Kubernetes クラスタ内に 1 つしか存在できないため、以下のように運用する。

| Helm リリース | IngressClass リソース作成 | 備考 |
|---|---|---|
| agic-private | 有効 (デフォルト) | IngressClass を管理 |
| agic-public | **無効** (`ingressClassResource.enabled: false`) | 競合回避 |

各 AGIC Pod が監視する Ingress は `IngressClass` リソースではなく、
**Ingress アノテーション `kubernetes.io/ingress.class` の値** で決まる。

| Ingress | アノテーション値 | 対応する AGIC |
|---|---|---|
| ingress-private.yaml | `azure/application-gateway-private` | agic-private |
| ingress-public.yaml | `azure/application-gateway-public` | agic-public |

## インストール順序

1. `agic-private` を先にインストール (IngressClass が作成される)
2. `agic-public` を後にインストール (IngressClass 作成をスキップ)

順序を逆にする場合は `ingressClassResource.enabled` の設定を入れ替えること。
