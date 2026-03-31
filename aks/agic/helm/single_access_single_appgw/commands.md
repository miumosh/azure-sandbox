# 正常性確認コマンド集

疎通確認までの手順と各コマンドの確認観点を整理する。
コマンドの作業ディレクトリは `overlay-test/terraform/` を起点とする。

---

## 確認の流れ

```
① Terraform output      → Azure リソースの値取得
② AKS ノード確認        → クラスター自体の正常性
③ Pod 確認              → アプリ・AGIC の起動状態
④ AGIC ログ確認         → AppGW への設定書き込み状態
⑤ Ingress 確認          → AGIC が AppGW に IP を割り当てたか
⑥ AppGW 確認            → リスナー・バックエンドの正常性
⑦ VM から疎通確認       → エンドツーエンドの HTTP 到達確認
```

---

## ① Terraform output — リソース情報の取得

```bash
# 全 output 表示
terraform output

# 個別取得（helm install や SSH に使用）
terraform output -raw subscription_id
terraform output -raw agic_identity_client_id
terraform output -raw test_vm_public_ip
terraform output -raw aks_get_credentials_cmd
```

**確認観点:** AGIC の Client ID や VM の Public IP など、後続手順で使う値を取得する。

---

## ② AKS ノード確認 — クラスター自体の正常性

```bash
# kubectl コンテキスト設定（初回のみ）
$(terraform output -raw aks_get_credentials_cmd)

# ノード一覧・ステータス
kubectl get nodes
```

**確認観点:** ノードが `Ready` になっているかを確認する。`NotReady` の場合は AKS の起動待ちまたは NSG の設定不備を疑う。

---

## ③ Pod 確認 — アプリ・AGIC の起動状態

```bash
# 全 namespace の Pod 一覧
kubectl get po -A

# AGIC Pod のみ
kubectl get pod -n kube-system -l app=ingress-azure
```

**確認観点:**
- `app-nodeport-*` / `app-clusterip-*` が `Running 1/1` であること
- `agic-ingress-azure-*` が `Running 1/1` であること
- `CrashLoopBackOff` の場合は認証エラー（Workload Identity 設定不備）を疑う

---

## ④ AGIC ログ確認 — AppGW への設定書き込み状態

```bash
# 直近ログ確認（通常時）
kubectl logs -n kube-system -l app=ingress-azure --tail=50

# 問題発生時は行数を増やす
kubectl logs -n kube-system -l app=ingress-azure --tail=200

# 直近 N 分のログ（再起動後など）
kubectl logs -n kube-system -l app=ingress-azure --since=5m
```

**確認観点と注意すべきログパターン:**

| ログパターン | 意味 | 対処 |
|---|---|---|
| `Overlay extension config is ready` | CNI Overlay の Route 設定完了 | 正常 |
| `BEGIN AppGateway deployment` + OperationID | AppGW への設定書き込み開始 | 完了まで待つ |
| `is in stopped state` / `Ignore mutating App Gateway` | AppGW が停止中 → 設定書き込み不可 | AppGW を起動して AGIC を再起動 |
| `Skipping event ... is not used by any Ingress` | Ingress と Service が未紐付け | Ingress が未 apply またはアノテーション不一致 |
| `AADSTS700213` | Federated Credential の subject 不一致 | Helm release name と subject を再確認 |
| `AADSTS70011` | identityClientID の設定誤り | `--set armAuth.identityClientID` の値を確認 |

---

## ⑤ Ingress 確認 — AGIC が AppGW にプライベート IP を割り当てたか

```bash
# ADDRESS 列に 10.0.1.10 が付いているか確認
kubectl get ingress

# 変化を監視する場合
kubectl get ingress -w
```

**確認観点:** `ADDRESS` が空の場合は AGIC が AppGW を設定できていない。AGIC ログで原因を確認する。

---

## ⑥ AppGW 確認 — リスナー・バックエンドの正常性

### AppGW の起動状態

```bash
az network application-gateway show \
  --name agic-green-appgw \
  --resource-group agic-green-rg \
  --query "operationalState" -o tsv
# → "Running" であること（"Stopped" の場合は後述の起動コマンドを実行）
```

**確認観点:** `Stopped` の状態では AGIC が AppGW を設定できず、Ingress の ADDRESS も空になる。

### バックエンドの正常性（ヘルスプローブ結果）

```bash
az network application-gateway show-backend-health \
  -g agic-green-rg -n agic-green-appgw \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address, health:health}" \
  -o table
```

**確認観点:**
- `Healthy`: AppGW からバックエンド Pod への疎通 OK
- `Unhealthy`: Pod IP 到達不可 → Route Table / CNI Overlay の設定不備を疑う
- アドレスが `192.168.x.x` (Pod CIDR) の場合は CNI Overlay の Pod 直接ルーティングが有効

### リスナーの frontend IP 確認

```bash
az network application-gateway show \
  -g agic-green-rg -n agic-green-appgw \
  -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for l in d.get('httpListeners', []):
    fip = l.get('frontendIpConfiguration', {}).get('id', 'N/A')
    print(l['name'], '->', fip.split('/')[-1] if fip != 'N/A' else 'N/A')
"
```

**確認観点:** `appgw-private-frontend` が表示されれば `usePrivateIP: true` が有効。`appgw-public-frontend` のみの場合は AGIC の設定を確認する。

---

