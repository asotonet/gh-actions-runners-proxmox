# GitHub Actions Runners en Proxmox

Automatización para el despliegue y gestión de GitHub Actions runners auto-hospedados en máquinas virtuales de Proxmox.

## 📋 Descripción

Este proyecto proporciona scripts para automatizar la creación, configuración y gestión de runners de GitHub Actions en un entorno Proxmox VE. Permite:

- Crear y configurar runners auto-hospedados automáticamente
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
| `GITHUB_TOKEN` | Token de GitHub | `ghp_xxxxx` |
| `RUNNER_VERSION` | Versión del runner | `2.311.0` |
| `VM_TEMPLATE` | ID del template VM | `9000` |
| `VM_STORAGE` | Almacenamiento para VMs | `local-lvm` |

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
