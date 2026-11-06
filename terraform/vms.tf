resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.vms

  name      = each.key
  node_name = var.pve_node
  vm_id     = each.value.vmid
  tags      = ["tofu", each.value.group]

  description = "Gestionada por OpenTofu. Los cambios a mano se pierden en el siguiente apply."

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  # Desactivado a propósito en la creación. Con el agente activo, el
  # proveedor espera a que algo DENTRO de la VM le conteste antes de dar
  # por buena la máquina: si qemu-guest-agent no está en la imagen, cada
  # VM se cuelga hasta agotar el tiempo.
  #
  # Es un huevo y gallina: lo que crea la máquina no debe depender de algo
  # que vive dentro de la máquina. Y aquí no hace falta, porque las IPs
  # son estáticas y vienen de cloud-init, no de preguntárselas al agente.
  #
  # Ansible instala qemu-guest-agent en el rol 'base'. Cuando todas las
  # VMs lo tengan, puedes poner enabled = true y ganarás el apagado limpio
  # y la IP reportada en la UI de Proxmox.
  agent {
    enabled = false
  }

  cpu {
    cores = each.value.cores
    # 'host' expone las instrucciones reales del 3600X a la VM. Sin esto
    # pierdes rendimiento y algunas cargas ni arrancan.
    type = "host"
  }

  memory {
    dedicated = each.value.memory
    # Sin globo: con memoria dinámica, Kubernetes planifica sobre una
    # cifra que cambia bajo sus pies.
    floating = 0
  }

  # La plantilla trae un disco de 2252M (el tamaño crudo de la imagen
  # cloud). Al clonar se agranda hasta 'size'; nunca pongas menos.
  disk {
    datastore_id = var.storage
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge = var.bridge
  }

  initialization {
    datastore_id = var.storage

    ip_config {
      ipv4 {
        address = "${var.network_prefix}.${each.value.host}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.vm_user
      keys     = [trimspace(var.ssh_public_key)]
    }
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [
      # Proxmox la reescribe sola y provocaría un diff permanente que no
      # significa nada.
      initialization[0].user_account[0].password,
    ]
  }
}
