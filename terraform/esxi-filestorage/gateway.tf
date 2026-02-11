################################################################################
# Public Gateway + SSH Bastion
#
# Provides:
#   - SSH bastion for accessing ESXi hosts and VMs on the Private Network
#   - NAT masquerade for outbound traffic from the PN
#   - Does NOT push default route to VMs (enable_default_route_propagation=false
#     on the PN + push_default_route=false on gateway_network)
#
# SSH access pattern:
#   ssh -J bastion@<pgw_public_ip>:61000 <user>@<resource>.<pn_name>.internal
################################################################################

# =============================================================================
# Public Gateway Flexible IP
# =============================================================================

resource "scaleway_vpc_public_gateway_ip" "bastion" {
  zone = var.proxy_zone
  tags = concat(local.common_tags, ["role:bastion"])
}

# =============================================================================
# Public Gateway (IPAM mode, SSH bastion enabled)
# =============================================================================

resource "scaleway_vpc_public_gateway" "bastion" {
  name = "${var.project_name}-pgw"
  type = var.pgw_type
  zone = var.proxy_zone

  ip_id = scaleway_vpc_public_gateway_ip.bastion.id

  bastion_enabled = true
  bastion_port    = var.pgw_bastion_port

  tags = concat(local.common_tags, ["role:bastion"])
}

# =============================================================================
# Attach Public Gateway to Private Network (IPAM mode, no default route)
# =============================================================================

resource "scaleway_vpc_gateway_network" "bastion" {
  gateway_id         = scaleway_vpc_public_gateway.bastion.id
  private_network_id = scaleway_vpc_private_network.bench.id
  enable_masquerade  = true
  zone               = var.proxy_zone

  ipam_config {
    push_default_route = false
  }

  depends_on = [
    scaleway_vpc_public_gateway.bastion,
    scaleway_vpc_private_network.bench,
  ]
}
