# Lo que acabas de aprender sin darte cuenta

Este documento no es un tutorial de Terraform ni de Ansible. Es la
explicación de **lo que has hecho**, con los errores que te encontraste de
verdad como anclas. Léelo ahora que los tienes frescos: dentro de un mes
este texto valdrá la mitad.

---

## 1. El modelo mental: dos capas y una frontera

```
OpenTofu  ──▶  crea CASCARONES     (VMs: CPU, RAM, disco, red, IP)
Ansible   ──▶  pone lo de DENTRO   (paquetes, config, servicios, k3s)
```

La frontera importa porque son herramientas con filosofías distintas.

**OpenTofu lleva la cuenta de lo que existe.** Sabe que creó seis VMs, con
qué identificadores, y si las borras se entera. Es dueño de esos recursos.

**Ansible no lleva la cuenta de nada.** Cada vez que lo ejecutas, mira cómo
está la máquina en ese momento y la empuja hacia el estado que describiste.
No recuerda ejecuciones anteriores. No sabe qué paquetes instaló ayer.

Esa diferencia explica casi todo lo demás.

> **Por qué no usar solo una.** Podrías crear las VMs con Ansible (tiene
> módulos de Proxmox) o configurar el sistema con Terraform (hay
> provisioners). Las dos cosas se hacen mal. Terraform es excelente
> llevando el inventario de recursos de una API y pésimo gestionando el
> interior de un sistema operativo. Ansible es al revés.

---

## 2. OpenTofu: el estado lo es todo

### Declarativo, no imperativo

Un script dice *haz esto, luego esto*. Terraform dice *esto es lo que
quiero que exista*. La diferencia práctica: un script ejecutado dos veces
hace el trabajo dos veces; Terraform ejecutado dos veces no hace nada la
segunda, porque la realidad ya coincide con lo descrito.

### El fichero de estado

Es **el concepto que hay que entender** y el que causa el 80% de los
problemas reales con Terraform.

`terraform.tfstate` es un JSON con el mapa entre lo que escribiste y lo que
existe de verdad en el proveedor:

```
tu código              el estado                    Proxmox
─────────              ─────────                    ───────
vm["master-01"]   ◀──▶  id = 201            ◀──▶   VM 201
```

Sin ese mapa, Terraform no sabría que `vm["master-01"]` y la VM 201 son la
misma cosa. Al ejecutar `plan`, hace tres cosas:

1. Lee el estado (qué creé yo)
2. Pregunta al proveedor cómo están esas cosas ahora (*refresh*)
3. Compara con tu código y calcula la diferencia

El plan que lees es esa diferencia.

**Las tres cosas que importan del estado:**

- **Contiene secretos en claro.** Tu token de API está ahí dentro. Por eso
  `*.tfstate` está en el `.gitignore`.
- **Es local y es de una sola persona.** Vive en tu MacBook. Si lo borras,
  Terraform se olvida de que creó las seis VMs y al siguiente `apply`
  intentará crearlas otra vez — y fallará porque ya existen. En un equipo
  esto se resuelve con *backends remotos* (S3 + bloqueo), que es justo el
  tema de tu proyecto de R4.
- **Puede divergir de la realidad.** Si borras una VM desde la interfaz de
  Proxmox, el estado sigue diciendo que existe hasta el siguiente refresh.
  Eso se llama **drift**.

### Lo que viste cuando falló a medias

Recuerda este error:

```
lvcreate 'pve/vm-201-cloudinit' error: Logical Volume already exists
```

Eso es un `apply` interrumpido. Terraform había creado el disco de la VM
201 y falló al arrancarla (la BIOS). Al reintentar, intentó crear el disco
otra vez y el disco ya estaba.

**Lección:** un `apply` que falla no deja las cosas como estaban. Deja un
estado parcial. La salida es `destroy` y volver a empezar, no insistir.

### El ciclo

| Comando | Qué hace | Cuándo |
| --- | --- | --- |
| `tofu init` | Descarga proveedores, escribe el lockfile | Una vez, y al cambiar proveedores |
| `tofu plan` | Calcula y enseña la diferencia. **No toca nada** | Siempre antes de aplicar |
| `tofu apply` | Ejecuta la diferencia | Cuando el plan te convence |
| `tofu destroy` | Borra todo lo que hay en el estado | Para limpiar |

La línea del final del plan es la que hay que leer:

```
Plan: 6 to add, 0 to change, 0 to destroy.
```

**Mira siempre el número de `destroy`.** Un plan que propone destruir algo
que no esperabas es la señal de alarma más importante de Terraform.

