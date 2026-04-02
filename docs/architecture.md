# Deception Mesh — Arquitectura (MVP)

## 1. Componentes principales

### 1.1 Sensor Agent (en red del cliente)
**Responsabilidades (MVP):**
- Exponer servicios señuelo (honeypots): SSH, HTTP/HTTPS, credenciales trampa.
- Capturar evidencia mínima del “toque”:
  - IP origen, puerto, timestamp, servicio, intentos, usuario/credencial usada (si aplica),
  - headers HTTP básicos y huellas simples (si aplica).
- Enviar eventos al Control Plane mediante **HTTPS** (TLS) usando token de sensor.
- Enviar heartbeat (online/offline, versión, latencia/RTT de reporte).

**No hace (MVP):**
- No ejecuta payloads ofensivos.
- No hace contraataque ni “active defense” destructivo.
- No pivotea hacia red interna.

---

### 1.2 Control Plane (SaaS / On-Prem central)
**Responsabilidades (MVP):**
- API de registro de sensores (enrolamiento por token) y gestión multi-tenant.
- Ingesta de eventos (validación + persistencia).
- Motor de severidad por reglas simples.
- Búsqueda / filtros de eventos para triage.
- Correlación básica (clusters por IP/ventana/sensor).
- Gestión de casos (estado del evento/caso).
- Integración de salida vía **webhook** (reintentos con backoff).
- Export CSV para auditoría.

**No hace (MVP):**
- Emulación completa de entornos (AD completo, SAP completo, etc.).
- Integraciones SIEM nativas profundas (se deja como post-MVP; MVP solo webhook).

---

## 2. Diagrama de alto nivel (flujo de datos)

```mermaid
flowchart LR
  A[Atacante / scanner] -->|toca señuelo| S[Sensor Agent<br/>Honeypots + Collector]
  S -->|HTTPS Events + Heartbeat| I[Control Plane API<br/>Ingest + Auth]
  I --> D[(Postgres / Storage)]
  D --> P[Dashboard / UI]
  I --> W[Webhook (SIEM/SOAR)]
```

---

## 3. Puertos y superficies (MVP)

### Sensor Agent (entrada)
- SSH señuelo: TCP 22 o puerto configurable (ej. 2222)
- HTTP/HTTPS señuelo: TCP 80/443 o puertos configurables (ej. 8080/8443)

### Sensor Agent (salida)
- HTTPS hacia Control Plane: TCP 443 (o el puerto del API)

### Control Plane (entrada)
- API HTTPS: TCP 443 (recomendado), o 3000/8080 detrás de reverse proxy

---

## 4. Principios de seguridad del diseño (MVP)
- Aislamiento del señuelo: contenedor/VM sin acceso a red interna sensible.
- Mínimo privilegio: no-root cuando sea posible.
- Minimización de datos: no capturar payload completo por defecto.
- Multi-tenant estricto: aislamiento por tenant a nivel de DB + auth en API.

---

## 5. Riesgos y mitigaciones rápidas
- Falsos positivos: colocar señuelos “fuera de uso normal” y documentar ubicaciones recomendadas.
- Exposición accidental: default-deny en rutas/servicios; no credenciales reales; no llaves reales.
- Ruido: reglas de severidad + rate limiting básico en el sensor (post-MVP si se requiere).
