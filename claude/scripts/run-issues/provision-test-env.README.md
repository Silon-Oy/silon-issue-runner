# provision-test-env — opt-in per-ajo testiympäristön provisiointi

Geneerinen, kohderepon omistama **provisiointihook**, jonka `/run-issues`-orkestraattori
ajaa toteutusvaiheen (S8 Implementer) edellä, vaiheessa **S7c**. Hook provisioi ajon ajaksi
mitä tahansa ulkoisia resursseja, joita kohderepon testit tarvitsevat — migratoitu
testitietokanta, Redis, objektivarasto-stub — ja injektoi niiden osoitteet implementerin
ympäristöön env-muuttujina.

Hook on **opt-in**: orkestraattori etsii worktreestä suoritettavan tiedoston
`<worktree>/.claude/provision-test-env.sh`. Jos sitä ei ole tai se ei ole suoritettava →
**no-op**, ajo etenee normaalisti (vastaava hyvänlaatuinen skip kuin `db-clone-skipped` /
`env-bootstrap-skipped`).

> **Suhde db-cloneen:** tämä on **erillinen, rinnakkainen** koneisto, ei korvaaja.
> `db-clone` *kopioi olemassa olevan datan*; provision-test-env *provisioi tyhjän,
> migratoidun skeeman + injektoi conn-stringin*. Eri tarkoitukset → eri koneisto. db-clone
> jää koskemattomaksi omaan tehtäväänsä.

## Sopimus

Orkestraattori kutsuu hookia kahdessa moodissa:

```bash
provision-test-env.sh provision <run-id>     # S7c: provisioi resurssit
provision-test-env.sh cleanup   <run-id>     # teardown (cleanup-run.sh / auto-clean.sh)
```

| Asia | Sopimus |
|---|---|
| **Työhakemisto** | worktreen juuri (CWD). Näin esim. `pnpm prisma` löytää schema-polun ja S7b:n asentaman `node_modules`-hakemiston. |
| **`<run-id>`** | **Pakollinen eristysavain.** Hook johtaa resurssien nimet siitä (esim. `test_<run-id>`), jotta kaksi rinnakkaista ajoa ei törmää. Älä provisioi jaettua resurssia. |
| **stdout** | `KEY=VALUE`-rivit. Orkestraattori kerää ne ja injektoi implementerin ympäristöön. Useampi rivi tuetaan. Vain rivit joiden avain on validi shell-env-muuttujanimi (`^[A-Za-z_][A-Za-z0-9_]*$`) poimitaan. |
| **stderr** | Diagnostiikka. Mikä tahansa muu (ei-`KEY=VALUE`) tuloste — myös stdoutiin eksynyt proosa — jätetään huomiotta. **Suosi stderriä diagnostiikalle.** |
| **paluuarvo** | `0` = onnistui. `≠0` = ajo blokataan (`provision_test_env_failed`, ks. alla). |
| **idempotenssi** | Hook ajetaan kaikilla implementeriin johtavilla poluilla (normaali, `--resume`, `--restart`, `--continue`). `provision` **ei saa luoda toista resurssia** uudelleenajossa — uudelleenkäytä tai uudelleenluo deterministisesti (esim. `DROP DATABASE IF EXISTS` + `CREATE`). `cleanup` on idempotentti (`DROP ... IF EXISTS`). |

### Salaisuudet

Staattiset tunnukset (Postgres dev host/portti/user/salasana yms.) tulevat olemassa olevasta
`source_machine_env`-mekanismista (`~/.config/run-issues/env`), **eivät committiin menevästä
`.claude/`-skriptistä**. Hook lukee ne ympäristöstä (esim. `$PGHOST`, `$PGUSER`).
Orkestraattori tallentaa `run.json`:iin vain injektoitujen avainten **nimet**, ei arvoja
— conn-string-salasana ei päädy run-stateen.

## Esimerkki (Postgres + Prisma -monorepo)

