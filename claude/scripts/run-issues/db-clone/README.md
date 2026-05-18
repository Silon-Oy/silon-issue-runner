# db-clone — opt-in DB-kloonaus `/run-issues`-ajojen ajaksi

Tämä hakemisto sisältää dispatcher-skriptin (`db-clone.sh`) ja backend-toteutukset
WordPress/MySQL-, Postgres- ja docker-compose-pohjaisille tietokannoille. Orkestraattori
(`orchestrate.sh`) kutsuu dispatcheriä S5 Worktree-vaiheen jälkeen, **vain jos kohderepossa
on `.claude/db-clone.json`** — kloonaus on opt-in.

## Käyttö

1. Luo kohderepoon `.claude/db-clone.json` jollain alla olevista muodoista.
2. Aja `/run-issues` normaalisti. Onnistuneen kloonin jälkeen orkestraattori asettaa
   `RUN_ISSUES_DB_CLONE=<cloned-db-name>` -ympäristömuuttujan implementer-promptiin.

Klooni nimetään muodossa `<prefix><run-id-sanitized>`, leikataan 32 merkkiin.

## `.claude/db-clone.json`-esimerkit

### `wordpress-mysql`

```json
{
  "type": "wordpress-mysql",
  "source_db": "wp_silon",
  "wp_path": ".",
  "mysql_user": "root",
  "mysql_host": "127.0.0.1",
  "clone": {
    "name_prefix": "wp_clone_",
    "exclude_tables": ["wp_options", "wp_users"],
    "update_urls": true,
    "url_pair": {
      "from": "https://prod.example.com",
      "to":   "https://clone.example.test"
    }
  }
}
```

- `wp_path` on `wp-cli`:n juuri repon sisällä (yleensä `.`).
- `exclude_tables` välitetään `wp db export`:lle.
- `update_urls=true` ajaa `wp search-replace`:n kloonatussa kannassa.

### `postgres`

```json
{
  "type": "postgres",
  "source_conn": "postgres://user:pass@localhost:5432/proddb",
  "target_conn_template": "postgres://user:pass@localhost:5432/{db}",
  "clone": {
    "name_prefix": "pg_clone_"
  }
}
```

- `{db}`-placeholder korvataan kloonin DB-nimellä.
- `target_conn_template`:lla yhdistetään myös `postgres`-järjestelmäkantaan (DROP/CREATE).

### `docker-compose`

```json
{
  "type": "docker-compose",
  "compose_file": "docker-compose.yml",
  "original_project": "silon",
  "db_service": "db",
  "db_engine": "mysql",
  "db_user_env": "MYSQL_USER",
  "db_pass_env": "MYSQL_PASSWORD",
  "source_db_env": "MYSQL_DATABASE",
  "clone": {
    "name_prefix": "clone_"
  }
}
```

- Credentialit luetaan kontin omasta ympäristöstä (env-muuttujan nimillä) — eivät päädy
  host-shelliin.
- `db_engine`: `mysql` tai `postgres`. Postgresilla käytetään `CREATE DATABASE ... TEMPLATE
  <source>` -menetelmää (nopea, mutta vaatii että source-kanta ei ole aktiivisesti käytössä
  hetkellä kun klooni luodaan).
- Compose-pohjaista *koko projektin* kloonia (uusi `<project>-clone-<slug>`) ei tueta tässä
  vaiheessa — sama palvelu hoitaa vain DB-tason kloonin.

## Exit-koodit (`db-clone.sh`)

| Koodi | Merkitys                                                  |
|-------|-----------------------------------------------------------|
| 0     | Klooni onnistui (stdout: `RUN_ISSUES_DB_CLONE=<name>`)    |
| 1     | `.claude/db-clone.json` puuttuu — kloonia ei tehdä        |
| 2     | Konfiguraatio rikki tai pakolliset kentät puuttuvat       |
| 3     | Tuntematon backend (`.type`)                              |
| 4     | Backend palautti virheen                                  |

Orkestraattori tulkitsee 0:n ja 1:n onnistumiseksi (1 = ei tarvinnut kloonata);
muu koodi blokkaa ajon.
