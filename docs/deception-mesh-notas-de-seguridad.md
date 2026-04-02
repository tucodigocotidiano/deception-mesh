# Deception Mesh — Notas de Seguridad

## Propósito de este documento

Este documento deja explícito el estado de seguridad del MVP actual de Deception Mesh, sus límites técnicos y sus límites éticos.

---

## Hardening actual

### Controles ya implementados

- autenticación JWT
- RBAC por tenant
- auditoría de acciones administrativas
- `sensor_token` almacenado hasheado
- tokens de enrolamiento almacenados como hash
- contraseñas con **Argon2**
- validación estricta de `EventV1`
- webhook deliveries con reintentos e historial
- honeypot SSH sin shell real
- honeypot HTTP con rutas trampa limitadas

### Riesgos todavía abiertos

- contenedores aún no endurecidos al máximo
- no hay retención automática por tenant
- no hay rotación formal de tokens
- no hay endpoint `/metrics`
- no hay mTLS real por sensor
- `host.docker.internal` es válido para demo, no como diseño final de producción
- el quickstart local usa bypass de desarrollo con `x-user-id`, lo cual no debe trasladarse a producción

---

## Secretos relevantes

- `JWT_SECRET`
- `SENSOR_TOKEN_PEPPER`
- `DATABASE_URL`
- contraseñas de usuarios
- sensor tokens
- tokens de enrolamiento

### Estado actual

- contraseñas verificadas con Argon2
- token de sensor almacenado como hash
- token de enrolamiento almacenado como hash
- configuración vía variables de entorno
- existe cuenta administrativa de laboratorio para quickstart local

### Reglas mínimas recomendadas

Antes de cualquier despliegue real:

- reemplazar todos los secretos de desarrollo
- eliminar credenciales por defecto
- no reutilizar tokens emitidos en demos
- separar secretos por ambiente

---

## Transporte y exposición de red

### Estado actual

El MVP acepta `http://` para local/dev.

Eso solo es válido para:

- localhost
- Docker local
- laboratorio
- demo controlada

### Regla

**dev/local != prod**

En producción el control plane debe ir detrás de **HTTPS** real.

### Exposición recomendada

- no exponer Postgres a internet
- exponer públicamente solo el reverse proxy del control plane
- exponer puertos de honeypots solo si esa exposición hace parte consciente del diseño del sensor
- segmentar red entre sensores, API y base de datos

---

## Datos capturados y minimización

### Qué sí se captura

**SSH**
- IP origen
- puerto origen
- username
- método de autenticación
- timestamp
- severidad
- contador de intentos

**HTTP**
- IP origen
- puerto origen
- método HTTP
- path
- user-agent
- timestamp
- severidad
- contador de intentos

**Operación**
- auditoría administrativa
- heartbeats
- historial de webhook deliveries

### Qué no se captura

- no se almacena shell interactiva
- no se almacenan comandos remotos
- no se hace keylogging
- no se hace PCAP completo
- no se buscan capturar datos innecesarios
- no se implementan payloads ofensivos

### Principio de minimización

El diseño actual busca capturar evidencia suficiente para observar, priorizar y alertar, sin convertir el sistema en un recolector excesivo de datos.

---

## Retención y privacidad

### Estado actual

En el MVP actual:

- no hay purga automática por tenant
- no hay política automática de 30/90 días
- la retención es manual

Esto debe quedar explícito para cualquier operador.

### Implicación

Mientras T19 no exista, el operador debe asumir responsabilidad manual sobre:

- limpieza de eventos
- limpieza de auditoría
- limpieza de historial de entregas webhook

---

## Límites legales y éticos

Este producto se diseña como tecnología defensiva y observacional.

Queda explícito que:

- **no hay acciones ofensivas**
- **no hay contraataque**
- **no hay payloads ofensivos**
- no hay explotación activa
- no hay pivot hacia terceros
- no hay sabotaje
- no hay emulación ofensiva de Active Directory

El objetivo es:

- observar
- registrar
- priorizar
- alertar
- integrar con webhook o SIEM

---

## Riesgos operativos conocidos del laboratorio

En laboratorio local pueden aparecer situaciones esperadas que no implican compromiso real, por ejemplo:

- cambios de host key SSH entre reconstrucciones del honeypot
- IPs de origen de Docker bridge en lugar de IPs locales directas
- múltiples eventos SSH para un solo intento manual de conexión
- uso de `host.docker.internal` para conectar el mock webhook

Nada de eso debe confundirse con un despliegue productivo final.

---

## Checklist antes de exponer a clientes

- reemplazar secretos de desarrollo
- quitar credenciales por defecto
- deshabilitar bypass de desarrollo
- montar TLS real
- no exponer Postgres
- definir política de retención
- revisar logging
- documentar límites al cliente
- endurecer contenedores
- revisar aislamiento de red
- definir estrategia de rotación de tokens

---

## Declaración final

Deception Mesh, en su estado actual, es un MVP funcional de observación defensiva con evidencia técnica reproducible. No debe presentarse todavía como plataforma completamente endurecida para producción sin cerrar primero los pendientes operativos y de seguridad.
