# homelab

Un Ryzen 3600X con 24 GB pasa de una instalación limpia de Ubuntu Server a
equipo de laboratorio operativo —red privada, cortafuegos, Docker, k3s y
herramientas con versión fijada— con un solo comando, y el resultado es
idéntico las veces que haga falta.

```bash
make apply
```

## El problema

Un homelab configurado a mano es un montón de decisiones que solo existen
en la cabeza de quien las tomó. Seis meses después nadie sabe por qué está
puesto ese `sysctl`, reinstalar significa repetir dos tardes de
`apt install` buscados en el historial, y cualquier cambio da miedo porque
no se puede volver atrás.

El objetivo aquí no es "automatizar la instalación": es que la máquina sea
**desechable**. Si mañana se muere el disco, el equipo vuelve a existir en
quince minutos, igual, y el diff de lo que cambió está en git.

## Arquitectura

```
MacBook (nodo de control)          PC (lab)
┌──────────────────────┐           ┌──────────────────────────┐
│ ansible-playbook     │           │ Ubuntu Server (sin GUI)  │
│ ssh / VS Code Remote │──────────▶│ ├─ ufw   (deny + tailnet)│
│ kubectl              │ Tailscale │ ├─ Docker                │
└──────────────────────┘  (WireGuard) ├─ k3s (sin traefik)    │
                                    │ └─ mise → tf, kubectl…  │
                                    └──────────────────────────┘
```

**Sin puertos abiertos en el router.** Tailscale monta una red WireGuard
entre los dos equipos; el PC es alcanzable como `lab` desde cualquier red
del mundo, y desde internet no existe.

El nodo de control es la MacBook: Ansible se ejecuta ahí y habla por SSH.
El PC nunca necesita tener Ansible instalado, lo que evita que la máquina
que configuras tenga que estar configurada para configurarse.

### Decisiones que no son obvias

| Decisión | Por qué, y contra qué |
| --- | --- |
| **Tailscale antes que hardening** | El cortafuegos abre `tailscale0`, que solo existe si Tailscale ya corrió. Al revés el playbook se cierra la puerta a sí mismo. |
| **SSH también desde la LAN** | Si Tailscale falla o caduca la clave, con solo el tailnet abierto te quedas fuera de tu propia máquina y hay que ir con teclado y monitor. La regla de LAN es el seguro. |
| **Versiones fijadas con `mise`** | `latest` convierte una máquina reproducible en una que funciona hoy y no mañana. Todas las versiones viven en `group_vars/all.yml`. |
| **k3s sin traefik ni servicelb** | Vienen puestos por defecto y estorban: en un lab quieres instalar tu propio ingress o Gateway API, y MetalLB en vez del balanceador de juguete. |
| **Límite de logs en Docker** | Un contenedor hablador llena el disco y tira la máquina. El `daemon.json` por defecto no rota nada. |
| **`sysctl` de inotify** | Los límites por defecto de Ubuntu se agotan con pocos pods, y el error que sale no menciona inotify: kubelet dice "too many open files" y Argo CD deja de ver cambios. |
| **Nodo de control en la MacBook** | Mantiene el PC limpio y hace que el playbook valga para el segundo equipo sin cambiar nada. |

## Qué deja montado

- **base** — paquetes, zona horaria, usuario con su clave, sudo sin contraseña, `sysctl` para Kubernetes, actualizaciones de seguridad desatendidas
- **tailscale** — alta en el tailnet con `--ssh`, idempotente
- **hardening** — ufw (deny entrante, tailnet abierto, SSH desde la LAN), SSH solo por clave, sin root, incluidos los fragmentos de `sshd_config.d` que Ubuntu usa para reactivar la contraseña por detrás
- **docker** — repo oficial, buildx, compose, rotación de logs, usuario en el grupo
- **tooling** — `mise` con terraform, opentofu, kubectl, helm, k9s, kustomize, argocd, yq; `direnv`; alias de kubectl
- **k3s** — nodo único, kubeconfig copiado al usuario y reescrito para que `kubectl` funcione **también desde la MacBook** por Tailscale
- **wol** — servicio systemd que reactiva Wake-on-LAN en cada arranque, porque `ethtool` lo pierde al reiniciar

## Cómo se usa

### En la MacBook, una vez

```bash
brew install ansible && ansible-galaxy collection install -r requirements.yml
```

Rellena tu clave pública y tu subred en `inventory/group_vars/all.yml`, y
crea el secreto de Tailscale:

```bash
cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml && ansible-vault encrypt inventory/group_vars/vault.yml
```

### El ciclo normal

```bash
make check   # qué cambiaría, sin tocar nada
```

```bash
make apply   # aplicarlo
```

```bash
make verify  # ejecuta dos veces y falla si la segunda cambia algo
```

`make verify` es la prueba de que esto es infraestructura declarativa y no
un script con pasos. Un playbook que no pasa esa prueba está mintiendo
sobre su propio estado.

Para tocar solo una parte: `ansible-playbook site.yml --tags k3s`.

## Qué rompí montando esto

| Qué rompí | Qué pasó | Cómo lo arreglé |
| --- | --- | --- |
| `vault_password_file` en `ansible.cfg` | Un clon recién hecho aborta antes de ejecutar nada: Ansible busca el fichero al arrancar y no lo encuentra. El CI también se caía. | Fuera de `ansible.cfg`; la clave se pasa por entorno con `direnv` (`.envrc.example`) |
| Cerrar el SSH antes de abrir el cortafuegos | Quedarte fuera de tu propia máquina. Hay que ir con teclado y monitor. | Orden explícito de roles y regla de LAN como seguro |
| Escribir el `config.toml` de mise antes de crear su directorio | La tarea falla en una máquina limpia, pero funciona en una ya configurada: el fallo solo aparece al reinstalar | Crear el directorio primero. Lo cazó probar sobre limpio, no sobre la máquina existente |

*(Esta tabla crece según se use. Es la parte más útil del repo.)*

## Lo que falta

- [ ] Prueba de idempotencia en CI, sobre contenedor, para el rol `base`
- [ ] Segundo nodo para que k3s sea un clúster de verdad
- [ ] Copia de seguridad de `/var/lib/rancher` y los volúmenes de Docker
- [ ] `node_exporter` para enganchar con el stack de observabilidad

## Lo que no hace, y por qué

No instala escritorio ni acceso gráfico. Para trabajo de infraestructura es
más lento, se lleva mal con conexiones malas y acostumbra a hacer las cosas
a mano, que es justo lo contrario de lo que este repo defiende.

Tampoco instala `fail2ban`: con SSH cerrado a internet y solo clave pública,
no hay superficie que proteger. Añadirlo sería seguridad de adorno.