`<repo>/.claude/provision-test-env.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
mode="$1"; runid="$2"

# Staattiset tunnukset koneellisesta env-tiedostosta (source_machine_env).
host="${PGHOST:-127.0.0.1}"; port="${PGPORT:-5432}"
user="${PGUSER:-postgres}"; pass="${PGPASSWORD:-postgres}"
# Run-id-eristetty kannan nimi: rinnakkaiset ajot eivät törmää.
db="test_$(printf '%s' "$runid" | tr -c 'a-zA-Z0-9' '_')"
url="postgres://$user:$pass@$host:$port/$db"

case "$mode" in
  provision)
    echo "provisioning $db" >&2                       # diagnostiikka -> stderr
    PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d postgres \
      -c "DROP DATABASE IF EXISTS \"$db\";" -c "CREATE DATABASE \"$db\";" >&2
    DATABASE_URL_TEST="$url" pnpm --filter @customer-a/api prisma migrate deploy >&2
    echo "DATABASE_URL_TEST=$url"                      # KEY=VALUE -> stdout
    ;;
  cleanup)
    PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d postgres \
      -c "DROP DATABASE IF EXISTS \"$db\";" >&2 || true
    ;;
esac
```

> Tämä on **esimerkki**, ei osa dotfiles-repoa. Kohderepo (esim. `customer-a-report`) omistaa
> oman skriptinsä; orkestraattori pysyy geneerisenä eikä sisällä DB-/Prisma-spesifistä
> logiikkaa.

## Esimerkki (WordPress/Bedrock — selain-UI-verifiointi)

Bedrock-worktree ei ole sellaisenaan selaimella ladattava sivusto: `vendor/` ja WP-core
(`web/wp/`) syntyvät vasta `composer install`:lla (S7b ajaa sen automaattisesti, kun
`composer.lock` on worktreen juuressa), eikä worktreessä ole `.env`:iä, uploads-hakemistoa
tai serving-prosessia. Tämä hook pystyttää ne per ajo ja injektoi serving-osoitteen
sovitulla avaimella **`RUN_ISSUES_BASE_URL`**, jonka implementer-prompt tunnistaa
(Playwright `e2e/` -ajo `baseURL`:lla).

`<repo>/.claude/provision-test-env.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
mode="$1"; runid="$2"

# Run-id-eristys: rinnakkaiset ajot saavat eri Valet-linkin/portin eivätkä törmää.
slug="run-$(printf '%s' "$runid" | tr -c 'a-zA-Z0-9' '-')"
host="$slug.test"                          # per-ajo Valet-domain
url="https://$host"
wt="$PWD"                                  # CWD = worktreen juuri (S7c-sopimus)

case "$mode" in
  provision)
    # Per-ajo .env. DB_NAME = orkestraattorin kloonaama kanta (RUN_ISSUES_DB_CLONE),
    # DB-credentiaalit koneellisesta env-tiedostosta (source_machine_env) — EIVÄT tästä
    # committiin menevästä skriptistä.
    cat > "$wt/.env" <<ENV
DB_NAME=${RUN_ISSUES_DB_CLONE:?provision needs a DB clone}
DB_USER=${WP_DB_USER:-root}
DB_PASSWORD=${WP_DB_PASSWORD:-}
DB_HOST=${WP_DB_HOST:-127.0.0.1}
WP_ENV=development
WP_HOME=$url
WP_SITEURL=$url/wp
ENV

    # Uploads: linkitä jaettuun mediahakemistoon (worktreessä ei ole sitä).
    mkdir -p "$wt/web/app"
    [ -e "$wt/web/app/uploads" ] || ln -s "${WP_UPLOADS_DIR:?}" "$wt/web/app/uploads"

    # Serving: per-ajo Valet-linkki worktreen web/-juureen.
    ( cd "$wt/web" && valet link "$slug" >&2 )

    echo "RUN_ISSUES_BASE_URL=$url"         # KEY=VALUE -> stdout (implementerin baseURL)
    ;;
  cleanup)
    ( cd "$wt/web" 2>/dev/null && valet unlink "$slug" >&2 ) || true
    rm -f "$wt/web/app/uploads" "$wt/.env" || true
    ;;
esac
```

