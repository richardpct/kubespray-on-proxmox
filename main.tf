resource "proxmox_vm_qemu" "k8s-control-plane" {
  count            = local.master_nb
  vmid             = "10${count.index}"
  name             = "k8s-control-plane-${count.index}"
  target_node      = "pve0${count.index + 1}"
  agent            = 1
  cores            = local.master_cores
  memory           = local.master_memory
  boot             = "order=scsi0"
  clone            = local.clone
  scsihw           = "virtio-scsi-single"
  vm_state         = "running"
  automatic_reboot = true

  # Cloud-Init configuration
  cicustom   = "vendor=local:snippets/qemu-guest-agent.yml" # /var/lib/vz/snippets/qemu-guest-agent.yml
  ciupgrade  = true
  nameserver = var.nameserver
  ipconfig0  = "ip=${var.master_subnet}${count.index}/${var.cidr},gw=${var.gateway}"
  skip_ipv6  = true
  ciuser     = "ubuntu"
  sshkeys    = var.public_ssh_key

  # Most cloud-init images require a serial device for their display
  serial {
    id = 0
  }

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = local.master_disk
        }
      }
    }
    ide {
      # Some images require a cloud-init disk on the IDE controller, others on the SCSI or SATA controller
      ide1 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id     = 0
    bridge = "vmbr0"
    model  = "virtio"
  }
}

resource "proxmox_vm_qemu" "k8s-worker" {
  count            = local.worker_nb
  vmid             = "20${count.index}"
  name             = "k8s-worker-${count.index}"
  target_node      = "pve0${count.index + 1}"
  agent            = 1
  cores            = local.worker_cores
  memory           = local.worker_memory
  boot             = "order=scsi0" # has to be the same as the OS disk of the template
  clone            = local.clone
  scsihw           = "virtio-scsi-single"
  vm_state         = "running"
  automatic_reboot = true

  # Cloud-Init configuration
  cicustom   = "vendor=local:snippets/qemu-guest-agent.yml" # /var/lib/vz/snippets/qemu-guest-agent.yml
  ciupgrade  = true
  nameserver = var.nameserver
  ipconfig0  = "ip=${var.worker_subnet}${count.index}/${var.cidr},gw=${var.gateway}"
  skip_ipv6  = true
  ciuser     = "ubuntu"
  sshkeys    = var.public_ssh_key

  # Most cloud-init images require a serial device for their display
  serial {
    id = 0
  }

  disks {
    scsi {
      scsi0 {
        # We have to specify the disk from our template, else Terraform will think it's not supposed to be there
        disk {
          storage = "local-lvm"
          # The size of the disk should be at least as big as the disk in the template. If it's smaller, the disk will be recreated
          size    = local.worker_disk
        }
      }
    }
    ide {
      # Some images require a cloud-init disk on the IDE controller, others on the SCSI or SATA controller
      ide1 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id     = 0
    bridge = "vmbr0"
    model  = "virtio"
  }
}

resource "null_resource" "deploy-kubespray" {
  provisioner "local-exec" {
    command = <<EOF
[ -d /tmp/kubespray ] && rm -rf /tmp/kubespray
cd /tmp
git clone -b ${local.kubespray_vers} https://github.com/kubernetes-sigs/kubespray.git
cd kubespray
python3 -m venv kubespray-venv
source kubespray-venv/bin/activate
pip install -U -r requirements.txt
pip install ruamel_yaml
cp -rfp inventory/sample inventory/proxmox
> inventory/proxmox/inventory.ini

for ((i=0; i < ${local.master_nb}; i++)); do
  echo "k8s-control-plane-$i ansible_host=${var.master_subnet}$i ip=${var.master_subnet}$i" >> inventory/proxmox/inventory.ini
done

for ((i=0; i < ${local.worker_nb}; i++)); do
  echo "k8s-worker-$i ansible_host=${var.worker_subnet}$i ip=${var.worker_subnet}$i" >> inventory/proxmox/inventory.ini
done

echo "\n[kube_control_plane]" >> inventory/proxmox/inventory.ini
for ((i=0; i < ${local.master_nb}; i++)); do
  echo "k8s-control-plane-$i" >> inventory/proxmox/inventory.ini
done

echo "\n[etcd]" >> inventory/proxmox/inventory.ini
for ((i=0; i < ${local.master_nb}; i++)); do
  echo "k8s-control-plane-$i" >> inventory/proxmox/inventory.ini
done

echo "\n[kube_node]" >> inventory/proxmox/inventory.ini
for ((i=0; i < ${local.worker_nb}; i++)); do
  echo "k8s-worker-$i" >> inventory/proxmox/inventory.ini
done

sed -i -e 's/helm_enabled: false/helm_enabled: true/' inventory/proxmox/group_vars/k8s_cluster/addons.yml
sed -i -e 's/ingress_nginx_enabled: false/ingress_nginx_enabled: true/' inventory/proxmox/group_vars/k8s_cluster/addons.yml
sed -i -e 's/metrics_server_enabled: false/metrics_server_enabled: true/' inventory/proxmox/group_vars/k8s_cluster/addons.yml
sed -i -e 's/# ingress_nginx_host_network: false/ingress_nginx_host_network: false/' inventory/proxmox/group_vars/k8s_cluster/addons.yml
sed -i -e 's/# ingress_nginx_service_type: LoadBalancer/ingress_nginx_service_type: NodePort/' inventory/proxmox/group_vars/k8s_cluster/addons.yml
sed -i -e 's/# ingress_nginx_service_nodeport_http: 30080/ingress_nginx_service_nodeport_http: 30080/' inventory/proxmox/group_vars/k8s_cluster/addons.yml
sed -i -e 's/# ingress_nginx_service_nodeport_https: 30081/ingress_nginx_service_nodeport_https: 30443/' inventory/proxmox/group_vars/k8s_cluster/addons.yml
sed -i -e 's/kube_network_plugin: calico/kube_network_plugin: cilium/' inventory/proxmox/group_vars/k8s_cluster/k8s-cluster.yml
sed -i -e 's/# cilium_kube_proxy_replacement: partial/cilium_kube_proxy_replacement: strict/' inventory/proxmox/group_vars/k8s_cluster/k8s-net-cilium.yml

ansible-playbook -i inventory/proxmox/inventory.ini -u ubuntu -b cluster.yml
[ -d ~/.kube ] || mkdir ~/.kube
ssh-keygen -R ${var.master_subnet}0
ssh -o StrictHostKeyChecking=accept-new ubuntu@${var.master_subnet}0 "sudo cat /root/.kube/config" > ~/.kube/config
sed -i -e 's/127.0.0.1/${var.master_subnet}0/' ~/.kube/config
    EOF
  }

  depends_on = [proxmox_vm_qemu.k8s-control-plane, proxmox_vm_qemu.k8s-worker]
}
