variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure Region"
  type        = string
  default     = "japaneast"
}

variable "my_public_ip" {
  description = "自分のグローバル IP (CIDR 形式: x.x.x.x/32)。scripts/update_my_ip.sh で自動更新可能"
  type        = string
}

variable "vm_admin_username" {
  description = "Test VM admin username"
  type        = string
  default     = "azureuser"
}

variable "vm_admin_password" {
  description = "Test VM admin password (12+ 文字、大小英数字 + 記号必須) — 検証用のためtfvarsにハードコード"
  type        = string
  sensitive   = true
}
