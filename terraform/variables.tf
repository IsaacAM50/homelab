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
  description = "Nombre del nodo Proxmox, que es su hostname. Compruébalo con 'hostname' por SSH: no tiene por qué ser 'pve'."
  type        = string
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

  # Reparto de los 23 GB del equipo. La memoria es el recurso que limita
  # todo lo demás, así que cada GB asignado a una VM que no hace nada es un
  # GB que no tiene el nodo de inferencia.
  #
  # storage-01, lb-01 y monitoring-01 se retiraron: el almacenamiento lo
  # resuelve local-path dentro del clúster, el balanceo lo hace MetalLB
  # como carga de trabajo, y Prometheus va mejor DENTRO de Kubernetes que
  # en su propia máquina. Tres VMs menos, 7 GB recuperados.
  default = {
    "master-01" = { vmid = 201, host = 201, cores = 2, memory = 4096, disk = 32, group = "k3s_server" }
    "worker-01" = { vmid = 202, host = 202, cores = 2, memory = 4096, disk = 32, group = "k3s_agents" }
    "worker-02" = { vmid = 203, host = 203, cores = 2, memory = 4096, disk = 32, group = "k3s_agents" }
  }
}
