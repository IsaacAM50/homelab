# homelab

Un clúster de seis nodos sobre Proxmox, declarado en código. OpenTofu crea
las máquinas virtuales, Ansible las configura, y el clúster entero se
levanta de cero con tres comandos.

```bash
make pve && make vms && make config
```

Hardware: Ryzen 5 3600X, 24 GB, Proxmox sobre LVM-thin.

> ¿Primera vez con Terraform o Ansible? **[CONCEPTOS.md](CONCEPTOS.md)** explica
> el modelo de las dos herramientas usando las roturas de este repo como ejemplos.
>
> **[HARDWARE.md](HARDWARE.md)** recoge lo que hay de verdad en la máquina:
> VRAM real, grupos IOMMU, reparto de memoria y los límites que condicionan el resto.

## El problema

Un homelab configurado a mano es un montón de decisiones que solo existen
en la cabeza de quien las tomó. Seis meses después nadie sabe por qué está
puesto ese `sysctl`, reinstalar significa repetir dos tardes de comandos
buscados en el historial, y cualquier cambio da miedo porque no se puede
volver atrás.

El objetivo no es "automatizar la instalación": es que el clúster sea
**desechable**. Si mañana se muere el disco, vuelve a existir igual, y el
diff de lo que cambió está en git.

## Arquitectura

Dos capas, con una frontera clara: **OpenTofu crea cascarones, Ansible
pone lo de dentro.**

```
MacBook (nodo de control)
├── tofu apply ─────────┐
└── ansible-playbook ───┼──── Tailscale (WireGuard) ────┐
                        │                               │
                        ▼                               ▼
              ┌──────────────────────────────────────────────┐
              │ Proxmox (LVM-thin)                           │
              │  plantilla 9000 ─clona→                      │
              │   201 master-01   4 GB  ─┐                   │
              │   202 worker-01   4 GB   ├ k3s               │
              │   203 worker-02   4 GB  ─┘                   │
              │   204 storage-01  2 GB                       │
              │   205 lb-01       1 GB                       │
              │   206 monitoring  4 GB                       │
              └──────────────────────────────────────────────┘
```

El hipervisor anuncia la subred entera por Tailscale, así que las VMs son
alcanzables desde la MacBook **sin instalar Tailscale en cada una**. Y sin
abrir un solo puerto en el router.

### Decisiones que no son obvias

| Decisión | Por qué, y contra qué |
| --- | --- |
| **El agente invitado desactivado al crear** | Con `agent = true` el proveedor espera a que algo *dentro* de la VM conteste antes de darla por buena. Es un huevo y gallina: lo que crea la máquina no debe depender de lo que vive dentro. Ansible instala `qemu-guest-agent` después. |
| **IPs estáticas desde cloud-init** | Con DHCP el inventario cambia solo y acabas persiguiendo direcciones. Y así tampoco hace falta el agente para descubrirlas. |
| **El inventario de Ansible es un output de OpenTofu** | Una sola fuente de verdad. Mantener dos listas de máquinas a mano es garantizar que un día no coincidan. |
| **VMIDs en el rango 2xx** | Los 101-106 son las VMs artesanales anteriores. Esto se construye al lado, sin tocarlas, y se retiran cuando el clúster declarado funciona. |
| **Tailscale antes que el cortafuegos** | ufw abre `tailscale0`, que solo existe si Tailscale ya corrió. Al revés el playbook se cierra la puerta a sí mismo. |
| **SSH también desde la LAN** | Si Tailscale falla o caduca la clave, con solo el tailnet abierto te quedas fuera y hay que ir con teclado y monitor. |
| **Puertos 6443, 8472/udp y 10250 abiertos en la LAN** | Sin ellos el clúster se levanta y *no funciona*: los nodos salen `NotReady` y los pods se quedan `Pending` sin decir por qué. |
| **Token de API, no contraseña de root** | Si se filtra, se revoca uno solo y no cambias nada más. |
| **Versiones fijadas con `mise` y con el lockfile** | `latest` convierte una máquina reproducible en una que funciona hoy y no mañana. El `.terraform.lock.hcl` se commitea: es la pinza de verdad del proveedor. |
| **k3s sin traefik ni servicelb** | Vienen por defecto y estorban: querrás tu propio ingress o Gateway API, y MetalLB en vez del balanceador de juguete. |

## Cómo se usa

### Una vez

```bash
brew install opentofu ansible && make deps
```

Rellena `ansible/inventory/pve.yml` con la IP del hipervisor,
`terraform/terraform.tfvars` a partir del `.example`, y cifra el secreto
de Tailscale:

```bash
cp ansible/inventory/group_vars/vault.yml.example ansible/inventory/group_vars/vault.yml && ansible-vault encrypt ansible/inventory/group_vars/vault.yml
```

### El ciclo normal

