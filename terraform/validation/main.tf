terraform {
  required_version = ">= 1.5"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.74"
    }
  }
}

variable "project_id" {
  description = "Project containing the existing ESXi and private network."
  type        = string
}

variable "private_network_id" {
  description = "Existing private network ID, including its region prefix (fr-par/UUID)."
  type        = string
}

variable "private_network_cidr" {
  description = "Existing private network CIDR allowed to reach the test NFS gateway."
  type        = string
}

variable "ssh_cidr" {
  description = "Operator's public IP as a /32 CIDR for SSH."
  type        = string
}

provider "scaleway" {
  project_id = var.project_id
  region     = "fr-par"
  zone       = "fr-par-2"
}

resource "scaleway_file_filesystem" "validation" {
  name       = "fs-validation"
  size_in_gb = 500
  tags       = ["validation", "esxi"]
}

resource "scaleway_block_volume" "nfs_validation" {
  name       = "nfs-validation-block"
  size_in_gb = 10
  iops       = 15000
  tags       = ["validation", "nfs"]
}

resource "scaleway_instance_security_group" "gateway" {
  name                    = "fs-validation-gateway"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    port     = 22
    ip_range = var.ssh_cidr
  }

  inbound_rule {
    action   = "accept"
    port     = 2049
    ip_range = var.private_network_cidr
  }
}

resource "scaleway_instance_security_group" "peer" {
  name                    = "fs-validation-peer"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    port     = 22
    ip_range = var.ssh_cidr
  }
}

resource "scaleway_instance_ip" "gateway" {}
resource "scaleway_instance_ip" "peer" {}

resource "scaleway_instance_server" "gateway" {
  name                  = "fs-validation-gateway"
  type                  = "POP2-4C-16G"
  image                 = "ubuntu_noble"
  state                 = "started"
  ip_id                 = scaleway_instance_ip.gateway.id
  security_group_id     = scaleway_instance_security_group.gateway.id
  tags                  = ["validation", "gateway"]
  additional_volume_ids = [scaleway_block_volume.nfs_validation.id]

  filesystems {
    filesystem_id = scaleway_file_filesystem.validation.id
  }

  private_network {
    pn_id = var.private_network_id
  }
}

resource "scaleway_instance_server" "peer" {
  name              = "fs-validation-peer"
  type              = "POP2-2C-8G"
  image             = "ubuntu_noble"
  state             = "started"
  ip_id             = scaleway_instance_ip.peer.id
  security_group_id = scaleway_instance_security_group.peer.id
  tags              = ["validation", "peer"]

  filesystems {
    filesystem_id = scaleway_file_filesystem.validation.id
  }

  private_network {
    pn_id = var.private_network_id
  }
}

output "file_storage_id" {
  value = scaleway_file_filesystem.validation.id
}

output "block_volume_id" {
  value = scaleway_block_volume.nfs_validation.id
}

output "gateway_public_ip" {
  value = scaleway_instance_ip.gateway.address
}

output "gateway_private_ip" {
  value = scaleway_instance_server.gateway.private_ips[0].address
}

output "peer_public_ip" {
  value = scaleway_instance_ip.peer.address
}

output "peer_private_ip" {
  value = scaleway_instance_server.peer.private_ips[0].address
}
