################################################################################
# Variables - ESXi + File Storage + iSCSI Proxy Benchmark Infrastructure
################################################################################

# =============================================================================
# Scaleway Configuration
# =============================================================================

variable "region" {
  description = "Scaleway region"
  type        = string
  default     = "fr-par"
}

variable "project_id" {
  description = "Scaleway project ID"
  type        = string
  default     = null
}

variable "ssh_key_ids" {
  description = "List of SSH key IDs for server access"
  type        = list(string)
}

variable "tags" {
  description = "Tags for all resources"
  type        = list(string)
  default     = ["benchmark", "storage", "esxi", "filestorage", "iscsi", "terraform"]
}

# =============================================================================
# Naming
# =============================================================================

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "storage-bench"
}

# =============================================================================
# ESXi Elastic Metal Configuration
# =============================================================================

variable "esxi_server_type" {
  description = "Elastic Metal server type for ESXi hosts"
  type        = string
  default     = "EM-I210E-NVME"

  validation {
    condition = contains([
      "EM-I210E-NVME",
      "EM-I220E-NVME",
      "EM-L220E-NVME",
      "EM-B220E-NVME",
    ], var.esxi_server_type)
    error_message = "Invalid ESXi server type."
  }
}

variable "esxi_os_id" {
  description = "OS ID for VMware ESXi on Elastic Metal (check: scw baremetal os list zone=fr-par-1 | grep -i esxi)"
  type        = string
}

variable "esxi_service_password" {
  description = "ESXi root password (8+ chars)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.esxi_service_password) >= 8
    error_message = "Password must be at least 8 characters."
  }
}

variable "esxi_zones" {
  description = "Zones for ESXi Elastic Metal servers (one per zone for comparison)"
  type        = list(string)
  default     = ["fr-par-1"]
}

# =============================================================================
# iSCSI Proxy Instance Configuration (POP2)
# =============================================================================

variable "proxy_instance_type" {
  description = "Instance type for iSCSI proxy (must be POP2 for File Storage)"
  type        = string
  default     = "POP2-8C-32G"
}

variable "proxy_image" {
  description = "OS image for proxy instance"
  type        = string
  default     = "ubuntu_noble" # Ubuntu 24.04 LTS
}

variable "proxy_zone" {
  description = "Zone for the proxy instance (must match File Storage region)"
  type        = string
  default     = "fr-par-1"
}

# =============================================================================
# File Storage Configuration
# =============================================================================

variable "filestorage_size_gb" {
  description = "Size of the Scaleway File Storage filesystem in GB (min 100)"
  type        = number
  default     = 500

  validation {
    condition     = var.filestorage_size_gb >= 100
    error_message = "File Storage minimum size is 100 GB."
  }
}

# =============================================================================
# iSCSI Configuration
# =============================================================================

variable "iscsi_lun_vm_size_gb" {
  description = "Size of the iSCSI LUN for direct VM benchmarks (sparse file)"
  type        = number
  default     = 50
}

variable "iscsi_lun_esxi_size_gb" {
  description = "Size of the iSCSI LUN for ESXi VMFS datastore (sparse file)"
  type        = number
  default     = 100
}

variable "iscsi_auth_user" {
  description = "CHAP username for iSCSI authentication"
  type        = string
  default     = "bench"
}

variable "iscsi_auth_pass" {
  description = "CHAP password for iSCSI authentication (12+ chars recommended)"
  type        = string
  default     = "benchpass123"
  sensitive   = true
}

# =============================================================================
# Network Configuration
# =============================================================================

variable "private_network_subnet" {
  description = "CIDR for the shared private network (EM ESXi + POP2 proxy)"
  type        = string
  default     = "172.16.100.0/24"
}

variable "esxi_private_ip_start" {
  description = "Starting IP offset for ESXi servers in the private network"
  type        = number
  default     = 20
}

# =============================================================================
# Public Gateway / SSH Bastion
# =============================================================================

variable "pgw_type" {
  description = "Public Gateway type (VPC-GW-S or VPC-GW-M)"
  type        = string
  default     = "VPC-GW-S"
}

variable "pgw_bastion_port" {
  description = "SSH bastion port on the Public Gateway"
  type        = number
  default     = 61000
}

# =============================================================================
# Benchmark VM Configuration (on ESXi)
# =============================================================================

variable "benchmark_vm_vcpus" {
  description = "Number of vCPUs for benchmark VMs on ESXi"
  type        = number
  default     = 4
}

variable "benchmark_vm_memory_mb" {
  description = "Memory in MB for benchmark VMs on ESXi"
  type        = number
  default     = 8192
}

# =============================================================================
# Proxmox Cluster Reference (Scenario A)
# =============================================================================

variable "proxmox_nodes" {
  description = "Map of existing Proxmox node names to their public IPs"
  type        = map(string)
  default     = {}
}

variable "proxmox_private_ips" {
  description = "Map of Proxmox node names to their private IPs"
  type        = map(string)
  default     = {}
}

# =============================================================================
# Output Configuration
# =============================================================================

variable "generate_inventory" {
  description = "Generate Ansible inventory"
  type        = bool
  default     = true
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key for Ansible"
  type        = string
  default     = "~/.ssh/id_rsa"
}
