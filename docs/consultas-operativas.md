# Consultas operativas útiles

Estas consultas sirven para inspeccionar rápidamente la telemetría capturada por Deception Mesh durante pruebas de laboratorio o despliegues reales.

## Ver últimos eventos

```sql
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
```

## Ver solo actividad externa

```sql
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
```

## Resumen por IP y servicio

```sql
SELECT
  src_ip,
  service,
  COUNT(*) AS total_hits,
  MAX(occurred_at) AS last_seen
FROM events
GROUP BY src_ip, service
ORDER BY total_hits DESC, last_seen DESC
LIMIT 20;
```

## Últimos eventos HTTP

```sql
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
```

## Últimos eventos SSH

```sql
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
```

## Consejo operativo

En despliegues reales conviene combinar estas consultas con webhooks, exportación CSV y filtros por tenant para separar laboratorio, staging y producción.
