# El hierro

Lo que **hay de verdad** en la máquina, averiguado preguntándoselo a ella y
no leyendo la caja. Cada dato lleva el comando con el que se obtuvo, para
que puedas volver a comprobarlo cuando cambie algo.

Tomado el 2026-11-08 sobre Proxmox 9.1.6 (Debian 13 trixie, kernel 6.17.13).

---

## Procesador

```
AMD Ryzen 5 3600X · 6 núcleos · 12 hilos
```

```bash
grep -m1 'model name' /proc/cpuinfo; nproc
```

**Virtualización por hardware (SVM):** activada en la BIOS. Estuvo
desactivada hasta el 2026-11-06 y era la razón de que ninguna VM arrancara.

```bash
grep -c -E 'svm|vmx' /proc/cpuinfo   # debe devolver 12, no 0
```

---

## Memoria — el recurso que limita todo

```
3 × 8 GB DDR4 @ 2133 MT/s   ·   4 ranuras   ·   máximo 128 GB
23,4 GB utilizables
```

```bash
dmidecode -t memory | grep -E 'Size|Locator|Speed|Maximum Capacity'
```

Dos cosas a tener presentes:

- **Configuración asimétrica.** Tres módulos en una placa de cuatro ranuras
  deja un canal cojo. Ryzen rinde mejor con pares.
- **2133 MT/s es la velocidad segura de DDR4.** Un 3600X va bastante mejor a
  3200 porque el Infinity Fabric se sincroniza con la memoria. La mezcla de
  tres módulos probablemente fuerza esa caída.

**Hay una ranura libre.** La mejora más rentable del equipo es un kit de
2 × 16 GB a 3200 retirando los tres de 8: 32 GB, doble canal y la velocidad
que la CPU quiere, por 55-70 €.

### Reparto actual

| VM | RAM | Papel |
| --- | --- | --- |
| master-01 (201) | 4 GB | Plano de control de k3s |
| worker-01 (202) | 4 GB | |
| worker-02 (203) | 4 GB | |
| **Comprometido** | **12 GB** | |
| Libre | ~11 GB | Reservado para el nodo con GPU |

`free -h` en el anfitrión enseña *menos* uso del asignado: KVM reserva
memoria de forma perezosa y el invitado solo ocupa lo que toca. **El número
que importa para planificar es el asignado, no el usado.**

---

## Gráfica

```
06:00.0  AMD/ATI Ellesmere [1002:67df]  ·  Polaris (gfx803)
Subsistema: Sapphire "Radeon RX 570 Pulse 4GB" [1da2:e353]
VRAM real: 8192 MiB
```

```bash
lspci -nnk | grep -A3 -i VGA
cat /sys/class/drm/card*/device/mem_info_vram_total   # en bytes
```

> **La etiqueta miente y el kernel no.** El identificador de subsistema dice
> «4GB» pero `mem_info_vram_total` reporta 8192 MiB. O es una variante de
> 8 GB con el SSID mal puesto de fábrica, o lleva la BIOS reflasheada. Al
> buscar información del modelo, fíate del segundo dato.

### Qué se puede y qué no

| | |
| --- | --- |
| **ROCm** | **No.** Polaris quedó fuera del soporte hace años |
| **vLLM** | **No.** Necesita ROCm o CUDA |
| **llama.cpp + Vulkan** | **Sí.** Es el camino para esta tarjeta |
| Modelo que entra en 8 GB | 7B cuantizado a Q4_K_M (~4,7 GB), con margen para el contexto |

### Passthrough

**Viable, y el grupo IOMMU está limpio:**

```
Grupo 12:  06:00.0  la GPU
Grupo 12:  06:00.1  su audio HDMI
```

```bash
for g in /sys/kernel/iommu_groups/*/devices/*; do
  echo "$(echo $g | cut -d/ -f5) $(basename $g)"
done | sort -n
```

Solo la tarjeta y su función de audio. Se pasan las dos juntas y no se
arrastra nada esencial del sistema.

**Dos avisos antes de hacerlo:**

1. **No hay gráficos integrados.** El 3600X no los lleva y solo hay un
   controlador de vídeo. Al pasar la tarjeta a una VM, el anfitrión se queda
   **sin consola**. Mientras la red funcione se arregla por SSH; el riesgo es
   quedarse sin las dos cosas. Regla: nunca toques configuración de red y de
   GPU en la misma sesión.
2. **Las Polaris arrastran el *AMD reset bug*.** Tras reiniciar la VM, la
   tarjeta a menudo no reinicializa sin el módulo `vendor-reset` o un
   reinicio del anfitrión. Es salvable, pero cuenta con perder una tarde.

Ahora mismo la ocupa el anfitrión con el driver `amdgpu`. Para el passthrough
habrá que soltarla y atarla a `vfio-pci`.

---

## Almacenamiento

```
local      (dir)      98 GB   ·   ~87 GB libres   ·   ISOs y plantillas
local-lvm  (lvmthin) 335 GB   ·   pool 'data' 319,6 GB al 23 %
```

```bash
pvesm status
lvs -o lv_name,lv_size,data_percent pve
```

**No es ZFS**, es LVM-thin. Consecuencia práctica: no hay caché ARC
comiéndose la RAM, así que el anfitrión se conforma con 1,5-2 GB. Los
volúmenes finos sí admiten snapshots.

Quedan ~246 GB libres. Las VMs artesanales 101-106, paradas, ocupan unos
30-35 GB del pool.

---

## Red

```
vmbr0   UP        enlace físico   ·   192.168.1.180/24   ·   puerta 192.168.1.1
vmbr1   sin enlace               ·   10.10.10.0/24, anfitrión en .1   ·   interna
```

```bash
ip -br link show type bridge
ip route
```

Las VMs van por `vmbr0` con IPs estáticas de cloud-init, en el rango
`.201`-`.203`. `vmbr1` existe de una configuración anterior y no se usa.

**El DNS estaba mal:** apuntaba a `192.168.0.1`, otra subred. Internet
funcionaba por IP y ninguna consulta de nombre resolvía. Corregido con
`pvesh set /nodes/isaac/dns`, no editando `/etc/resolv.conf`, que la interfaz
sobrescribe.

---

## La plantilla de VM

```
VMID 9000  ·  ubuntu-template  ·  Ubuntu 22.04 LTS, kernel 5.15
ciuser: isaac  ·  cloud-init en ide2  ·  agent: enabled=1
disco base: 2252 MiB (se agranda al clonar)
```

```bash
qm config 9000
```

**22.04 es una LTS de 2022** y su soporte estándar acaba en abril de 2027.
Funciona bien con k3s 1.37, pero rehacerla sobre 24.04 es el ejercicio ideal
para comprobar que el clúster es realmente desechable: cambias una variable,
`make destroy`, `make vms`, `make config`.

**Ojo con `agent: enabled=1`:** el indicador está puesto en la plantilla,
pero eso solo le dice a Proxmox que *intente* hablar con el agente. Por eso
OpenTofu lo tiene desactivado al crear — ver la decisión en el README.

---

## Lo que conviene re-comprobar cuando algo cambie

```bash
make discover
```

Lee el hipervisor sin tocar nada y aborta si el almacenamiento configurado
no coincide con el que existe.