### Proveedores y el lockfile

El proveedor (`bpg/proxmox` en tu caso) es quien sabe hablar con la API.
Terraform solo orquesta.

En `providers.tf` pusiste `version = "~> 0.120"`, que es un *rango*
aceptable. Lo que de verdad fija la versión es `.terraform.lock.hcl`, que
`init` genera y **sí se commitea**. Sin él, dos personas clonan el mismo
repo e instalan versiones distintas del proveedor.

### `for_each`: un bloque, seis máquinas

```hcl
resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.vms
  name     = each.key
  ...
}
```

Esto no crea una VM: crea tantas como entradas tenga el mapa `vms`. Cada
una es un recurso independiente con su dirección: `vm["master-01"]`,
`vm["worker-01"]`...

**Por qué `for_each` y no `count`:** `count` indexa por posición. Si borras
la segunda entrada de una lista de seis, todas las siguientes se desplazan
y Terraform cree que tiene que destruir y recrear cuatro máquinas.
`for_each` indexa por clave, así que borrar `worker-02` solo afecta a
`worker-02`. **En infraestructura real, casi siempre quieres `for_each`.**

### Outputs: cómo una capa alimenta a la otra

```hcl
output "ansible_inventory" { ... }
```

Ese output genera el inventario de Ansible en formato YAML. El `Makefile`
lo vuelca a fichero:

```bash
tofu output -raw ansible_inventory > ../ansible/inventory/vms.yml
```

**El principio:** la lista de máquinas existe en un solo sitio. Si añades
una VM a `variables.tf`, el inventario de Ansible se entera sola. Mantener
dos listas a mano es garantizar que un día no coincidan — y esa es
exactamente la clase de fallo que tarda horas en encontrarse.

---

## 3. Ansible: empujar, no instalar

### Sin agente

Ansible no instala nada en las máquinas que gestiona. Se conecta por SSH,
copia un módulo de Python, lo ejecuta, recoge el resultado y lo borra.

Por eso tu MacBook es el **nodo de control** y Proxmox y las VMs no tienen
Ansible instalado. Y por eso tu pregunta de «¿esto lo ejecuto en Proxmox?»
tenía como respuesta «no, nunca».

### Idempotencia: `ok` frente a `changed`

Esta es la idea central, y es la que hace a Ansible distinto de un script.

```
ok: [master-01]        ← ya estaba como debía. No he tocado nada
changed: [master-01]   ← no estaba así. Lo he cambiado
```

Un módulo bien escrito **comprueba antes de actuar**. `ansible.builtin.apt`
mira si el paquete está instalado; si lo está, no hace nada y reporta `ok`.

La consecuencia práctica: puedes ejecutar el mismo playbook cien veces sin
miedo. La segunda vez no hace trabajo, solo confirma.

> **La prueba de fuego** es `make verify`: ejecuta el playbook dos veces y
> falla si la segunda reporta algún `changed`. Un playbook que no pasa esa
> prueba está mintiendo sobre su propio estado — dice que cambió algo
> cuando ya estaba bien, y eso significa que no sabe mirar.

### Módulos frente a comandos

```yaml
# Mal: siempre reporta changed, no sabe si hacía falta
- ansible.builtin.command: apt install -y curl

# Bien: comprueba, actúa solo si hace falta, reporta la verdad
- ansible.builtin.apt:
    name: curl
    state: present
```

**Usa un módulo siempre que exista uno.** `command` y `shell` son la última
opción, y cuando los uses tienes que decirle a Ansible cuándo considerar
que hubo cambio (`changed_when`) y cuándo fallo (`failed_when`), porque él
solo no puede saberlo.

En tu repo verás `command` en tres sitios: los instaladores de Tailscale y
k3s, y los comandos `qm`/`pveum` de Proxmox. Los tres llevan `creates:` o
`changed_when:` precisamente por esto.

### Inventario y grupos

```yaml
k3s_server:
  hosts:
    master-01:
      ansible_host: 192.168.1.201
```

Un grupo es una etiqueta. Una máquina puede estar en varios. En las obras
eliges a quién te diriges:

```yaml
hosts: k3s_server:k3s_agents:storage:lb:monitoring   # unión
hosts: all:!lb                                        # todas menos lb
```

Y desde la línea de comandos, `--limit master-01` restringe la ejecución a
una sola máquina sin tocar el fichero. **Lo vas a usar constantemente** para
probar un cambio en una máquina antes de soltarlo en las seis.

### Obras, roles, tareas, manejadores