| Comando | Qué hace |
| --- | --- |
| `make discover` | Mira qué hay en el hipervisor. No toca nada |
| `make pve` | Prepara el hipervisor: plantilla, token, Tailscale |
| `make plan` | Enseña qué VMs se crearían |
| `make vms` | Crea las VMs y regenera el inventario |
| `make check` | Qué cambiaría dentro de las VMs, sin tocar nada |
| `make config` | Configura las VMs y levanta el clúster |
| `make nodes` | `kubectl get nodes` desde la MacBook |
| `make verify` | Ejecuta dos veces y falla si la segunda cambia algo |
| `make lint` | Linters de las dos capas |

`make verify` es la prueba de que esto es infraestructura declarativa y no
un script con pasos. Un playbook que no la pasa está mintiendo sobre su
propio estado.

## Qué rompí montando esto

| Qué rompí | Qué pasó | Cómo lo arreglé |
| --- | --- | --- |
| `vault_password_file` en `ansible.cfg` | Un clon recién hecho aborta antes de ejecutar nada, y el CI también. Ansible busca ese fichero al arrancar | Fuera de `ansible.cfg`; la clave va por entorno con `direnv` |
| Rutas viejas en `.gitignore` tras reestructurar | El fichero del vault **dejó de estar ignorado**. Un commit más y el secreto habría acabado en git | `git check-ignore -v` sobre cada secreto, en vez de confiar en que las rutas siguen valiendo |
| Cortafuegos sin los puertos internos de k3s | El clúster arranca y no funciona. Los nodos salen `NotReady` y el error no menciona el cortafuegos | Reglas explícitas para 6443, 8472/udp y 10250 desde la LAN |
| Grupo y host llamados `pve` | Ansible avisa y el comportamiento depende de cuál gane | Grupo `proxmox`, host `pve` |
| `stdout_callback = yaml` en `ansible.cfg` | El callback de `community.general` se eliminó en su versión 12. Nada arranca: el error aparece antes de la primera tarea | Callback por defecto con `callback_result_format = yaml` |
| `result_format` como clave del `ansible.cfg` | La clave correcta es `callback_result_format`. Una clave que no existe **se ignora en silencio**: ni error, ni aviso, ni efecto | Confirmada con `ansible-doc -t callback ansible.builtin.default` |
| `pve_node` con valor por defecto `"pve"` | El nodo se llamaba `isaac`. Un valor por defecto que casi siempre está mal deja seguir hasta que falla lejos del origen | Variable sin defecto: OpenTofu obliga a escribirla |
| DNS del hipervisor en `192.168.0.1` | La red es `192.168.1.x`. Un octeto. Internet funcionaba por IP, pero toda consulta de nombre se iba a una máquina inexistente y agotaba el tiempo. El síntoma era `apt`, la causa estaba tres capas más abajo, y el repositorio no tenía nada que ver | `ip route` + `resolv.conf` + ping a la IP cruda **antes** de tocar el repositorio. Arreglado con `pvesh set /nodes/<nodo>/dns`, no editando `/etc/resolv.conf`, que la interfaz sobrescribe |
| `sysctl` de `br_netfilter` antes de cargar el módulo | `net.bridge.bridge-nf-call-iptables` no existe hasta que `br_netfilter` está cargado, y en una VM recién hecha no lo está. El error dice *No such file or directory* y no menciona el módulo por ningún lado. Lo acaban cargando Docker o k3s, pero más tarde | Cargar `overlay` y `br_netfilter` con `persistent: present` antes de los sysctl |
| Copiar el kubeconfig y editarlo después | Dos tareas peleándose: `copy` restauraba el original con `127.0.0.1`, `replace` lo cambiaba por la IP, y la siguiente pasada volvía a empezar. Dos `changed` por ejecución, para siempre, sin que nada estuviera mal. Lo cazó `make verify`, no la vista | Escribir el contenido ya transformado en UNA tarea: el resultado es determinista y `copy` compara hashes |
| `config.toml` de mise escrito antes de crear su directorio | Falla en una máquina limpia y funciona en una ya configurada: solo aparece al reinstalar | Crear el directorio primero |

*(Esta tabla crece según se use. Es la parte más útil del repo.)*

## Lo que falta

- [ ] Retirar las VMs 101-106 cuando el clúster declarado esté validado
- [ ] MetalLB y un ingress de verdad sobre `lb-01`
- [ ] Prueba de idempotencia en CI, sobre contenedor, para el rol `base`
- [ ] Copia de seguridad de `/var/lib/rancher` y los volúmenes
- [ ] Rol para `storage-01` y `monitoring-01`, que hoy solo reciben la base

## Lo que no hace, y por qué

No instala escritorio en ninguna máquina. Para infraestructura es más
lento, se lleva mal con conexiones malas y acostumbra a hacer las cosas a
mano, que es justo lo contrario de lo que este repo defiende.

Tampoco instala `fail2ban`: con SSH cerrado a internet y solo clave
pública, no hay superficie que proteger. Sería seguridad de adorno.
