################################################################################
# Scaleway File Storage + iSCSI Proxy Instance (POP2)
#
# The POP2 instance:
#   1. Mounts File Storage via virtiofs (Scaleway native)
#   2. Creates sparse image files as iSCSI LUN backing stores
#   3. Exposes LUNs via tgtd to the Private Network
#
# LUN layout:
#   LUN 1: vm-bench LUN (direct iSCSI from Linux VMs)
#   LUN 2: esxi-datastore LUN (VMFS6 datastore for ESXi)
#
# Architecture:
#   Scaleway File Storage ─(virtiofs)─► POP2 Instance ─(iSCSI)─► EM ESXi / VMs
################################################################################

resource "scaleway_file_filesystem" "bench" {
  name       = "${var.project_name}-filestorage"
  size_in_gb = var.filestorage_size_gb
  tags       = concat(local.common_tags, ["role:filestorage"])
}

# =============================================================================
# POP2 Instance - iSCSI Proxy
# =============================================================================

resource "scaleway_instance_ip" "proxy" {
  zone = var.proxy_zone
  tags = concat(local.common_tags, ["role:iscsi-proxy"])
}

resource "scaleway_instance_server" "proxy" {
  name  = "${var.project_name}-nfs-proxy"
  type  = var.proxy_instance_type
  image = var.proxy_image
  zone  = var.proxy_zone
  state = "started"
  tags  = concat(local.common_tags, ["role:iscsi-proxy"])

  ip_id = scaleway_instance_ip.proxy.id

  root_volume {
    size_in_gb  = 50
    volume_type = "sbs_volume"
  }

  # Attach File Storage via virtiofs
  filesystems {
    filesystem_id = scaleway_file_filesystem.bench.id
  }

  # Attach to shared Private Network (IP auto-assigned by IPAM)
  private_network {
    pn_id = scaleway_vpc_private_network.bench.id
  }

  # Cloud-init: mount virtiofs + install/configure tgtd with iSCSI LUNs
  user_data = {
    cloud-init = <<-CLOUDINIT
      #cloud-config
      package_update: true
      packages:
        - tgt
        - net-tools
        - htop
        - iotop
        - sysstat
        - fio
        - ioping
        - bonnie++
      runcmd:
        # Mount File Storage (virtiofs tag = UUID only)
        - mkdir -p ${local.filestorage_mount}
        - FS_UUID=$(echo "${scaleway_file_filesystem.bench.id}" | sed 's|^[a-z-]*/||')
        - mount -t virtiofs $FS_UUID ${local.filestorage_mount} || true
        - echo "$FS_UUID ${local.filestorage_mount} virtiofs defaults 0 0" >> /etc/fstab
        # Create sparse LUN backing files on File Storage
        - |
          for LUN_NAME in iscsi-lun-vm.img iscsi-lun-esxi.img; do
            FPATH="${local.filestorage_mount}/$LUN_NAME"
            if [ ! -f "$FPATH" ]; then
              dd if=/dev/zero of="$FPATH" bs=1M count=1 seek=$((${var.iscsi_lun_vm_size_gb} * 1024 - 1))
            fi
          done
        # Resize ESXi LUN to its proper size (may differ from VM LUN)
        - truncate -s ${var.iscsi_lun_esxi_size_gb}G ${local.filestorage_mount}/iscsi-lun-esxi.img
        - truncate -s ${var.iscsi_lun_vm_size_gb}G ${local.filestorage_mount}/iscsi-lun-vm.img
        # Configure tgtd via tgtadm (avoids tgt-admin duplicate account bug)
        - systemctl start tgt
        - sleep 2
        - tgtadm --lld iscsi --mode target --op new --tid 1 --targetname ${local.iscsi_target_iqn}
        - tgtadm --lld iscsi --mode logicalunit --op new --tid 1 --lun 1 --backing-store ${local.filestorage_mount}/iscsi-lun-vm.img
        - tgtadm --lld iscsi --mode logicalunit --op new --tid 1 --lun 2 --backing-store ${local.filestorage_mount}/iscsi-lun-esxi.img
        - tgtadm --lld iscsi --mode account --op new --user ${local.iscsi_auth_user} --password ${local.iscsi_auth_pass}
        - tgtadm --lld iscsi --mode account --op bind --tid 1 --user ${local.iscsi_auth_user}
        - tgtadm --lld iscsi --mode target --op bind --tid 1 --initiator-address ${var.private_network_subnet}
        # Persist config (tgt-admin --dump format, loaded on reboot)
        - tgt-admin --dump > /etc/tgt/conf.d/filestorage-bench.conf
        # Network tuning
        - sysctl -w net.core.rmem_max=16777216
        - sysctl -w net.core.wmem_max=16777216
        - sysctl -w net.ipv4.tcp_rmem="4096 1048576 16777216"
        - sysctl -w net.ipv4.tcp_wmem="4096 1048576 16777216"
        - |
          cat >> /etc/sysctl.d/99-iscsi-tuning.conf << 'SYSCTL'
          net.core.rmem_max=16777216
          net.core.wmem_max=16777216
          net.core.rmem_default=1048576
          net.core.wmem_default=1048576
          net.ipv4.tcp_rmem=4096 1048576 16777216
          net.ipv4.tcp_wmem=4096 1048576 16777216
          net.core.netdev_max_backlog=30000
          SYSCTL
    CLOUDINIT
  }

  depends_on = [
    scaleway_file_filesystem.bench,
    scaleway_vpc_private_network.bench,
  ]
}