```
playbook (site.yml)
└── obra (play): a qué hosts y con qué roles
    └── rol: un paquete reutilizable de tareas
        ├── tasks/main.yml      lo que hace
        ├── handlers/main.yml   lo que se dispara al final
        └── templates/          ficheros con variables dentro
```

**Los manejadores (handlers)** son tareas que solo corren si algo las
notifica, y **al final de la obra**, una sola vez aunque se notifiquen diez
veces. Es para cosas como «reinicia sshd»: si cambias seis líneas de
`sshd_config`, quieres un reinicio, no seis.

**Por qué k3s está en tres obras separadas en tu `site.yml`:** el nodo
servidor genera un token que los agentes necesitan. Ansible solo propaga
datos entre obras si la del servidor ha corrido antes en la misma
ejecución. Si fuera todo una obra, los agentes intentarían leer un token
que todavía no existe.

### Hechos (facts)

Al empezar, Ansible interroga a cada máquina y guarda cientos de datos:
RAM, CPU, interfaces, distribución, IPs. Son los *facts*.

```bash
ansible master-01 -m setup | less
```

Ese comando te vuelca todo lo que Ansible sabe de una máquina. **Úsalo**
cuando no sepas cómo se llama un dato.

Te encontraste la forma antigua y la nueva:

```yaml
ansible_default_ipv4.address          # deprecado, desaparece en core 2.24
ansible_facts.default_ipv4.address    # la forma correcta
```

Ojo con una excepción que confunde: `ansible_check_mode`, `ansible_play_hosts`
y compañía **no son hechos**, son *variables mágicas* que inyecta el propio
Ansible. Esas no se tocan.

### Variables: de dónde sale cada valor

De menos a más prioridad, en la práctica:

| Dónde | Para qué |
| --- | --- |
| `roles/x/defaults/main.yml` | Valores por defecto del rol, fáciles de pisar |
| `inventory/group_vars/all.yml` | Lo común a todas las máquinas |
| `inventory/group_vars/<grupo>.yml` | Lo propio de un grupo |
| `vars:` en una tarea | Local a esa tarea |
| `-e clave=valor` | Gana a todo. Para pruebas puntuales |

La lista real tiene veintidós niveles. Nunca los vas a necesitar todos.

### `--check`: el modo simulación, y su trampa

`--check` dice «enséñame qué cambiarías sin cambiarlo». Con `--diff`, además
te enseña las líneas exactas.

**La trampa que te comiste:** los módulos `command` y `shell` **no se
ejecutan en modo check**. Ansible no puede saber si un comando arbitrario
escribe o no, así que por seguridad lo salta. Por eso tu `make discover`
recogía cadenas vacías.

La solución es decirle explícitamente cuáles son seguras:

```yaml
- name: Listar los almacenamientos
  ansible.builtin.command: pvesm status
  changed_when: false
  check_mode: false    # esta solo lee: ejecútala también en --check
```

Y la decisión que hay que tomar con cuidado: **esa directiva en una tarea
que escribe hace que `--check` modifique el sistema.** Por eso en tu
`pve.yml` la tarea que modifica la ACL se quedó fuera, aunque también lleve
`changed_when: false`.

---

## 4. Los comandos que vas a usar de verdad

```bash
# Ver sin tocar
tofu plan
ansible-playbook site.yml --check --diff

# Limitar el alcance
ansible-playbook site.yml --limit master-01
ansible-playbook site.yml --tags docker
tofu plan -target='proxmox_virtual_environment_vm.vm["master-01"]'

# Mirar el estado
tofu state list
tofu state show 'proxmox_virtual_environment_vm.vm["master-01"]'
ansible master-01 -m setup

# Comprobar conectividad
ansible all -m ping

# Retomar donde se rompió
ansible-playbook site.yml --start-at-task "Instalar Docker"
```

`-target` y `--limit` son para depurar, no para el uso normal. Si acabas
aplicando siempre con `-target`, es que el código está mal dividido.

---

## 5. Las siete roturas, y qué enseña cada una

