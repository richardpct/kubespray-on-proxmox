locals {
  clone          = "ubuntu-24-04-cloudinit"
  kubespray_vers = "v2.27.0"
  master_nb      = 3
  worker_nb      = 3
  master_cores   = 2
  worker_cores   = 2
  master_memory  = 4096
  worker_memory  = 8192
  master_disk    = "20G"
  worker_disk    = "20G"
}

variable "nameserver" {
  type        = string
  description = "nameserver"
}

variable "gateway" {
  type        = string
  description = "gateway"
}

variable "cidr" {
  type        = string
  description = "cidr"
}

variable "master_subnet" {
  type        = string
  description = "control plane subnet"
}

variable "worker_subnet" {
  type        = string
  description = "worker subnet"
}

variable "public_ssh_key" {
  type        = string
  description = "public ssh key"
}
