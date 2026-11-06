terraform {
  # OpenTofu, no Terraform. La 1.5.7 fue la última versión libre de
  # Terraform antes del cambio de licencia de HashiCorp; esta restricción
  # la excluye a propósito.
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # La versión exacta la fija .terraform.lock.hcl, que SÍ se commitea.
      # Esa es la pinza de verdad: la restricción de aquí solo dice qué
      # rango es aceptable, el lockfile dice qué se instaló realmente.
      version = "~> 0.120"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token

  # Proxmox trae un certificado autofirmado. En un lab es aceptable; en
  # cualquier otro sitio, monta un certificado de verdad antes que esto.
  insecure = true

  # El proveedor necesita SSH para algunas operaciones de disco que la API
  # no cubre. Usa el agente de claves de tu MacBook.
  ssh {
    agent    = true
    username = "root"
  }
}
