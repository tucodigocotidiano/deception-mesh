# Deception Mesh

MVP defensivo de **deception telemetry** para capturar actividad sospechosa temprana mediante sensores señuelo distribuidos. El proyecto combina un **control plane** multi-tenant en Rust, un **sensor agent** con honeypots HTTP/SSH y un pipeline reproducible para **ingesta, severidad, consulta, webhook y exportación CSV**.

> Estado actual: **MVP funcional y validado en laboratorio y VPS**. El sistema ya registra intentos reales sobre trampas HTTP expuestas, persiste eventos, clasifica severidad y puede despachar alertas por webhook.

---

## Qué resuelve

En muchas organizaciones, el primer contacto del atacante con la infraestructura es un toque pequeño y ambiguo: un `HEAD /login`, una prueba a `/wp-login.php`, un intento SSH sin autenticación válida. Esas señales suelen perderse entre logs dispersos o quedar mezcladas con tráfico legítimo. Deception Mesh busca convertir ese ruido en evidencia accionable y de alta fidelidad.

## Capacidades actuales

- honeypot SSH ligero
- honeypot HTTP con rutas trampa (`/login`, `/admin`, `/wp-login.php`)
- registro de sensores por token de enrolamiento
- heartbeat y estado `active/offline`
- autenticación JWT para usuarios
- autorización multi-tenant con RBAC
- ingesta tipada de eventos `EventV1`
- clasificación de severidad por reglas y repetición
- historial de auditoría para cambios administrativos
- cola de webhooks con reintentos y backoff
- exportación CSV de eventos
- quickstart reproducible y suites E2E
- empaquetado Docker y workflows de GitHub Actions

---

## Cambios de empaquetado en esta versión

Esta entrega quedó preparada para subirse a GitHub sin arrastrar residuos locales. Se corrigió lo siguiente:

- se eliminaron archivos generados, temporales y secretos de runtime
- se corrigió `.gitignore`
- se agregaron reglas de fin de línea LF para evitar errores tipo `$'\r': command not found` en Bash
- el `docker-compose.yml` local ya **no usa `container_name` fijos**, para reducir conflictos entre entornos de prueba
- el quickstart local ahora puede convivir mejor con puertos ocupados
- el flujo de producción permite definir `SENSOR_CONTROL_PLANE_BASE_URL` si Docker Desktop/WSL necesita `host.docker.internal`

---

## Arquitectura

```text
scanner / atacante
        │
        ▼
  sensor_agent
  ├─ SSH trap
  ├─ HTTP trap
  └─ reporter + heartbeat
        │
        ▼
  control_plane API
  ├─ auth / RBAC
  ├─ ingest
  ├─ severity engine
  ├─ audit log
  ├─ webhook queue
  └─ CSV export
        │
        ▼
     Postgres
```

Más detalle en [`docs/architecture.md`](docs/architecture.md).

---

## Estructura del repositorio

```text
.
├── crates/
│   ├── control_plane/
│   ├── sensor_agent/
│   └── shared/
├── deploy/
│   ├── docker/
│   ├── runtime/
│   ├── sensor/
│   └── sql/
├── docs/
├── scripts/
├── docker-compose.yml
└── compose.production.yml
```

### Componentes

- `crates/control_plane`: API central, auth, RBAC, severidad, webhooks y consultas.
- `crates/sensor_agent`: honeypots, heartbeat y envío de eventos.
- `crates/shared`: tipos compartidos y esquema `EventV1`.
- `deploy/sql`: esquema y bootstrap de base de datos.
- `scripts/`: quickstart, smoke tests, E2E y utilidades operativas.
- `docs/`: arquitectura, scope, runbook, notas de seguridad y consultas.

---

## Quickstart local

### Requisitos

- Docker + Docker Compose plugin
- Bash
- `curl`
- `jq`
- Rust estable

### Arranque rápido

```bash
bash scripts/t29_install_mvp_local.sh
bash scripts/e2e_t29_quickstart.sh
```

### Arranque manual mínimo

```bash
docker compose up -d --build postgres control_plane
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/ready
```

### Demo end-to-end

```bash
bash scripts/demo.sh
```

Más detalle en [`docs/quickstart.md`](docs/quickstart.md).

---

## Flujo recomendado para VPS

### 1) Preparar entorno

```bash
cp .env.production.example .env.production
nano .env.production
bash scripts/prepare_sql_prod.sh
bash scripts/build_local_images.sh
```

### 2) Levantar control plane + base de datos

```bash
bash scripts/deploy_production.sh
```

### 3) Crear admin y tenant inicial

```bash
bash scripts/bootstrap_production_admin.sh "tu-correo@dominio.com" "TU_PASSWORD_SUPER_LARGO" "Mi Tenant"
```

### 4) Registrar el sensor

