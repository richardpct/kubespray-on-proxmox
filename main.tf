data "local_file" "ssh_public_key" {
  filename = var.public_ssh_key
}

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "pve"

  url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve"

  source_raw {
    data = <<-EOF
    #cloud-config
    hostname: kubernetes
    users:
      - default
      - name: ubuntu
        groups:
          - sudo
        shell: /bin/bash
        ssh_authorized_keys:
          - ${trimspace(data.local_file.ssh_public_key.content)}
        sudo: ALL=(ALL) NOPASSWD:ALL
    runcmd:
      - apt update
      - apt install -y qemu-guest-agent
      - systemctl enable qemu-guest-agent
      - systemctl start qemu-guest-agent
    EOF

    file_name = "user-data-cloud-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "ubuntu_template" {
  name        = "ubuntu-template"
  node_name   = "pve"
  template    = true
  description = "Managed by OpenTofu"

  agent {
    enabled = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 20
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data.id
  }

  network_device {
    bridge = "vmbr0"
  }
}

resource "proxmox_virtual_environment_vm" "k8s-control-plane" {
  count     = local.master_nb
  name      = "k8s-control-plane-${count.index}"
  node_name = "pve"

  clone {
    vm_id = proxmox_virtual_environment_vm.ubuntu_template.id
  }

  agent {
    enabled = true
  }

  memory {
    dedicated = 2048
  }

  initialization {
    dns {
      servers = [var.nameserver]
    }

    ip_config {
      ipv4 {
        address = "${var.master_subnet}${count.index}/${var.cidr}"
        gateway = var.gateway
      }
    }
  }
}

resource "proxmox_virtual_environment_vm" "k8s-worker" {
  count     = local.worker_nb
  name      = "k8s-worker-${count.index}"
  node_name = "pve"

  clone {
    vm_id = proxmox_virtual_environment_vm.ubuntu_template.id
  }

  agent {
    enabled = true
  }

  memory {
    dedicated = 6144
  }

  initialization {
    dns {
      servers = [var.nameserver]
    }

    ip_config {
      ipv4 {
        address = "${var.worker_subnet}${count.index}/${var.cidr}"
        gateway = var.gateway
      }
    }
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

for ((i=0; i < ${local.master_nb}; i++)); do
  ssh-keygen -R ${var.master_subnet}$i
done

for ((i=0; i < ${local.worker_nb}; i++)); do
  ssh-keygen -R ${var.worker_subnet}$i
done

ansible-playbook -i inventory/proxmox/inventory.ini -u ubuntu -b cluster.yml

[ -d ~/.kube ] || mkdir ~/.kube
ssh -o StrictHostKeyChecking=accept-new ubuntu@${var.master_subnet}0 "sudo cat /root/.kube/config" > ~/.kube/config
sed -i -e 's/127.0.0.1/${var.master_subnet}0/' ~/.kube/config
    EOF
  }

  depends_on = [proxmox_virtual_environment_vm.k8s-control-plane,
                proxmox_virtual_environment_vm.k8s-worker]
}
