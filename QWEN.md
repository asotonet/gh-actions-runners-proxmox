# QWEN.md - Project Configuration for Qwen Code

## Git Commit Rules

**IMPORTANT**: When making commits, NEVER add "Co-authored-by: Qwen-Coder" or any co-author information.

All commits should only have the human user as the author. The user is:
- Name: asotonet
- Email: asoto.asn@gmail.com

When committing changes:
1. Make clear, descriptive commit messages
2. NEVER include any co-author information
3. NEVER add "Co-authored-by: Qwen-Coder <qwen-coder@alibabacloud.com>"
4. NEVER add any variation of co-author attribution

This is a strict requirement - follow it always.

## Project Overview

GitHub Actions Runners en Proxmox - Automatización para despliegue y gestión de runners auto-hospedados en contenedores LXC con Docker Engine.

## Technology Stack

- **Bash scripts** for automation
- **Proxmox VE API** for LXC container management
- **GitHub Actions API** for runner registration
- **Docker Engine** for containerization within LXC

## Key Files

- `scripts/setup-runner.sh` - Main script to create and configure runners
- `scripts/remove-runner.sh` - Script to remove runners
- `scripts/check-runners.sh` - Script to monitor runner status
- `scripts/health-check.sh` - Comprehensive health verification
- `scripts/backup-runner.sh` - Configuration backup
- `scripts/utils.sh` - Helper functions
- `config/config.example.env` - Configuration template
- `README.md` - Full documentation
- `QUICKSTART.md` - Quick start guide
- `examples/ci-docker-workflow.yml` - CI/CD workflow example
