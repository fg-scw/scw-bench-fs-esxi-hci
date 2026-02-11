################################################################################
# ESXi Elastic Metal Servers
# Deployed in fr-par-1 and fr-par-2 for cross-zone comparison
#
# Each ESXi host:
#   - Connects to the shared Private Network
#   - Accesses iSCSI datastore from the POP2 proxy (LUN 2)
#   - Runs benchmark VMs
################################################################################

# =============================================================================
# Data Sources
# =============================================================================

data "scaleway_baremetal_offer" "esxi" {
  for_each = toset(var.esxi_zones)

  zone = each.value
  name = var.esxi_server_type
}

data "scaleway_iam_ssh_key" "keys" {
  for_each   = toset(var.ssh_key_ids)
  ssh_key_id = each.value
}

# =============================================================================
# Private Network Option for Elastic Metal
# =============================================================================

data "scaleway_baremetal_option" "private_network" {
  for_each = toset(var.esxi_zones)

  zone = each.value
  name = "Private Network"
}

# =============================================================================
# ESXi Servers (one per zone)
# =============================================================================

resource "scaleway_baremetal_server" "esxi" {
  for_each = local.esxi_nodes

  name        = each.value.name
  zone        = each.value.zone
  offer       = data.scaleway_baremetal_offer.esxi[each.key].offer_id
  os          = var.esxi_os_id
  ssh_key_ids = var.ssh_key_ids
  tags        = concat(local.common_tags, ["role:esxi", "zone:${each.key}"])

  service_password = var.esxi_service_password

  # Enable Private Network option
  options {
    id = data.scaleway_baremetal_option.private_network[each.key].option_id
  }

  # Attach to shared Private Network with reserved IPAM IP
  private_network {
    id          = scaleway_vpc_private_network.bench.id
    ipam_ip_ids = [scaleway_ipam_ip.esxi[each.key].id]
  }

  timeouts {
    create = "45m"
    delete = "15m"
  }

  depends_on = [
    scaleway_vpc_private_network.bench,
    scaleway_ipam_ip.esxi,
  ]
}