```bash
bash scripts/register_production_sensor.sh "tu-correo@dominio.com" "TU_PASSWORD_SUPER_LARGO" "<TENANT_ID>" "sensor-vps-01"
```

### 5) Ejecutar smoke test

```bash
bash scripts/production_smoke_test.sh "tu-correo@dominio.com" "TU_PASSWORD_SUPER_LARGO" "<TENANT_ID>"
```

---

## Solución rápida de problemas reales

### Error `pull access denied for deceptionmesh-control-plane`

No rompe el despliegue si ya construiste las imágenes locales con:

```bash
bash scripts/build_local_images.sh
```

El `deploy_production.sh` ya continúa con `up -d` usando la imagen local.

### Error `$'\r': command not found` al cargar `.env.production`

Eso ocurre por saltos de línea Windows. Esta versión ya fuerza LF en el repo, pero si editas el archivo con herramientas que vuelvan a meter CRLF, conviértelo otra vez a LF.

### Error `Bind for 0.0.0.0:2222 failed: port is already allocated`

Tienes otro proceso o contenedor usando el puerto. Libera el puerto o cambia en `.env.production`:

```env
SENSOR_SSH_PORT=3222
SENSOR_HTTP_PORT=18081
SENSOR_HTTPS_PORT=18443
```

### En WSL/Docker Desktop el sensor no logra hablar con el control plane

Prueba en `.env.production`:

```env
SENSOR_CONTROL_PLANE_BASE_URL=http://host.docker.internal:18080
```

---

## Consultas operativas útiles

Las consultas operativas quedaron documentadas en:

- [`docs/consultas-operativas.md`](docs/consultas-operativas.md)

---

## Pruebas y calidad

### Suite de producto

```bash
bash scripts/run_t31_suite.sh
```

### CI incluida

El repositorio incluye workflows para:

- `fmt + clippy + test`
- suite `T31`
- publicación de imágenes Docker por tag

---

## Seguridad y uso ético

Deception Mesh está pensado como tecnología **defensiva y observacional**.

No debe utilizarse para:

- contraataque
- pivoting hacia terceros
- payloads ofensivos
- recolección invasiva innecesaria

Su propósito es observar, registrar, priorizar y alertar.

Más detalle en [`docs/deception-mesh-notas-de-seguridad.md`](docs/deception-mesh-notas-de-seguridad.md).


## Apoya el proyecto

Si **Deception Mesh** te resultó útil, te ayudó a aprender algo nuevo o quieres apoyar su evolución, puedes invitarme un café o hacer una donación.

Tu apoyo ayuda a sostener tiempo de investigación, documentación, pruebas en laboratorio/VPS y mejoras del proyecto.

### Opciones de apoyo

#### GitHub Sponsors

Si publicas el repositorio en GitHub y activas Sponsors, puedes dejar este bloque así:

```md
## Apoya el proyecto

Si este proyecto te sirvió, puedes apoyar su desarrollo en GitHub Sponsors:

[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsors-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/tucodigocotidiano)
```

#### Buy Me a Coffee

También puedes usar una página externa:

```md
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-Support-FFDD00?logo=buymeacoffee&logoColor=000000)](https://buymeacoffee.com/topassky)
```

Reemplaza `TU_USUARIO` por tu identificador real.

#### PayPal / Nequi / enlace personal

Si prefieres algo más directo, puedes dejar una sección simple como esta:

```md
También puedes apoyar este trabajo aquí:

- PayPal: https://www.paypal.com/paypalme/topassky
- Nequi: 3004936297
- Más proyectos: https://tucodigocotidiano.yarumaltech.com/proyectos/
```

### Bloque recomendado para este README

Este es el bloque más práctico para pegar tal cual al README cuando ya tengas tus enlaces reales:

```md
## Apoya el proyecto

Si **Deception Mesh** te resultó útil, te ahorró tiempo o quieres apoyar su evolución, puedes invitarme un café o hacer una donación.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-Support-FFDD00?logo=buymeacoffee&logoColor=000000)](https://buymeacoffee.com/topassky)

También puedes apoyar este trabajo aquí:

- PayPal: https://www.paypal.com/paypalme/topassky
- Nequi: 3004936297
- Sitio web: https://tucodigocotidiano.yarumaltech.com/proyectos/
```

### Dónde ponerlo

La ubicación más recomendable es **antes de “Publicar en GitHub”** y después de la parte de seguridad/uso ético. Así no interrumpe la explicación técnica, pero sigue siendo visible para quien llegó al final del README.

---

## Publicar en GitHub

```bash
git init
git add .
git commit -m "feat: initial public version of deception mesh MVP"
```

Si quieres asociarlo a GitHub:

```bash
git remote add origin <TU_REPO_GITHUB>
git branch -M main
git push -u origin main
```

---

## Autor

**Juan Felipe Orozco**

Proyecto orientado a investigación aplicada, telemetría defensiva y diseño de producto de ciberseguridad reproducible.
