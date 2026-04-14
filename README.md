# GitHub Actions Runners en Proxmox (LXC)

Automatización para el despliegue y gestión de GitHub Actions runners auto-hospedados en contenedores LXC de Proxmox con Docker Engine.

## 📋 Descripción

Este proyecto proporciona scripts para automatizar la creación, configuración y gestión de runners de GitHub Actions en contenedores LXC en un entorno Proxmox VE. Cada contenedor incluye Docker Engine preinstalado y configurado con los permisos de kernel necesarios.

Características principales:
- Crear y configurar contenedores LXC con runners automáticamente
- Instalar y configurar Docker Engine en cada contenedor
- Configurar permisos de kernel para Docker (cgroups, AppArmor, etc.)
- Gestionar el ciclo de vida de los runners
- Configurar runners para repositorios u organizaciones
- Monitorizar el estado de los runners
- Verificación de salud del runner
- Backup automático de configuración

## 🚀 Requisitos

- **Proxmox VE** 7.x o superior
- **Bash** 5.0+
- **Proxmox VE API access** con permisos adecuados
- **Token de GitHub** con permisos para registrar runners
- **jq** para procesamiento de JSON
- **curl** para peticiones HTTP
- **Template LXC** con soporte para contenedores no privilegiados (recomendado)
- **Permisos de nestificación** para Docker en LXC (cgroups v2)

## 📁 Estructura del Proyecto

```
gh-actions-runners-proxmox/
├── README.md                 # Documentación del proyecto
├── QUICKSTART.md             # Guía de inicio rápido (15 min)
├── config/
│   └── config.example.env    # Plantilla de configuración
├── scripts/
│   ├── setup-runner.sh       # Script principal de configuración
│   ├── remove-runner.sh      # Script para eliminar runners
│   ├── check-runners.sh      # Script para verificar estado
│   ├── health-check.sh       # Verificación de salud completa
│   ├── backup-runner.sh      # Backup de configuración
│   └── utils.sh              # Funciones auxiliares
├── examples/
│   └── ci-docker-workflow.yml  # Ejemplo de pipeline CI/CD
├── logs/                     # Directorio para logs
└── .gitignore
```

## 🚀 Inicio Rápido

¿Quieres tener un runner funcionando en **15 minutos**?

👉 Lee la [Guía de Inicio Rápido](QUICKSTART.md)

## 🔧 Instalación

1. **Clonar el repositorio:**
   ```bash
   git clone https://github.com/asotonet/gh-actions-runners-proxmox.git
   cd gh-actions-runners-proxmox
   ```

2. **Configurar variables de entorno:**
   ```bash
   cp config/config.example.env config/config.env
   ```

   Editar `config/config.env` con tus credenciales y configuración.

3. **Dar permisos de ejecución:**
   ```bash
   chmod +x scripts/*.sh
   ```

## 📖 Uso

### Configurar un nuevo runner

```bash
./scripts/setup-runner.sh --name mi-runner --repo USUARIO/REPO
```

### Verificar estado de runners

```bash
./scripts/check-runners.sh --repo USUARIO/REPO
```

### Verificar salud del runner

```bash
./scripts/health-check.sh
```

### Crear backup de configuración

```bash
./scripts/backup-runner.sh --compress --include-docker --include-logs
```

### Eliminar un runner

```bash
./scripts/remove-runner.sh --name mi-runner --repo USUARIO/REPO --force
```

## ⚙️ Variables de Configuración

Crear un archivo `config/config.env` basado en `config/config.example.env`:

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `PROXMOX_HOST` | Host de Proxmox | `192.168.1.100` |
| `PROXMOX_PORT` | Puerto de la API | `8006` |
| `PROXMOX_USER` | Usuario de Proxmox | `root@pam` |
| `PROXMOX_PASSWORD` | Contraseña de Proxmox | `tu_password` |
| `PROXMOX_NODE` | Nodo de Proxmox | `pve` |
| `GITHUB_TOKEN` | Token de acceso personal de GitHub | `ghp_xxxxx` |
| `RUNNER_VERSION` | Versión del runner | `2.311.0` |
| `LXC_TEMPLATE` | ID del template LXC | `ubuntu-22.04-standard` |
| `LXC_STORAGE` | Almacenamiento para LXC | `local-lvm` |
| `LXC_MEMORY` | Memoria RAM para LXC (MB) | `4096` |
| `LXC_CPUS` | Número de CPUs | `2` |
| `LXC_DISK` | Tamaño de disco (GB) | `30` |
| `LXC_UNPRIVILEGED` | Contenedor no privilegiado | `1` (recomendado) |
| `LXC_NESTING` | Habilitar nestificación | `1` (requerido para Docker) |
| `LXC_KEYCTL` | Habilitar keyctl | `1` (requerido para Docker) |
| `DOCKER_VERSION` | Versión de Docker | `24.0.7` |
| `RUNNER_USER` | Nombre del usuario dedicado | `runner` |

### ⚠️ Importante sobre los tokens de GitHub

- **`GITHUB_TOKEN`**: Es tu **Personal Access Token (PAT)** con permisos de administrador del repositorio u organización. Este token se usa para llamar a la API de GitHub y **NO caduca con cada runner**.
- **Token de registro del runner**: El script solicita automáticamente un **token nuevo y de un solo uso** por cada runner que creas. Este token:
  - ✅ Se genera automáticamente vía API de GitHub
  - ⏱️ Expira en 1 hora
  - 🔒 Solo se puede usar UNA vez
  - 🔄 Cada runner requiere un token diferente

