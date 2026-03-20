# Prompt: getLogs Edge Function entwerfen

Nutze diesen Prompt mit einem KI-Assistenten um eine `getLogs` Edge Function fuer dein Supabase Self-Hosted Setup zu erstellen.

---

## Prompt

```
Ich betreibe Supabase Self-Hosted mit Logflare + Vector fuer Logging.
Die Infrastruktur wird ueber dieses Repo verwaltet: https://github.com/<user>/supabase-hetzner

Erstelle eine Supabase Edge Function `getLogs` die als einfache REST-API
Logs aus Logflare abruft.

### Kontext

- Logflare laeuft als Container `supabase-analytics` im Docker-Netzwerk
- Logflare ist intern unter `http://analytics:4000` erreichbar
- Die Query-API ist `GET /api/query?pg_sql=<SQL>`
- Auth: Header `x-api-key` mit dem Wert der Env-Variable `LOGFLARE_PRIVATE_ACCESS_TOKEN`
- Logs liegen in der Datenbank `_supabase`, Schema `_analytics`
- Jede Log-Source hat eine eigene Tabelle: `_analytics.log_events_<token_mit_underscores>`
- Jede Zeile hat: `id` (UUID), `timestamp`, `body` (JSONB)
- `body` enthaelt: `event_message` (String), `metadata` (Object), `appname` (String)

Die verfuegbaren Sources und ihre Tokens koennen ueber
`GET /api/sources` (mit x-api-key Header) abgefragt werden.
Jede Source hat `name` und `token` Felder.

### Anforderungen

1. **Einfache Query-Parameter statt SQL:**
   - `service` — Filtert nach Source-Name (z.B. `functions`, `auth`, `kong`, `storage`, `rest`, `db`, `realtime`)
   - `limit` — Anzahl Ergebnisse (default: 50, max: 500)
   - `since` — ISO-Timestamp, nur Logs nach diesem Zeitpunkt
   - `search` — Freitext-Suche in `event_message`
   - `level` — Filtert nach Log-Level in `metadata` (falls vorhanden)

2. **Service-Name Mapping:**
   Die Function soll beim Start die verfuegbaren Sources von Logflare abrufen
   und ein Mapping von benutzerfreundlichen Namen zu Source-Tokens aufbauen.
   Z.B. `functions` → `deno-relay-logs`, `auth` → `gotrue.logs.prod`, etc.
   Ohne `service`-Parameter alle Sources abfragen oder eine Liste der
   verfuegbaren Services zurueckgeben.

3. **Auth:**
   - Die Edge Function soll nur mit `service_role` Key aufrufbar sein
   - LOGFLARE_PRIVATE_ACCESS_TOKEN aus Deno.env.get() lesen

4. **Response-Format:**
   ```json
   {
     "logs": [
       {
         "timestamp": "2026-03-05T14:30:00.123Z",
         "message": "...",
         "metadata": { ... },
         "service": "functions"
       }
     ],
     "count": 42,
     "service": "functions",
     "sources_available": ["functions", "auth", "kong", ...]
   }
   ```

5. **Fehlerbehandlung:**
   - Unbekannter Service → 400 mit Liste verfuegbarer Services
   - Logflare nicht erreichbar → 502
   - Kein service_role Key → 401

6. **SQL Injection verhindern:**
   Alle Query-Parameter muessen sanitized werden bevor sie in die SQL-Query
   eingebaut werden. Nutze einfache Whitelist-Validierung fuer `service`,
   numerische Validierung fuer `limit`, ISO-Timestamp-Validierung fuer `since`,
   und escape Sonderzeichen in `search`.

### Beispiel-Aufrufe

# Alle verfuegbaren Services
GET /functions/v1/getLogs

# Letzte 20 Edge Function Logs
GET /functions/v1/getLogs?service=functions&limit=20

# Auth-Fehler der letzten Stunde
GET /functions/v1/getLogs?service=auth&since=2026-03-05T15:00:00Z&search=error

# Suche in allen Kong-Logs
GET /functions/v1/getLogs?service=kong&search=POST&limit=100

### Technische Details

- Edge Functions laufen in Deno
- HTTP-Requests an Logflare gehen ueber das Docker-Netzwerk (kein externer Aufruf)
- Die Function wird im Supabase-Hetzner-Stack unter `supabase/functions/getLogs/index.ts` abgelegt
- Nutze `Deno.env.get("LOGFLARE_PRIVATE_ACCESS_TOKEN")` fuer den API-Key
- Die Logflare-URL ist `http://analytics:4000`
```

---

## Hinweise

- Der Prompt ist bewusst ohne hardcoded Credentials, Tabellennamen oder Tokens
- Die Function ermittelt Sources dynamisch ueber die Logflare API
- Funktioniert mit jedem Setup das dieses Repo nutzt, unabhaengig von generierten Keys
- Nach dem Erstellen der Function muss sie ueber den Deploy-Workflow deployt werden
