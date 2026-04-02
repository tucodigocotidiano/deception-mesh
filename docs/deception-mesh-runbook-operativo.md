# Deception Mesh — Runbook Operativo

## Alcance de este runbook

Este documento describe cómo operar el MVP actual de Deception Mesh en entorno local o de laboratorio controlado.

Su objetivo es dejar claro:

- cómo arrancar el stack
- qué puertos expone
- cómo verificar salud y funcionamiento
- qué datos captura el sistema
- qué datos no captura
- cuál es el estado actual de retención
- qué limitaciones operativas existen hoy

Este runbook aplica al estado actual del MVP compuesto por:

- `control_plane`
- `postgres`
- `sensor_agent`
- honeypots SSH y HTTP
- webhook delivery worker
- exportación CSV
- scripts de quickstart, demo y suites e2e

---

## Arquitectura operativa

### Componentes

**Control Plane**
- API HTTP principal
- autenticación JWT para usuarios
- autorización multi-tenant con RBAC
- ingestión de eventos desde sensores
- consultas, filtros, export CSV y webhook deliveries
- auditoría de acciones administrativas

**Postgres**
- persistencia de tenants, usuarios, memberships, sensores, eventos, auditoría y webhooks

**Sensor Agent**
- heartbeat periódico
- honeypot SSH señuelo
- honeypot HTTP señuelo
- publicación de eventos al control plane

### Flujo operativo

1. El sensor arranca con `sensor_id`, `tenant_id` y `sensor_token`.
2. El sensor reporta heartbeat al control plane.
3. Un toque a SSH o HTTP genera un `EventV1`.
4. El sensor envía el evento a `POST /events/ingest`.
5. El control plane valida, calcula severidad y persiste en DB.
6. El evento queda visible por API.
7. Si el tenant tiene webhook configurado y la severidad cumple el umbral, se encola una entrega.
8. El worker procesa la entrega y registra el historial de intentos.

---

## Puertos y superficies expuestas

### Puertos principales del stack

- `8080/TCP` — Control Plane API
- `5432/TCP` — Postgres
- `2222/TCP` — honeypot SSH del sensor
- `8081/TCP` — honeypot HTTP del sensor
- `8443/TCP` — honeypot HTTPS opcional del sensor

### Qué puertos deberían exponerse según entorno

**Local / demo**
- `8080`
- `2222`
- `8081`
- `8443` solo si se usa honeypot HTTPS
- `5432` idealmente no exponerlo fuera del host si no es necesario

**Producción**
- exponer públicamente solo el reverse proxy delante del control plane
- no exponer Postgres a internet
- exponer puertos de honeypots solo si forman parte explícita del despliegue del sensor
- segmentar red entre sensores, API y DB

---

## Arranque local reproducible

### Stack base

```bash
docker compose up -d --build postgres control_plane
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/ready
```

### Quickstart MVP local

```bash
bash scripts/t29_install_mvp_local.sh
bash scripts/e2e_t29_quickstart.sh
```

### Demo extremo a extremo

```bash
bash scripts/demo.sh
```

### Suite de producto

```bash
bash scripts/run_t31_suite.sh
```

---

## Verificaciones operativas

### Salud del control plane

```bash
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/ready
```

### Login administrativo

```bash
curl -sS -X POST http://127.0.0.1:8080/auth/login   -H "Content-Type: application/json"   -d '{"email":"admin@acme.com","password":"admin"}'
```

### Ver tenants visibles

Con JWT:

```bash
TOKEN="$(curl -sS -X POST http://127.0.0.1:8080/auth/login   -H "Content-Type: application/json"   -d '{"email":"admin@acme.com","password":"admin"}' | jq -r '.access_token')"

curl -sS http://127.0.0.1:8080/v1/tenants   -H "Authorization: Bearer $TOKEN" | jq .
```

En local, solo para quickstart reproducible, también existe bypass de desarrollo:

```bash
DEV_USER_ID="11111111-1111-1111-1111-111111111111"

curl -sS http://127.0.0.1:8080/v1/tenants   -H "x-user-id: $DEV_USER_ID" | jq .
```

**Importante:** `x-user-id` es solo para laboratorio local.

### Ver sensores de un tenant

Con JWT:

```bash
curl -sS "http://127.0.0.1:8080/v1/tenants/<TENANT_ID>/sensors"   -H "Authorization: Bearer <TOKEN>" | jq .
```

Con bypass local de quickstart:

```bash
curl -sS "http://127.0.0.1:8080/v1/tenants/<TENANT_ID>/sensors"   -H "x-user-id: 11111111-1111-1111-1111-111111111111" | jq .
```

### Consultar eventos

Ruta general:

```bash
curl -sS "http://127.0.0.1:8080/events?tenant_id=<TENANT_ID>&limit=50"   -H "Authorization: Bearer <TOKEN>" | jq .
```

