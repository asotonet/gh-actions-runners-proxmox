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
├── config/
│   └── config.example.env    # Plantilla de configuración
├── scripts/
│   ├── setup-runner.sh       # Script principal de configuración
│   ├── remove-runner.sh      # Script para eliminar runners
│   ├── check-runners.sh      # Script para verificar estado
│   └── utils.sh              # Funciones auxiliares
├── logs/                     # Directorio para logs
└── .gitignore
```

## 🔧 Instalación

1. **Clonar el repositorio:**
   ```bash
   git clone https://github.com/TU_USUARIO/gh-actions-runners-proxmox.git
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

### Eliminar un runner

```bash
./scripts/remove-runner.sh --name mi-runner --repo USUARIO/REPO
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

- ⚠️ **NUNCA** commits el archivo `config/config.env` con credenciales reales
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
3. Instalación de Docker Engine
4. Configuración de permisos y cgroups
5. Habilitación del servicio de Docker
6. Verificación de la instalación

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