> Sama invariantit kuin Postgres-esimerkissä: **run-id-eristys pakollinen** (eri ajo → eri
> Valet-domain, ei jaettua serving-osoitetta), salaisuudet `source_machine_env`:stä, ja
> `cleanup` purkaa serving-linkin **ennen worktreen poistoa** (`cleanup-run.sh` ajaa sen).
> Serving-tapa (`valet link` vs. `php -S`/`wp server`) on **hookin valinta** — orkestraattori
> tarjoaa vain `RUN_ISSUES_BASE_URL`-kanavan.

## Vaiheen sijainti tilakoneessa

```
S7b_EnvBootstrap  →  S7c_ProvisionTestEnv  →  S8_Implementer
(riippuvuusasennus)   (tämä hook)              (toteutus + testit)
```

Hook ajetaan **S7b:n jälkeen**, jotta migraatio voi nojata asennettuihin riippuvuuksiin
(esim. `pnpm prisma` `node_modules`:sta), ja **S8:n edellä**, jotta implementerin testiajo
näkee injektoidut env-muuttujat. Provisiointi ei kuluta implementer-timeout-budjettia, mutta
kasvattaa ajon kokonaiskestoa.

## Virhetilanne (fail-fast)

Jos hook palauttaa `rc≠0`, ajo viimeistellään tilaan `status=blocked`,
`blocked_reason=provision_test_env_failed`, lisätään `needs-human`-label, **provisiointiloki
postataan issueen** ja orkestraattori palauttaa **exit 5**. Implementer-timeout-budjettia ei
kuluteta. Tämä noudattaa samaa kaavaa kuin S7b env-bootstrap -portti.

## Teardown

`cleanup-run.sh` (manuaalinen siivous) ja `auto-clean.sh` (label-pohjainen siivous, kutsuu
`cleanup-run.sh`:ta) ajavat `provision-test-env.sh cleanup <run-id>`:n **best-effort**:
sen epäonnistuminen lokitetaan eikä kaada siivousta. Teardown ajetaan **ennen worktreen
poistoa**, koska hook sijaitsee worktreessä (toisin kuin `db-clone.sh`, joka on
orkestraattorin script-hakemistossa ja säilyy worktreen poistossa). Gate: run.json:n
`provision_test_env`-kenttä on ei-tyhjä (orkestraattori asettaa sen onnistuneessa
provisioinnissa) ja worktreen hook on yhä suoritettava.

> **Orpo-resurssit:** jos worktree on jo poistettu kun teardown yritetään, hook ei ole
> tavoitettavissa eikä resurssia voida poistaa automaattisesti. Run-id-prefiksi mahdollistaa
> orpojen periodisen siivouksen erillisenä huomiona (ei tämän koneiston vastuulla).

## Turvallisuus (luotettu tiedosto)

`.claude/provision-test-env.sh` on **luotettu tiedosto**: se ajaa mielivaltaista shelliä
ajokoneella (sama vastuu kuin `db-clone`-config). Tästä syystä:

- **Kohtele skriptiä kuin koodia** — sen kirjoitusoikeudet kuuluvat vain tahoille, joihin
  luotat. Yksityisissä repoissa riskitaso on matala, mutta luotettu-status on syytä tiedostaa.
- **Älä laita salaisuuksia skriptiin** — lue ne ympäristöstä (`source_machine_env`).

## run.json-kentät

| Kenttä | Merkitys |
|---|---|
| `provision_test_env` | Injektoitujen env-avainten nimet pilkulla eroteltuna (esim. `DATABASE_URL_TEST,REDIS_URL`), tai `provisioned` jos hook onnistui ilman avaimia. Ei-tyhjä → teardown ajaa hookin. **Arvoja (salaisuuksia) ei tallenneta.** |
