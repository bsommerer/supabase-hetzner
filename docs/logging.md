# Logging (Logflare + Vector)

## Architektur

```
Docker Container Logs → Vector → Logflare → _supabase DB (_analytics Schema)
```

| Container | Image | Funktion |
|---|---|---|
| `supabase-analytics` | `supabase/logflare` | Analytics Server, Query-API |
| `supabase-vector` | `timberio/vector` | Sammelt Docker-Logs, sendet an Logflare |

## Log-Sources

| Service | Source Name | Query-Tabelle |
|---|---|---|
| Kong (API Gateway) | `cloudflare.logs.prod` | `edge_logs` |
| Edge Functions | `deno-relay-logs` | `function_logs` |
| Auth (GoTrue) | `gotrue.logs.prod` | `auth_logs` |
| Realtime | `realtime.logs.prod` | `realtime_logs` |
| Storage | `storage.logs.prod.2` | `storage_logs` |
| PostgREST | `postgREST.logs.prod` | `rest_logs` |
| PostgreSQL | `postgres.logs` | `postgres_logs` |

## Authentifizierung

Logflare nutzt zwei Token-Typen (automatisch aus Env-Variablen erstellt):

| Env-Variable | Scope | Verwendung |
|---|---|---|
| `LOGFLARE_PUBLIC_ACCESS_TOKEN` | `public` | Ingestion (Vector → Logflare) |
| `LOGFLARE_PRIVATE_ACCESS_TOKEN` | `private` | Query + Management API |

**Wichtig:** Beide Tokens muessen unterschiedliche Werte haben, sonst wird nur der `public` Token angelegt.

## Logs abfragen

### Intern (vom Server / Docker-Netzwerk)

```bash
ANALYTICS_IP=$(docker inspect supabase-analytics --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
PRIVATE_KEY=$(grep '^LOGFLARE_PRIVATE_ACCESS_TOKEN=' /opt/supabase/.env | cut -d= -f2)

# Sources auflisten
curl -s -H "x-api-key: $PRIVATE_KEY" "http://${ANALYTICS_IP}:4000/api/sources"

# Logs abfragen (Direct Query API)
curl -s -H "x-api-key: $PRIVATE_KEY" \
  "http://${ANALYTICS_IP}:4000/api/query?pg_sql=SELECT timestamp, body->>'event_message' as message FROM _analytics.log_events_<SOURCE_TOKEN_MIT_UNDERSCORES> ORDER BY timestamp DESC LIMIT 10"
```

### Extern (ueber Kong/HTTPS)

Voraussetzung: Kong Analytics-Route ist aktiviert (siehe Cloud-Init Patch in `user-data.yaml.tpl`).

```bash
curl -H "apikey: <SERVICE_ROLE_KEY>" \
     -H "x-api-key: <LOGFLARE_PRIVATE_ACCESS_TOKEN>" \
     "https://<DOMAIN>/analytics/v1/api/sources"

curl -H "apikey: <SERVICE_ROLE_KEY>" \
     -H "x-api-key: <LOGFLARE_PRIVATE_ACCESS_TOKEN>" \
     "https://<DOMAIN>/analytics/v1/api/query?pg_sql=<SQL>"
```

### Direkt per SQL (auf dem Server)

```bash
docker exec supabase-db psql -U supabase_admin -d _supabase -c "
  SELECT timestamp, body->>'event_message' as message
  FROM _analytics.log_events_<SOURCE_TOKEN_MIT_UNDERSCORES>
  ORDER BY timestamp DESC LIMIT 10;"
```

## Datenbank

- Datenbank: `_supabase` (nicht `postgres`)
- Schema: `_analytics`
- Log-Tabellen: `_analytics.log_events_<source_token_mit_underscores>`
- Spalten: `id` (UUID), `timestamp`, `body` (JSONB)

## Edge Function Logging

```typescript
console.log("Info")
console.warn("Warnung")
console.error("Fehler")
```

Limits: 10.000 Zeichen/Nachricht, 100 Events/10s.

## Studio Dashboard

Logs-Tab funktioniert ueber den vordefinierten Endpoint `logs.all`. Studio verbindet sich direkt ueber Docker-Netzwerk mit Logflare.

## Offene Punkte

- **getLogs Edge Function:** Einfache REST-API als Wrapper um die Logflare Query-API (kein SQL noetig, ein Auth-Header statt zwei)
- **Log Retention:** `retention_days: 7` pro Source, keine automatische Bereinigung
- **Separater Postgres:** Bei hohem Log-Volumen eigene DB fuer Analytics evaluieren
