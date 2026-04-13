# 🚀 Guía de Inicio Rápido

## GitHub Actions Runners en Proxmox (LXC + Docker)

Esta guía te permitirá configurar un runner de GitHub Actions en un contenedor LXC de Proxmox con Docker Engine en **menos de 15 minutos**.

---

## 📋 Prerrequisitos

- ✅ Proxmox VE 7.x o superior configurado
- ✅ Template LXC de Ubuntu 22.04 descargado
- ✅ Token de GitHub con permisos de administrador del repositorio
- ✅ Acceso root al host de Proxmox (para crear contenedores)
- ✅ Conectividad de red desde Proxmox a GitHub

---

## 🎯 Paso 1: Clonar y Configurar

```bash
# Clonar el repositorio
git clone https://github.com/TU_USUARIO/gh-actions-runners-proxmox.git
cd gh-actions-runners-proxmox

# Copiar archivo de configuración
cp config/config.example.env config/config.env

# Editar con tus credenciales
nano config/config.env
```

**Configuración mínima requerida:**
```bash
# Proxmox
PROXMOX_HOST="192.168.1.100"
PROXMOX_USER="root@pam"
PROXMOX_PASSWORD="tu_password"
PROXMOX_NODE="pve"

# GitHub (Personal Access Token)
GITHUB_TOKEN="ghp_xxxxx"

# LXC Template
LXC_TEMPLATE="ubuntu-22.04-standard"
LXC_STORAGE="local-lvm"
```

---

## 🛠️ Paso 2: Crear el Runner

```bash
# Dar permisos de ejecución
chmod +x scripts/*.sh

# Crear runner para un repositorio
./scripts/setup-runner.sh \
  --name mi-runner-01 \
  --repo TU_USUARIO/TU_REPOSITORIO

# O para una organización
./scripts/setup-runner.sh \
  --name org-runner-01 \
  --org MI_ORGANIZACION \
  --labels "linux,docker,ci-cd"
```

**El script hará automáticamente:**
1. ✅ Crear contenedor LXC en Proxmox
2. ✅ Configurar AppArmor y capacidades para Docker
3. ✅ Instalar Docker Engine con BuildKit
4. ✅ Crear usuario dedicado `runner` con permisos de sudo
5. ✅ Añadir usuario al grupo `docker` (sin sudo)
6. ✅ Configurar directorios de build con permisos correctos
7. ✅ Instalar GitHub Actions runner
8. ✅ Verificar que todo funciona

---

## 🔧 Paso 3: Verificar Configuración de LXC

**IMPORTANTE:** Después de crear el contenedor, el script te mostrará las configuraciones aplicadas. Si el script no pudo aplicarlas automáticamente, debes hacerlo manualmente:

```bash
# Editar configuración del contenedor en Proxmox
nano /etc/pve/lxc/<CT_ID>.conf

# Agregar estas líneas al final:
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file,optional 0 0
```

**Reiniciar el contenedor:**
```bash
pct shutdown <CT_ID> && pct start <CT_ID>
```

---

## ✔️ Paso 4: Verificar que Todo Funciona

```bash
# Ejecutar script de verificación
./scripts/health-check.sh

# O manualmente en el contenedor
pct exec <CT_ID> -- sudo -u runner bash -c '
  docker --version
  docker run --rm hello-world
  cd /home/runner/actions-runner && ./svc.sh status
'
```

---

## 🐳 Paso 5: Configurar Docker Login (Opcional)

Si necesitas hacer push/pull de imágenes privadas, configura **GitHub Secrets** en tu repositorio:

1. Ve a: `https://github.com/TU_USUARIO/TU_REPOSITORIO/settings/secrets/actions`

2. Agrega estos secrets:
   - `DOCKER_USERNAME`: Tu usuario de Docker Hub
   - `DOCKER_PASSWORD`: Tu password o token de acceso

3. Usa en tu workflow:
```yaml
- name: Login to Docker Hub
  uses: docker/login-action@v3
  with:
    username: ${{ secrets.DOCKER_USERNAME }}
    password: ${{ secrets.DOCKER_PASSWORD }}
```

---

## 🚀 Paso 6: Usar el Runner en un Workflow

Crea un archivo `.github/workflows/ci.yml` en tu repositorio:

```yaml
name: CI con Docker

on:
  push:
    branches: [ main ]

jobs:
  build:
    runs-on: self-hosted  # ← Usa tu runner auto-hospedado
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      
      - name: Build Docker image
        run: |
          docker build -t mi-app:latest .
          docker push mi-app:latest
```

---

## 📊 Monitoreo y Mantenimiento

### Ver estado del runner
```bash
# Verificar salud completa
./scripts/health-check.sh

# Ver runners en GitHub
./scripts/check-runners.sh --repo TU_USUARIO/TU_REPOSITORIO
```

### Backup de configuración
```bash
# Crear backup completo
./scripts/backup-runner.sh \
  --compress \
  --include-docker \
  --include-logs \
  --ct-id <CT_ID>
```

### Eliminar un runner
```bash
./scripts/remove-runner.sh \
  --name mi-runner-01 \
  --repo TU_USUARIO/TU_REPOSITORIO \
  --force
```

---

## ❓ Troubleshooting

### Docker no funciona en el contenedor
```bash
# Verificar configuraciones LXC
cat /etc/pve/lxc/<CT_ID>.conf | grep -E "apparmor|cap.drop|cgroup"

# Debe mostrar:
# lxc.apparmor.profile: unconfined
# lxc.cap.drop:
# lxc.cgroup2.devices.allow: a
```

### Runner no aparece en GitHub
```bash
# Verificar registro
pct exec <CT_ID> -- sudo -u runner bash -c '
  cd /home/runner/actions-runner
  cat .runner
'

# Re-registrar si es necesario
pct exec <CT_ID> -- sudo -u runner bash -c '
  cd /home/runner/actions-runner
  ./config.sh --url https://github.com/TU_USUARIO/TU_REPOSITORIO --token TU_TOKEN
'
```

### Permisos de Docker incorrectos
```bash
# Verificar que runner está en grupo docker
pct exec <CT_ID> -- groups runner

# Debe mostrar: runner : runner docker

# Si no aparece, añadir manualmente
pct exec <CT_ID> -- usermod -aG docker runner
```

---

## 📚 Documentación Adicional

- [README.md](README.md) - Documentación completa del proyecto
- [examples/ci-docker-workflow.yml](examples/ci-docker-workflow.yml) - Ejemplo completo de CI/CD
- [config/config.example.env](config/config.example.env) - Todas las variables de configuración

---

## 🆘 Soporte

Si encuentras problemas:
1. Revisa la sección de Troubleshooting
2. Ejecuta `./scripts/health-check.sh` y comparte el output
3. Abre un issue en GitHub con los logs del runner

---

**¡Listo! Tu runner está configurado y listo para ejecutar pipelines CI/CD con Docker** 🎉
