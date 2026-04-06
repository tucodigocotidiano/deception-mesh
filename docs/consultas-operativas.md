# Deception Mesh — Consultas operativas útiles

Este documento consolida las consultas prácticas que surgieron durante la validación del MVP en laboratorio y VPS. La idea es convertir notas sueltas en una referencia operativa reutilizable.

> Todas las consultas asumen un contenedor `deceptionmesh-postgres-1`, base `deception_mesh` y usuario `deception`.

---

## 1. Ver los últimos eventos capturados

```bash
docker exec -it deceptionmesh-postgres-1 psql -U deception -d deception_mesh -c "
SELECT
  occurred_at,
  service,
  src_ip,
  src_port,
  severity,
  attempt_count,
  raw_event->'evidence'->>'http_path' AS http_path,
  raw_event->'evidence'->>'http_user_agent' AS http_user_agent,
  raw_event->'evidence'->>'username' AS ssh_username,
  raw_event->'evidence'->>'ssh_auth_method' AS ssh_auth_method
FROM events
ORDER BY occurred_at DESC
LIMIT 30;
"
```

Útil para una revisión rápida del estado del sensor.

---

## 2. Aislar solo actividad externa

```bash
docker exec -it deceptionmesh-postgres-1 psql -U deception -d deception_mesh -c "
SELECT
  occurred_at,
  service,
  src_ip,
  severity,
  attempt_count,
  raw_event->'evidence'->>'http_path' AS http_path,
  raw_event->'evidence'->>'username' AS ssh_username
FROM events
WHERE src_ip NOT LIKE '172.%'
  AND src_ip NOT LIKE '10.%'
  AND src_ip NOT LIKE '192.168.%'
  AND src_ip <> '127.0.0.1'
ORDER BY occurred_at DESC
LIMIT 50;
"
```

Sirve para separar tráfico de pruebas internas del tráfico real que llega desde Internet.

---

## 3. Top IPs por cantidad de toques

```bash
docker exec -it deceptionmesh-postgres-1 psql -U deception -d deception_mesh -c "
SELECT
  src_ip,
  service,
  COUNT(*) AS total_hits,
  MAX(occurred_at) AS last_seen
FROM events
GROUP BY src_ip, service
ORDER BY total_hits DESC, last_seen DESC
LIMIT 20;
"
```

Esta consulta ayuda a identificar repetición, persistencia y focos de ruido.

---

## 4. Revisar evidencia HTTP reciente

```bash
docker exec -it deceptionmesh-postgres-1 psql -U deception -d deception_mesh -c "
SELECT
  occurred_at,
  src_ip,
  severity,
  raw_event->'evidence'->>'http_method' AS method,
  raw_event->'evidence'->>'http_path' AS path,
  raw_event->'evidence'->>'http_user_agent' AS ua
FROM events
WHERE service = 'http'
ORDER BY occurred_at DESC
LIMIT 30;
"
```

Especialmente útil para observar toques a rutas trampa como `/login`, `/admin` y `/wp-login.php`.

---

## 5. Revisar evidencia SSH reciente

```bash
docker exec -it deceptionmesh-postgres-1 psql -U deception -d deception_mesh -c "
SELECT
  occurred_at,
  src_ip,
  severity,
  raw_event->'evidence'->>'username' AS username,
  raw_event->'evidence'->>'ssh_auth_method' AS auth_method
FROM events
WHERE service = 'ssh'
ORDER BY occurred_at DESC
LIMIT 30;
"
```

Permite revisar usuarios probados y método de autenticación observado.

---

## 6. Ver todo el histórico más reciente en una sola vista

```bash
docker exec -it deceptionmesh-postgres-1 psql -U deception -d deception_mesh -c "
SELECT
  occurred_at,
  service,
  src_ip,
  severity,
  attempt_count,
  raw_event->'evidence'->>'http_path' AS http_path,
  raw_event->'evidence'->>'username' AS ssh_username
FROM events
ORDER BY occurred_at DESC
LIMIT 100;
"
```

---

## 7. Seguir logs del sensor en vivo

```bash
docker logs -f deceptionmesh-sensor_agent-1
```

Útil para ver heartbeats, fallos de reporte y actividad mientras pruebas exposición real.

---

## 8. Inspeccionar entregas webhook capturadas por el mock receiver

Si estás usando el receptor de pruebas:

```bash
nano /tmp/deceptionmesh_webhooks.jsonl
```

También puedes consultar el estado HTTP del receptor:

```bash
curl -fsS http://127.0.0.1:18080/health
```

---

## 9. Qué interpretación dar a resultados típicos

### Caso A: IP privada tipo `172.x.x.x`

Normalmente indica tráfico interno de Docker o pruebas locales.

### Caso B: tu IP pública propia

Indica que tú mismo tocaste el sensor desde fuera mediante `curl`, `nc` o SSH para validación.

### Caso C: una IP pública desconocida

Ese es el caso interesante: suele ser un toque real de bot, scanner o reconocimiento externo.

---

## 10. Recomendación operativa

La secuencia mínima de observación cuando expones el sensor a Internet debería ser:

1. revisar `docker ps`
2. confirmar que el sensor responde en `2222` y `8081`
3. consultar eventos recientes
4. separar IPs externas de internas
5. revisar top IPs por número de toques
6. inspeccionar webhook deliveries si tienes alerta configurada

Con eso ya puedes responder la pregunta central del MVP:

**“¿alguien real tocó el sensor y qué evidencia dejó?”**
