terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.1-rc6"
    }
  }
}

provider "proxmox" {
  pm_api_url      = "https://xxx.xxx.xxx.xxx:8006/api2/json"
  pm_tls_insecure = true
}
