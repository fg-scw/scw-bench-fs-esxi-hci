################################################################################
# Network Configuration
# Shared VPC and Private Network connecting:
#   - iSCSI Proxy (POP2 Instance) → IP assigned by DHCP/IPAM automatically
#   - ESXi Elastic Metal servers → IP reserved via IPAM (supported for EM)
#
# IMPORTANT: Scaleway Instances get their Private Network IP via DHCP.
# Unlike Elastic Metal, you CANNOT specify a static IPAM IP for Instances.
# The proxy IP is retrieved dynamically via data source after creation.
################################################################################

# =============================================================================
# VPC
# =============================================================================

resource "scaleway_vpc" "main" {
  name   = "${var.project_name}-vpc"
  region = var.region
  tags   = local.common_tags
}

# =============================================================================
# Private Network (regional - shared between all zones)
# =============================================================================

resource "scaleway_vpc_private_network" "bench" {
  name   = "${var.project_name}-bench-pn"
  vpc_id = scaleway_vpc.main.id
  region = var.region
  tags   = concat(local.common_tags, ["network:benchmark"])

  ipv4_subnet {
    subnet = var.private_network_subnet
  }

  # Do NOT propagate the PGW default route to resources on this PN.
  # ESXi and VMs manage their own routing; we only want SSH bastion access.
  enable_default_route_propagation = false
}

# =============================================================================
# IPAM IP Reservations (Elastic Metal only)
# =============================================================================

resource "scaleway_ipam_ip" "esxi" {
  for_each = local.esxi_nodes

  address = each.value.ip

  source {
    private_network_id = scaleway_vpc_private_network.bench.id
  }

  tags = ["role:esxi", "zone:${each.key}"]
}

# =============================================================================
# Retrieve proxy's auto-assigned private IP from IPAM
# This is populated AFTER the instance is created and attached to the PN.
# =============================================================================

data "scaleway_ipam_ip" "proxy" {
  resource {
    id   = scaleway_instance_server.proxy.private_network[0].pnic_id
    type = "instance_private_nic"
  }
  type = "ipv4"

  depends_on = [scaleway_instance_server.proxy]
}
