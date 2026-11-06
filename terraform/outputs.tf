locals {
  groups = distinct([for name, vm in var.vms : vm.group])
}

output "vm_ips" {
  description = "Dirección de cada VM."
  value       = { for name, vm in var.vms : name => "${var.network_prefix}.${vm.host}" }
}

# El inventario de Ansible sale de aquí, no se escribe a mano. Una sola
# fuente de verdad: si cambias una VM en variables.tf, el inventario se
# entera. Mantener las dos listas a mano es garantizar que un día difieran.
output "ansible_inventory" {
  description = "Inventario YAML para la capa de Ansible."
  value = yamlencode({
    for group in local.groups : group => {
      hosts = {
        for name, vm in var.vms : name => {
          ansible_host = "${var.network_prefix}.${vm.host}"
          ansible_user = var.vm_user
        } if vm.group == group
      }
    }
  })
}