## ⑦ VM からの疎通確認 — エンドツーエンドの HTTP 到達確認

```bash
# VM に SSH ログイン
ssh azureuser@$(terraform output -raw test_vm_public_ip)
```

VM 内で実行:

```bash
APPGW_PRIVATE_IP="10.0.1.10"

# TCP 到達確認（HTTP の前にポート疎通を確認）
nc -vz ${APPGW_PRIVATE_IP} 80
# → "Connection ... succeeded" であること

# HTTP 疎通確認 — NodePort ルーティング
curl -s -o /dev/null -w "%{http_code}\n" \
  http://${APPGW_PRIVATE_IP}/ -H "Host: nodeport-setting.internal"
# → 200

# HTTP 疎通確認 — ClusterIP ルーティング
curl -s -o /dev/null -w "%{http_code}\n" \
  http://${APPGW_PRIVATE_IP}/ -H "Host: clusterip-setting.internal"
# → 200

# 詳細確認（レスポンスボディ含む）
curl -v http://${APPGW_PRIVATE_IP}/ -H "Host: nodeport-setting.internal"
```

**確認観点の段階的切り分け:**

| コマンド | 成否 | 判定 |
|---|---|---|
| `nc -vz 10.0.1.10 80` | 失敗 | VM → AppGW のネットワーク経路問題（NSG / ルーティング）|
| `nc` 成功 + `curl` タイムアウト | — | AppGW のリスナーが private frontend に向いていない可能性 |
| `nc` 成功 + `curl` 502 | — | AppGW リスナーは正常、バックエンド Pod が不健全 |
| `nc` 成功 + `curl` 200 | — | 全正常 ✅ |

---

## クラスター内からの切り分け確認

VM からの curl が届かない場合に、AppGW 自体の問題か経路の問題かを切り分けるために使用する。

```bash
# AKS Pod から AppGW の private IP に直接 HTTP アクセス
kubectl run test-curl --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s -o /dev/null -w "%{http_code}\n" \
  http://10.0.1.10/ -H "Host: nodeport-setting.internal"
# Pod から 200 が返り VM から届かない場合 → VM ↔ AppGW 間の経路問題
# Pod からも届かない場合 → AppGW 側の問題（リスナー・バックエンド）
```

---

## Workload Identity 確認 — AGIC の認証設定

```bash
# ServiceAccount に client-id アノテーションが付いているか確認
kubectl get sa -n kube-system agic-sa-ingress-azure -o yaml
```

**確認観点:**
- `azure.workload.identity/client-id` アノテーションが存在すること
- 値が `terraform output -raw agic_identity_client_id` と一致すること
- `azure.workload.identity/use: "true"` ラベルが存在すること

---

## トラブルシューティング コマンド

### AppGW が Stopped 状態の場合

```bash
az network application-gateway start \
  --name agic-green-appgw \
  --resource-group agic-green-rg

# Running になるまで待って AGIC を再起動
kubectl rollout restart deployment agic-ingress-azure -n kube-system
kubectl rollout status deployment agic-ingress-azure -n kube-system
```

### AGIC を手動で再トリガーする

```bash
# Pod を再起動して AppGW への設定再書き込みを強制
kubectl rollout restart deployment agic-ingress-azure -n kube-system
```

### VM NSG の実効ルール確認

```bash
NIC_NAME=$(az vm show \
  -g agic-green-rg -n agic-test-vm \
  --query "networkProfile.networkInterfaces[0].id" -o tsv | xargs basename)

az network nic list-effective-nsg \
  -g agic-green-rg -n $NIC_NAME \
  --query "effectiveSecurityRules[].{name:name, direction:direction, access:access, src:sourceAddressPrefix, dst:destinationAddressPrefix, port:destinationPortRange, priority:priority}" \
  -o table
```

**確認観点:** サブネット NSG と NIC NSG の両方が合算された実効ルールを確認できる。期待する outbound ルールに `AllowVnetOutBound` が含まれていること。

### グローバル IP が変わって SSH できなくなった場合

```bash
bash ../scripts/update_my_ip.sh
terraform apply -target=azurerm_network_security_rule.vm_allow_ssh
```

---

## 重要事項メモ

| 項目 | 内容 |
|---|---|
| AppGW Public IP | Standard_v2 SKU では必須。Private IP のみの構成は不可。実際のルーティングは AGIC の `usePrivateIP: true` によりプライベート IP 経由のみ。 |
| AppGW Stopped 問題 | `terraform apply` で AppGW が再作成されると Stopped 状態で起動することがある。`az ... start` 後に AGIC を `rollout restart` すること。 |
| AGIC の反映遅延 | AppGW への設定書き込みには数十秒〜数分かかる。Ingress の ADDRESS が空でも AGIC ログで `BEGIN AppGateway deployment` が出ていれば書き込み中。|
| Federated Credential の subject | Helm の release name が変わると ServiceAccount 名も変わり subject 不一致エラーになる。release name `agic` → SA 名 `agic-sa-ingress-azure` で固定。|
| AGIC v1.9.1 + CNI Overlay | バックエンドに Pod IP (192.168.x.x) が直接登録される。Route Table ではなく "overlay extension config" で AppGW ↔ Pod 間のルーティングを設定。|
| ClusterIP 疎通 | AGIC v1.9.1 以上 + CNI Overlay 環境でのみ有効。それ未満では NodePort が必須。|
