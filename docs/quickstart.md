# Deception Mesh — Quickstart MVP local

Este quickstart deja un MVP funcional en una máquina limpia con:

- Postgres
- Control Plane
- 1 sensor registrado
- 1 sensor agent levantado por Docker
- sensor visible como `active`
- `last_seen` no nulo
- honeypots HTTP/SSH accesibles localmente

## Objetivo de T29

Validar una instalación reproducible en menos de 10 minutos razonables.

Criterios cubiertos:

- levanta control plane
- registra 1 sensor
- el sensor aparece online
- existe receta mínima y repetible

---

## Requisitos

Necesitas tener instalado:

- Docker
- Docker Compose plugin
- `curl`
- `jq`
- Bash

En Ubuntu/Debian, una base típica sería:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin curl jq