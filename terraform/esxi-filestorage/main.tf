################################################################################
# Main Configuration
# ESXi + File Storage + iSCSI Proxy Benchmark Infrastructure
#
# Architecture:
#   Scaleway File Storage (virtiofs) → POP2 Instance (tgtd iSCSI target)
#     ├── LUN 1 (vm-bench): Linux VM on ESXi → iSCSI initiator → ext4 → fio
#     └── LUN 2 (esxi-datastore): ESXi → iSCSI → VMFS6 → VM VMDK → fio
#
# Why iSCSI and not NFS:
#   virtiofs does NOT support NFS re-export (ESTALE on all file operations).
#   iSCSI works because tgtd does block I/O on a single file — no file handles.
#
# Benchmark scenarios:
#   Phase 1a: virtiofs direct (proxy) — theoretical max
#   Phase 1b: iSCSI loopback (proxy) — tgtd overhead
#   Phase 2a: Linux VM → iSCSI LUN → ext4 — direct iSCSI from guest
#   Phase 2b: Linux VM → VMDK on VMFS → iSCSI LUN — ESXi datastore path
################################################################################

locals {
  # Common tags
  common_tags = concat(var.tags, ["project:${var.project_name}"])

  # ESXi node names per zone
  esxi_nodes = {
    for i, zone in var.esxi_zones : zone => {
      name = "${var.project_name}-esxi-${replace(zone, "fr-par-", "par")}"
      zone = zone
      ip   = cidrhost(var.private_network_subnet, var.esxi_private_ip_start + i)
    }
  }

  # File Storage mount point on POP2 instance
  filestorage_mount = "/mnt/filestorage"

  # iSCSI configuration
  iscsi_target_iqn   = "iqn.2026-02.fr.scaleway:filestorage.bench"
  iscsi_backing_dir  = "${local.filestorage_mount}"
  iscsi_auth_user    = var.iscsi_auth_user
  iscsi_auth_pass    = var.iscsi_auth_pass
}
