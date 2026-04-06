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

## Validación ya lograda

Durante las pruebas del proyecto se verificó que:

- el `control_plane` y `postgres` arrancan correctamente en Docker
- un admin puede autenticarse por JWT en producción local/VPS
- el sensor se registra y queda visible dentro del tenant correcto
- el `sensor_agent` mantiene heartbeat y pasa a `active`
- los honeypots HTTP/SSH generan eventos persistidos en Postgres
- la severidad sube por repetición en rutas trampa
- el sistema exporta eventos a CSV
- el pipeline de webhook funciona con reintentos
- en una VPS se observaron toques externos reales sobre `/login`

En otras palabras: **no es una maqueta vacía**. El MVP ya produce telemetría útil del mundo real.

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
│   ├── sensor/
│   ├── sql/
│   └── runtime/
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
- Rust estable (para desarrollo local sin Docker)

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

### 6) Exponer solo lo necesario

En una VPS, la postura mínima recomendable es:

- **sí exponer** los puertos trampa del sensor si quieres capturar bots reales
- **no exponer** Postgres a Internet
- **no exponer** el control plane directamente si puedes ponerlo detrás de reverse proxy/TLS
- usar `DEV_ALLOW_X_USER_ID=0` en producción

---

## Consultas operativas útiles

Las consultas que nacieron de la validación real quedaron organizadas en:

- [`docs/consultas-operativas.md`](docs/consultas-operativas.md)

Ese documento sirve para responder cosas como:

- qué IPs tocaron el sensor
- qué rutas fueron golpeadas
- qué intentos son internos vs externos
- cuál fue la última vez que una IP apareció
- qué evidencia SSH y HTTP quedó registrada

---

## Pruebas y calidad

### Suite de producto

```bash
bash scripts/run_t31_suite.sh
```

### CI incluida

El repositorio ya contiene workflows para:

- `fmt + clippy + test`
- suite `T31`
- publicación de imágenes Docker por tag

Revisa `.github/workflows/`.

---

## Decisiones de diseño: complejidad computacional y complejidad de Kolmogorov

Este repositorio se reorganizó para dejar una narrativa más compacta y una base más mantenible.

### 1. Optimización de complejidad computacional

La arquitectura favorece operaciones lineales o casi lineales sobre el flujo principal:

- el sensor captura un evento y lo reporta sin procesamiento pesado local
- el control plane aplica reglas simples de severidad en vez de pipelines costosos de ML
- el almacenamiento relacional permite filtros, agregaciones y exportación con costo razonable para un MVP
- el worker de webhook desacopla ingestión de entrega, evitando bloquear la ruta crítica

### 2. Optimización de complejidad de Kolmogorov

Se redujo la longitud descriptiva necesaria para entender el proyecto:

- un único `README.md` como punto de entrada
- documentación especializada pero no dispersa
- separación clara entre quickstart, runbook, arquitectura y consultas
- eliminación de archivos ad hoc y ruido local del paquete final
- normalización de nombres y rutas para que el proyecto “se explique solo”

### 3. Unificación de ideas redundantes

Se concentró cada tema donde aporta más valor:

- **README** → visión global, instalación y mapa del proyecto
- **quickstart** → receta mínima reproducible
- **runbook** → operación del MVP
- **notas de seguridad** → límites, riesgos y postura ética
- **consultas operativas** → inspección real de evidencia

El objetivo fue que cada documento tenga una función única y que no compita con los demás.

---

## Limitaciones actuales

Este repositorio **no pretende vender humo**. El estado real del MVP es:

- sí captura evidencia útil
- sí permite triage básico
- sí soporta multi-tenant, severidad y webhooks
- **no** es todavía un SIEM completo
- **no** implementa retención automática madura por tenant
- **no** incluye bloqueo activo ni respuesta ofensiva
- **no** debe desplegarse como producto enterprise endurecido sin cerrar primero los pendientes operativos

---

## Seguridad y uso ético

Deception Mesh está pensado como tecnología **defensiva y observacional**.

No debe utilizarse para:

- contraataque
- pivoting hacia terceros
- payloads ofensivos
- recolección invasiva innecesaria

Su propósito es:

- observar
- registrar
- priorizar
- alertar
- integrar con otras herramientas defensivas

Más detalle en [`docs/deception-mesh-notas-de-seguridad.md`](docs/deception-mesh-notas-de-seguridad.md).

---

## Documentación disponible

- [`docs/architecture.md`](docs/architecture.md)
- [`docs/mvp_scope.md`](docs/mvp_scope.md)
- [`docs/quickstart.md`](docs/quickstart.md)
- [`docs/deception-mesh-runbook-operativo.md`](docs/deception-mesh-runbook-operativo.md)
- [`docs/deception-mesh-notas-de-seguridad.md`](docs/deception-mesh-notas-de-seguridad.md)
- [`docs/consultas-operativas.md`](docs/consultas-operativas.md)

---

## Publicar en GitHub

Antes de subir el repositorio:

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
