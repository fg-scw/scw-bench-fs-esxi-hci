################################################################################
# Outputs
################################################################################

locals {
  proxy_private_ip = data.scaleway_ipam_ip.proxy.address
}

# =============================================================================
# File Storage
# =============================================================================

output "filestorage" {
  description = "File Storage details"
  value = {
    id      = scaleway_file_filesystem.bench.id
    name    = scaleway_file_filesystem.bench.name
    size_gb = var.filestorage_size_gb
  }
}

# =============================================================================
# iSCSI Proxy
# =============================================================================

output "iscsi_proxy" {
  description = "iSCSI Proxy instance details"
  value = {
    id         = scaleway_instance_server.proxy.id
    name       = scaleway_instance_server.proxy.name
    public_ip  = scaleway_instance_ip.proxy.address
    private_ip = local.proxy_private_ip
    ssh        = "ssh root@${scaleway_instance_ip.proxy.address}"
    iscsi_portal = "${local.proxy_private_ip}:3260"
    target_iqn   = local.iscsi_target_iqn
  }
}

# =============================================================================
# ESXi Servers
# =============================================================================

output "esxi_servers" {
  description = "ESXi server details per zone"
  value = {
    for zone, node in local.esxi_nodes : zone => {
      name       = node.name
      zone       = node.zone
      server_id  = scaleway_baremetal_server.esxi[zone].id
      public_ip  = try([for ip in scaleway_baremetal_server.esxi[zone].ips : ip.address if ip.version == "IPv4"][0], null)
      private_ip = node.ip
    }
  }
}

# =============================================================================
# Network
# =============================================================================

output "network" {
  description = "Network configuration"
  value = {
    vpc_id             = scaleway_vpc.main.id
    private_network_id = scaleway_vpc_private_network.bench.id
    subnet             = var.private_network_subnet
    proxy_private_ip   = local.proxy_private_ip
  }
}

# =============================================================================
# Bastion
# =============================================================================

output "bastion" {
  description = "SSH Bastion (Public Gateway) details"
  value = {
    public_ip    = scaleway_vpc_public_gateway_ip.bastion.address
    bastion_port = var.pgw_bastion_port
    ssh_jump     = "ssh -J bastion@${scaleway_vpc_public_gateway_ip.bastion.address}:${var.pgw_bastion_port}"
    pn_name      = scaleway_vpc_private_network.bench.name
  }
}

# =============================================================================
# iSCSI Setup Commands
# =============================================================================

output "iscsi_setup" {
  description = "iSCSI setup commands for VMs and ESXi"
  value = {
    vm_linux = <<-EOT
      # Linux VM — direct iSCSI (LUN 1 = ${var.iscsi_lun_vm_size_gb}G)
      apt install -y open-iscsi
      cat >> /etc/iscsi/iscsid.conf << 'EOF'
      node.session.auth.authmethod = CHAP
      node.session.auth.username = ${local.iscsi_auth_user}
      node.session.auth.password = ${local.iscsi_auth_pass}
      EOF
      systemctl restart iscsid
      iscsiadm -m discovery -t sendtargets -p ${local.proxy_private_ip}
      iscsiadm -m node --login
      # Find iSCSI disk, format, mount
      DISK=$(lsblk -dpno NAME,TRAN | grep iscsi | awk '{print $1}' | head -1)
      mkfs.ext4 -F $DISK && mount $DISK /mnt/iscsi-bench
    EOT

    esxi_cli = <<-EOT
      # ESXi — iSCSI datastore (LUN 2 = ${var.iscsi_lun_esxi_size_gb}G)
      esxcli iscsi software set --enabled=true
      ADAPTER=$(esxcli iscsi adapter list | grep Software | awk '{print $1}')
      esxcli iscsi adapter auth chap set --adapter=$ADAPTER --direction=uni --authname=${local.iscsi_auth_user} --secret=${local.iscsi_auth_pass} --level=required
      esxcli iscsi adapter discovery sendtarget add --adapter=$ADAPTER --address=${local.proxy_private_ip}
      esxcli iscsi adapter discovery rediscover --adapter=$ADAPTER
      esxcli storage core adapter rescan --adapter=$ADAPTER
      # Then create VMFS6 datastore via vSphere UI or vmkfstools
    EOT
  }
  sensitive = true
}

# =============================================================================
# Summary
# =============================================================================

output "benchmark_summary" {
  description = "Summary for benchmark execution"
  value = <<-EOT

    ================================================================
    Storage Benchmark Infrastructure — iSCSI Architecture
    ================================================================

    File Storage: ${var.filestorage_size_gb} GB (virtiofs on proxy)
    iSCSI Proxy:  ${scaleway_instance_ip.proxy.address} (${var.proxy_instance_type})
    Proxy PN IP:  ${local.proxy_private_ip} (auto-assigned by IPAM)
    iSCSI Portal: ${local.proxy_private_ip}:3260
    Target IQN:   ${local.iscsi_target_iqn}

    LUN 1: iscsi-lun-vm.img   (${var.iscsi_lun_vm_size_gb}G)  — Linux VM direct iSCSI
    LUN 2: iscsi-lun-esxi.img (${var.iscsi_lun_esxi_size_gb}G) — ESXi VMFS6 datastore

    ESXi Hosts:
    %{for zone, node in local.esxi_nodes~}
      ${node.name} (${zone}): ${node.ip}
    %{endfor~}

    Next Steps:
    1. Configure proxy iSCSI target:
       cd ../ansible && ansible-playbook playbooks/01-proxy-storage.yml

    2. Install benchmark tools + connect iSCSI on VMs:
       ansible-playbook playbooks/02-benchmark-prep.yml

    3. Configure ESXi iSCSI adapter (see: terraform output -json iscsi_setup)

    4. Run benchmarks:
       ansible-playbook playbooks/03-run-benchmarks.yml
    ================================================================
  EOT
}