| Rotura | La lección |
| --- | --- |
| `vault_password_file` en `ansible.cfg` | Una configuración que exige un fichero que no existe rompe el clon recién hecho. Prueba siempre desde cero, no desde tu máquina ya configurada |
| Rutas viejas en `.gitignore` | Al reestructurar, los patrones de ignorar también se mueven. `git check-ignore -v <fichero>` comprueba de verdad, en vez de suponer |
| Callback `yaml` eliminado | Las colecciones tienen su propio versionado y eliminan cosas. `ansible-doc` dice la verdad sobre lo que hay instalado; tu memoria, no |
| `result_format` en vez de `callback_result_format` | **Una clave de configuración que no existe se ignora en silencio.** Ni error ni aviso. Si una opción no hace nada, verifica que existe antes de buscar otra causa |
| DNS en `192.168.0.1` | El síntoma estaba en `apt` y la causa tres capas más abajo. **Diagnostica antes de arreglar**, o romperás algo que funcionaba |
| SVM desactivado en la BIOS | Hay una capa por debajo del sistema operativo. Cuando nada de lo de arriba explica el fallo, baja un piso |
| `sysctl` sin el módulo cargado | Los parámetros del kernel no existen hasta que existe el módulo. El orden de las tareas no es estético: es una dependencia |

El patrón que se repite en cinco de las siete: **el mensaje de error
señalaba un sitio y el problema estaba en otro.** Interiorizar eso vale más
que memorizar la sintaxis de cualquiera de las dos herramientas.

---

## 6. Para practicar esta semana

Treinta minutos, y entenderás el modelo de estado mejor que leyendo mil
páginas. Todo esto es seguro: lo peor que pasa es que recreas una VM.

**1. Mira el estado por dentro**

```bash
cd terraform && tofu state list && tofu state show 'proxmox_virtual_environment_vm.vm["lb-01"]'
```

Busca el `id`. Ese número es el enlace con Proxmox.

**2. Provoca un drift**

Apaga y borra `lb-01` desde la interfaz de Proxmox. Luego:

```bash
tofu plan
```

Fíjate en que dice `1 to add`. Terraform ha preguntado al proveedor, ha
visto que no está, y propone recrearla. **Eso es el refresh en acción.**
Haz `tofu apply` y vuelve a existir.

**3. Cambia algo en caliente**

Sube la RAM de `lb-01` a 2048 en `variables.tf` y haz `tofu plan`.
La pregunta: ¿dice `1 to change` o `1 to destroy and 1 to add`? El
proveedor decide si un atributo se puede modificar en sitio o exige
recrear. Averiguar cuáles son destructivos es media batalla de Terraform.

**4. Comprueba la idempotencia**

```bash
make config
```

Otra vez. Debe salir `changed=0` en las seis máquinas. Si alguna tarea
reporta `changed` siempre, está mal escrita.

**5. Rompe algo y míralo curarse**

```bash
ssh isaac@192.168.1.201 'sudo rm /etc/sysctl.d/99-lab.conf'
```

Y luego `make config`. Ansible lo detecta y lo repone. Eso es la
convergencia: no importa cómo esté la máquina, acaba en el estado descrito.

**6. Lee un diff antes de aplicarlo**

Añade `tree` a la lista de paquetes de `roles/base/tasks/main.yml` y:

```bash
cd ansible && ansible-playbook site.yml --tags base --check --diff --limit lb-01
```

---

## 7. Errores que vas a cometer

- **Editar a mano algo que gestiona Terraform.** Al siguiente `apply` te lo
  revierte. Si necesitas tocar algo en caliente, hazlo sabiendo que es
  temporal.
- **Confiar en `--check` para todo.** Ya sabes que no ejecuta comandos, y
  además no puede predecir lo que depende de una tarea anterior que tampoco
  se ejecutó.
- **Perder el `tfstate`.** Haz copia antes de experimentar con él.
- **`changed_when: false` para callar el ruido.** Si una tarea reporta
  cambio siempre, la pregunta es por qué, no cómo silenciarla.
- **Poner `latest` en una versión.** Convierte una máquina reproducible en
  una que funciona hoy y mañana no.
- **Olvidar que el estado tiene secretos.** No lo pegues en un chat ni lo
  subas a ningún sitio.

---

## 8. Dónde está la verdad cuando dudes

| Pregunta | Comando |
| --- | --- |
| ¿Qué opciones tiene este módulo? | `ansible-doc ansible.builtin.apt` |
| ¿Existe esta clave de configuración? | `ansible-doc -t callback ansible.builtin.default` |
| ¿Qué sabe Ansible de esta máquina? | `ansible master-01 -m setup` |
| ¿Qué configuración está activa? | `ansible-config dump --only-changed` |
| ¿Qué atributos tiene este recurso? | Documentación del proveedor en el registro |
| ¿Qué hay en el estado? | `tofu state show <dirección>` |

Esa es la costumbre que más te va a valer: **preguntarle a la herramienta
instalada en vez de a tu memoria.** Es lo que evitó que nos tragáramos el
nombre equivocado de la clave del callback, y lo que te salvó de añadir un
repositorio de `bookworm` a un sistema `trixie`.
