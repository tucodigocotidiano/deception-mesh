# Deception Mesh — Alcance del MVP (Scope)

## 1. Objetivo del MVP
Entregar una solución “plug & play” que despliegue señuelos distribuidos y genere alertas de **alta fidelidad**:
- detectar temprano actividad maliciosa,
- producir evidencia accionable para SOC/MSP,
- integrar a SIEM/SOAR vía webhook.

---

## 2. Incluye (MVP)

### 2.1 Sensor Agent
- Honeypot SSH (banner configurable, captura intentos).
- Honeypot HTTP/HTTPS (rutas trampa, login falso, captura headers básicos).
- Credenciales trampa únicas por sensor/servicio (rotación simple).
- Heartbeat hacia Control Plane (online/offline, versión, latencia de reporte).
- Reporte de eventos por HTTPS con schema versionado.

### 2.2 Control Plane
- Multi-tenant: separación de datos por organización.
- Roles: Admin / Analista / Read-only.
- Registro de sensor por token + inventario (lista por tenant).
- Ingesta y persistencia de eventos (evidencia mínima).
- Severidad por reglas simples (Low/Medium/High/Critical).
- Filtros y búsqueda (fecha, sensor, servicio, severidad, IP, texto).
- Correlación básica por IP/ventana/sensor (clusters).
- Gestión de casos / estados (Nuevo, En análisis, Confirmado, Cerrado, Falso positivo).
- Webhook por tenant para alertas + reintentos (>=3) con backoff.
- Exportación CSV de eventos.

---

## 3. Fuera de alcance (MVP)
- Explotación activa, contraataque, payloads ofensivos o acciones que dañen sistemas.
- Emulación completa de entornos (AD completo, SAP completo, etc.).
- Honeypots avanzados (RDP/SMB/DB) — post-MVP.
- SIEM integrations nativas profundas (Splunk/Elastic/Sentinel) — post-MVP (MVP: webhook).
- SOAR playbooks nativos (bloqueo firewall/aislar endpoint/ticketing automático) — post-MVP.
- mTLS por sensor con PKI y firma de binarios — recomendado post-MVP.

---

## 4. Criterios de aceptación del MVP (Definition of Done)
- Se despliega 1 sensor en Docker y se registra en el panel/API en < 10 minutos.
- Al tocar honeypot SSH/HTTP, se crea un evento visible en el panel/API en <= 10 segundos.
- El evento se envía a webhook con JSON versionado + reintentos básicos.
- Multi-tenant: dos tenants no pueden ver eventos entre sí.

---

## 5. Decisiones técnicas mínimas (MVP)
- Transporte: HTTPS (TLS). (mTLS opcional post-MVP).
- Storage: Postgres.
- Schema: JSON versionado (EventV1).
- Observabilidad: logs estructurados + métricas básicas (post-MVP ampliar).
