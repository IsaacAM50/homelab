variable "pve_endpoint" {
  description = "URL del API de Proxmox, con el puerto 8006."
  type        = string
}

variable "pve_api_token" {
  description = "Token de API. Lo genera ansible/pve.yml en secrets.auto.tfvars."
  type        = string
  sensitive   = true
}

variable "pve_node" {
  description = "Nombre del nodo Proxmox. Por defecto 'pve' salvo que lo cambiaras al instalar."
  type        = string
  default     = "pve"
}

variable "template_vmid" {
  description = "VMID de la plantilla cloud que creó ansible/pve.yml."
  type        = number
  default     = 9000
}

variable "storage" {
  description = "Almacenamiento de los discos. 'make discover' te dice cuál tienes."
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Puente de red de Proxmox."
  type        = string
  default     = "vmbr0"
}

# ─── Red ──────────────────────────────────────────────────────────────
# IPs estáticas a propósito: con DHCP el inventario de Ansible cambia solo
# y acabas persiguiendo direcciones. Elige un rango POR ENCIMA del que
# reparte tu router para que no choquen.
variable "network_prefix" {
  description = "Los tres primeros octetos de tu red, sin punto final."
  type        = string
  default     = "192.168.1"
}

variable "gateway" {
  description = "IP del router."
  type        = string
  default     = "192.168.1.1"
}

variable "dns_servers" {
  description = "Resolutores DNS para las VMs."
  type        = list(string)
  default     = ["1.1.1.1", "9.9.9.9"]
}

# ─── Acceso ───────────────────────────────────────────────────────────
variable "vm_user" {
  description = "Usuario que crea cloud-init dentro de cada VM."
  type        = string
  default     = "isaac"
}

variable "ssh_public_key" {
  description = "Tu clave pública: cat ~/.ssh/id_ed25519.pub"
  type        = string
}

# ─── Las máquinas ─────────────────────────────────────────────────────
# Reparto pensado para 24 GB: 16 GB en VMs, el resto para el hipervisor y
# la caché ARC de ZFS (limitada a 4 GB por ansible/pve.yml).
variable "vms" {
  description = "Las VMs a crear. 'host' es el último octeto de su IP."
  type = map(object({
    vmid   = number
    host   = number
    cores  = number
    memory = number
    disk   = number
    group  = string
  }))

  # Misma topología que ya tenías a mano, pero declarada. Los VMIDs van en
  # el rango 2xx a propósito: 101-106 siguen ocupados por las VMs
  # artesanales, así que esto se construye AL LADO sin tocarlas. Cuando el
  # clúster declarado funcione, retiras las viejas tú.
  default = {
    "master-01"     = { vmid = 201, host = 201, cores = 2, memory = 4096, disk = 32, group = "k3s_server" }
    "worker-01"     = { vmid = 202, host = 202, cores = 2, memory = 4096, disk = 32, group = "k3s_agents" }
    "worker-02"     = { vmid = 203, host = 203, cores = 2, memory = 4096, disk = 32, group = "k3s_agents" }
    "storage-01"    = { vmid = 204, host = 204, cores = 2, memory = 2048, disk = 96, group = "storage" }
    "lb-01"         = { vmid = 205, host = 205, cores = 1, memory = 1024, disk = 16, group = "lb" }
    "monitoring-01" = { vmid = 206, host = 206, cores = 2, memory = 4096, disk = 64, group = "monitoring" }
  }
}
