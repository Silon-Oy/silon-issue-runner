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
  "source_db": "wp_example",
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
- `exclude_tables` välitetään `wp db export`:lle (`--exclude_tables`), tai `update_urls=true`-tilassa `wp search-replace`:lle (`--skip-tables`). Useampi taulu kelpaa.
- `update_urls=true` kirjoittaa URL:t uudelleen **export-vaiheessa**: `wp search-replace --export` lukee lähde-DB:tä read-onlyna ja kirjoittaa valmiiksi uudelleenkirjoitetun dumpin, joka tuodaan klooniin. Lähde-DB:hen ei kosketa, ja serialized-arvot säilyvät wp-cli:n hoitamana. (wp-cli:ssä ei ole lippua osoittaa komentoa toiseen kantaan, joten uudelleenkirjoitus tehdään exportissa.)

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
  "original_project": "example",
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
- Compose-pohjaista *koko projektin* kloonia (uusi `<project>-clone-<slug>`: omat kontit,
  volyymit, verkot, portit) **ei tueta** — ja se on tietoinen päätös, ei keskeneräisyys.
  DB-tason klooni jakaa saman jo käynnissä olevan `db`-palvelun eikä avaa uusia portteja,
  joten rinnakkaiset worktreet eivät törmää porttikonflikteihin. Koko projektin kloonin
  arviointi, käynnistysehto ja formalisoitu tuleva polku:
  [`docs/design/docker-compose-full-project-clone.md`](../../../../docs/design/docker-compose-full-project-clone.md)
  (issue [#11](https://github.com/Silon-Oy/dotfiles/issues/11)).

## Turvallisuus

`.claude/db-clone.json` on **luotettu tiedosto.** Backendit (erityisesti
`docker-compose.sh`) rakentavat osasta configin arvoja shell-stringin, joka
ajetaan `docker compose exec`-kutsulla. Käytännössä configia muokkaamaan pääsevä
voi siis ajaa mielivaltaista shelliä kontti- tai host-prosessina.

Tästä syystä:

- **Älä committaa `.claude/db-clone.json`-tiedostoa julkiseen repoon** äläkä jaa
  sitä tahoille, joihin et luota. Pidä se `.gitignore`:ssä tai vain paikallisena.
- **Kohtele tiedostoa kuin credentiaalia** — sen kirjoitusoikeudet kuuluvat vain
  configin omistajalle (käytännössä ylläpitäjä kirjoittaa configit itse).
- Riskitaso tässä ympäristössä on matala (yksityiset repot), mutta luotettu-status
  on silti syytä tiedostaa, jos workflow joskus laajenee jaettuihin repoihin.

Puolustuksena `db-clone.sh`-dispatcher hylkää (exit 2) configin, jonka jossain
string-arvossa esiintyy shell-metamerkki `$`, backtick, `;` tai `|`. Validointi
on tarkoituksella kapea: legitiimit arvot — myös Postgres-conn-stringit muotoa
`postgres://user:pass@host:5432/db` — eivät sisällä näitä merkkejä, joten oikeat
configit eivät kaadu. Validointi **ei korvaa** tiedoston luotettu-statuksen
ylläpitoa, vaan on lisäkerros sen päälle.

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