## 🔒 Seguridad

- ⚠️ **NUNCA** hagas commit del archivo `config/config.env` con credenciales reales
- Usar variables de entorno para datos sensibles en CI/CD
- Rotar regularmente los tokens de GitHub
- Restringir permisos de la API de Proxmox

## 📝 Logs

Los logs se guardan en el directorio `logs/` con el formato:
- `setup-runner-YYYY-MM-DD.log`
- `remove-runner-YYYY-MM-DD.log`
- `check-runners-YYYY-MM-DD.log`
- `docker-install-YYYY-MM-DD.log`

## 🐳 Configuración de Docker en LXC

Para que Docker funcione correctamente en contenedores LXC, se requieren las siguientes configuraciones:

### Características del contenedor:
- **Nesting**: Habilitado (permite ejecutar Docker dentro de LXC)
- **Keyctl**: Habilitado (requerido para Docker)
- **cgroups v2**: Soporte habilitado
- **AppArmor**: Perfil sin restricciones para Docker

### Script de instalación de Docker:
El script `setup-runner.sh` incluye automáticamente:
1. Instalación de dependencias necesarias
2. Configuración del repositorio oficial de Docker
3. Instalación de Docker Engine con BuildKit habilitado
4. Configuración de permisos y cgroups para LXC
5. Habilitación del servicio de Docker
6. Verificación de la instalación con test de build

### 📁 Directorios y Permisos de Docker

El script configura automáticamente los siguientes directorios con permisos correctos:

| Directorio | Propósito | Permisos | Dueño |
|------------|-----------|----------|-------|
| `/var/lib/docker` | Datos de Docker (imágenes, contenedores, volúmenes) | `710` | `root:docker` |
| `/home/runner/actions-runner/_work` | Directorio de trabajo del runner (bind mounts) | `755` | `runner:runner` |
| `/home/runner/docker-volumes` | Volúmenes compartidos accesibles | `755` | `runner:runner` |
| `/tmp/docker-builds` | Directorio temporal para builds | `1777` | `root:root` |
| `/home/runner/.docker` | Configuración de BuildKit | `700` | `runner:runner` |

### 🔑 Permisos para Docker Builds

El script maneja automáticamente:

1. **Usuario en grupo docker**: El usuario `runner` puede ejecutar Docker sin sudo
2. **BuildKit habilitado**: Para builds más rápidos y con mejor manejo de caché
3. **Bind mounts funcionales**: El directorio `_work` tiene permisos `755` para que Docker pueda montar archivos desde el job
4. **Verificación de builds**: Se realiza un build de prueba para confirmar que todo funciona
5. **Storage driver overlay2**: Óptimo para contenedores LXC

### ⚙️ Configuración de daemon.json

Docker se configura con:
```json
{
  "storage-driver": "overlay2",
  "data-root": "/var/lib/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "features": {
    "buildkit": true
  }
}
```

### 🔐 Docker Login y Registros

El runner se configura con un archivo `config.json` vacío en `/home/runner/.docker/config.json`. Para hacer **docker login** en tus pipelines, usa **GitHub Secrets**:

#### Secrets necesarios en GitHub:
| Secret | Descripción | Ejemplo |
|--------|-------------|---------|
| `DOCKER_USERNAME` | Usuario del registry | `miusuario` |
| `DOCKER_PASSWORD` | Password o token de acceso | `ghp_xxxxx` o token |
| `DOCKER_REGISTRY_URL` | URL del registry (opcional) | `docker.io`, `ghcr.io` |

#### Ejemplo de uso en workflow:
```yaml
- name: Login to Docker Hub
  uses: docker/login-action@v3
  with:
    username: ${{ secrets.DOCKER_USERNAME }}
    password: ${{ secrets.DOCKER_PASSWORD }}

# O con Docker CLI directamente:
- name: Login and Push
  run: |
    echo "${{ secrets.DOCKER_PASSWORD }}" | docker login -u "${{ secrets.DOCKER_USERNAME }}" --password-stdin
    docker build -t mi-imagen:latest .
    docker push mi-imagen:latest
```

### ⚙️ Configuración de LXC para Docker

**IMPORTANTE**: Para que Docker funcione dentro de un contenedor LXC, se requieren estas configuraciones en `/etc/pve/lxc/<ct_id>.conf`:

```
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file,optional 0 0
```

El script `setup-runner.sh` aplica estas configuraciones automáticamente vía API de Proxmox y reinicia el contenedor.

**No se requiere SSH** — todo se gestiona mediante la API REST de Proxmox con autenticación por ticket.

## 🤝 Contribuir

1. Fork el proyecto
2. Crear una rama para tu feature (`git checkout -b feature/nueva-funcionalidad`)
3. Commit tus cambios (`git commit -m 'Añadir nueva funcionalidad'`)
4. Push a la rama (`git push origin feature/nueva-funcionalidad`)
5. Abrir un Pull Request

## 📄 Licencia

Este proyecto está bajo la Licencia MIT. Ver [LICENSE](LICENSE) para más detalles.

## ⚠️ Disclaimer

Este proyecto es una herramienta de automatización. Úsalo bajo tu propia responsabilidad. Siempre prueba en un entorno de desarrollo antes de usar en producción.

## 📞 Soporte

Para issues o preguntas, abrir un issue en el repositorio de GitHub.