Ruta scoped:

```bash
curl -sS "http://127.0.0.1:8080/v1/tenants/<TENANT_ID>/events?limit=50"   -H "Authorization: Bearer <TOKEN>" | jq .
```

Filtros útiles:

```bash
curl -sS "http://127.0.0.1:8080/v1/tenants/<TENANT_ID>/events?service=http&limit=50"   -H "Authorization: Bearer <TOKEN>" | jq .

curl -sS "http://127.0.0.1:8080/v1/tenants/<TENANT_ID>/events?service=ssh&limit=50"   -H "Authorization: Bearer <TOKEN>" | jq .
```

### Exportar CSV

```bash
curl -sS "http://127.0.0.1:8080/events/export.csv?tenant_id=<TENANT_ID>"   -H "Authorization: Bearer <TOKEN>"   -o events.csv

cat events.csv
```

### Consultar entregas webhook

```bash
curl -sS "http://127.0.0.1:8080/v1/tenants/<TENANT_ID>/webhook-deliveries"   -H "Authorization: Bearer <TOKEN>" | jq .
```

---

## Evidencia funcional ya validada en laboratorio

En el estado actual del MVP ya quedó validado que:

- el sensor se registra correctamente
- el heartbeat mantiene el sensor en estado `active`
- el honeypot HTTP responde en rutas trampa (`/login`, `/admin`, `/wp-login.php`)
- el honeypot SSH rechaza acceso real pero captura intentos de autenticación
- los eventos quedan persistidos en la API
- la severidad sube por repetición
- la exportación CSV funciona
- los webhooks quedan registrados con historial de entrega
- la demo extremo a extremo es reproducible

### Nota específica sobre SSH en laboratorio

Es normal que una conexión SSH manual produzca varios eventos del mismo intento, por ejemplo:

- `ssh_auth_method = "none"`
- `ssh_auth_method = "publickey_offered"`
- `ssh_auth_method = "password"`

Eso es útil porque permite observar mejor la secuencia del cliente y elevar severidad cuando hay repetición.

### Nota sobre direcciones IP observadas

Cuando el sensor corre dentro de Docker, la IP observada puede verse como una IP de red bridge, por ejemplo `172.21.0.1`, en lugar de `127.0.0.1`. Eso es esperado en entorno local con contenedores.

---

## Retención de datos

### Estado actual del MVP

**Estado actual del MVP: no hay purga automática por tenant implementada.**

Mientras T19 no esté cerrada, la retención efectiva es manual.

### Implicación operativa

- el sistema guarda eventos
- el sistema guarda auditoría
- el sistema guarda webhook deliveries
- la limpieza depende del operador

---

## Qué se captura

### SSH honeypot

- `tenant_id`
- `sensor_id`
- `event_id`
- `schema_version`
- `src_ip`
- `src_port`
- `timestamp_rfc3339`
- `username`
- `ssh_auth_method`
- `severity`
- `severity_reason`
- `attempt_count`

### HTTP honeypot

- `tenant_id`
- `sensor_id`
- `event_id`
- `schema_version`
- `src_ip`
- `src_port`
- `timestamp_rfc3339`
- `http_method`
- `http_path`
- `http_user_agent`
- `severity`
- `severity_reason`
- `attempt_count`

### Operación adicional

- heartbeats del sensor
- auditoría administrativa
- historial de webhook deliveries
- export CSV de eventos

---

## Qué no se captura

El MVP actual **no** captura por defecto:

- shell interactiva real
- comandos ejecutados en shell remota
- keylogging
- payloads ofensivos
- contraataque
- movimiento lateral
- tráfico completo tipo PCAP
- emulación completa de Active Directory

---

## Hardening operativo actual

### Ya implementado

- JWT
- RBAC por tenant
- auditoría administrativa
- hash de `sensor_token`
- hash de tokens de enrolamiento
- Argon2 para contraseñas
- validación estricta de `EventV1`
- reintentos de webhook con historial
- SSH fake sin shell real

### Pendiente

- usuario no-root en contenedores
- retención automática por tenant
- rotación formal de tokens
- endpoint `/metrics`
- mTLS por sensor
- aislamiento de red más fino
- endurecimiento adicional de despliegue productivo

---

## Respuesta operativa ante actividad

Si un honeypot recibe actividad:

1. verificar evento en API
2. revisar severidad
3. revisar entrega webhook
4. exportar CSV si hace falta
5. documentar hallazgo
6. **no ejecutar represalias**

---

## Límites del estado actual

Este MVP demuestra:

- sensor
- heartbeat
- honeypot SSH/HTTP
- `EventV1`
- ingestión
- persistencia
- consulta
- webhook
- export CSV
- suites reproducibles

Pero todavía no debe venderse como plataforma endurecida completa para producción sin ajustes adicionales.
