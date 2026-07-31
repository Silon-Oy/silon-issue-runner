# CLAUDE.md — claude-issue-runner

## 1. Mikä tämä repo on

Itsenäisesti asennettava paketti `/run-issues`-orkestraattorille ja sen ympärillä olevalle
automaatiolle: GitHub-issuesta valmiiseen pull requestiin ilman ihmistä silmukassa, sekä
PR-vahti (`pr-watch.sh`), joka vie PR:n merge-tilaan asti.

Paketti irrotettiin dotfiles-reposta (#2), koska se on yleiskäyttöinen työkalu eikä yhden
ihmisen ympäristökonfiguraatiota. Tässä repossa **ei ole henkilökohtaista konfiguraatiota**:
ei watchlistiä (vain skeemaesimerkki `examples/`-hakemistossa), ei koneistokohtaisia
env-tiedostoja, ei salaisuuksia.

Sisältö:

- **Orkestraattori** — `orchestrate.sh` + `lib/` + `prompts/`: yksi issue → yksi ajo → yksi PR.
- **Pollerit** — `poller.sh`, `pr-watch-poller.sh`: LaunchAgent-vetoinen automaattiajo watchlistin repoille.
- **PR-vahti** — `pr-watch.sh`: CI-odotus, konfliktin ratkaisu, auto-merge.
- **Apuvälineet** — `cleanup-run.sh`, `auto-clean.sh`, `unblock-issues.sh`.
- **Claude-integraatio** — `agents/`, `commands/` (slash-komennot), `prompts/`.

## 2. Hakemistorakenne ja polkuvalinta

```
orchestrate.sh                 poller.sh              pr-watch.sh
pr-watch-poller.sh             cleanup-run.sh         auto-clean.sh
unblock-issues.sh              provision-test-env.README.md
lib/       13 bash-moduulia (ks. §6)
prompts/   orkestraattorin claude-kutsujen promptipohjat
tests/     plain-bash-testipaketti, ajuri run-all.sh
db-clone/  opt-in-tietokantakloonaus
agents/    Claude-agenttimäärittelyt (architect, developer, reviewer, refactorer)
commands/  slash-komennot (run-issues, cleanup-run, pr-watch, refresh, factory-*)
docs/diagrams/  mermaid-kaaviot (.mmd)
examples/  run-issues-watchlist.example.json
com.claude-issue-runner.run-issues-poller.plist
com.claude-issue-runner.pr-watch-poller.plist
.gitignore
```

### Miksi repo-juuri on litteä

**Paketin repo-juuri _on_ submodulen mount-piste.** Epic (#1) lukitsee sidontatavan: paketti
liitetään dotfilesiin git-submodulena polkuun `claude/scripts/run-issues`. Git mounttaa
submodulen **repo-juuren** siihen polkuun, joten juuren sisällön on oltava täsmälleen se, mitä
`claude/scripts/run-issues/`-hakemistossa ennen oli.

Issue #3 tarjosi kaksi vaihtoehtoa, ja kumpikin hylättiin mitatun tuloksen perusteella
(todennettu kertakäyttöisellä `git submodule add` -kokeella ennen siirtoa):

| Vaihtoehto | Paketin juuri | Lopputulos mountin jälkeen |
|---|---|---|
| A — säilytä polut | `claude/scripts/run-issues/orchestrate.sh` | `…/run-issues/claude/scripts/run-issues/orchestrate.sh` — kaksinkertainen sisäkkäisyys |
| B — `scripts/` juureen | `scripts/orchestrate.sh` | `…/run-issues/scripts/orchestrate.sh` — yksi taso liikaa |
| **C — valittu** | `orchestrate.sh` | `…/run-issues/orchestrate.sh` — osuu |

A ja B rikkoisivat jokaisen viittauksen, joka osoittaa polkuun `…/run-issues/<skripti>`:
kolme slash-komentoa (`commands/{run-issues,cleanup-run,pr-watch}.md`),
`prompts/02-implementer.md`, molemmat LaunchAgent-plistit ja `poller.sh`:n omat
`${DOTFILES}/claude/scripts/run-issues/…`-polut. Rakenne C säilyttää ne kaikki sanatarkasti.

Siirto oli mahdollinen ilman koodimuutoksia, koska jokainen suoritettava skripti ja testi
resolvoi riippuvuutensa oman sijaintinsa suhteen (`SCRIPT_DIR` / `HERE`) eikä yksikään nouse
`../..`-tasolle. Ainoa poikkeus oli `pr-watch-poller.sh`:n `unblock-issues.sh`-polku — ks. §12.

**Invariantti:** juuressa ei saa olla `claude/`-hakemistoa. `tests/test-package-layout.sh`
vartioi tätä, koska rikkoutuminen olisi muuten hiljainen (paketti näyttäisi ehjältä, mutta
kaikki ulkoiset viittaukset osoittaisivat väärään paikkaan).

## 3. Asennusmalli

```
paketin repo-juuri
  └─ git submodule → ~/dotfiles/claude/scripts/run-issues
       └─ dotfilesin hakemistosymlinkki claude/scripts → ~/.claude/scripts
            └─ ~/.claude/scripts/run-issues/orchestrate.sh   ← slash-komentojen polku
```

`agents/` ja `commands/` päätyvät tässä ketjussa polkuun `~/.claude/scripts/run-issues/…`,
mikä ei riitä: Claude Code lukee ne hakemistoista `~/.claude/agents/` ja `~/.claude/commands/`.
Paketin oma `install.sh` (#4) symlinkkaa ne sinne **per tiedosto**, jotta muiden lähteiden
agentit ja komennot eivät korvaudu.

Submodule pinnataan tiettyyn committiin: dotfilesin `git pull` ei siis koskaan päivitä
orkestraattoria vahingossa, vaan päivitys on eksplisiittinen toimenpide.

## 4. Tilakone

Lähde: `orchestrate.sh` (otsikkokommentti + `enter_state`-kutsut) ja
`docs/diagrams/run-issues-state-machine.mmd`.

**Vaihe A** — S1 PickIssue → S2 Lock → S3 Claim → S4 Worktree → S5 DBClone → S6 CycleReview

**Review-portti (S7)** — auto-tilassa päätös tehdään in-process; interaktiivisessa tilassa
orkestraattori poistuu koodilla 10 ja jättää ajohakemiston ja lukon elämään. Jatko:
`orchestrate.sh --resume <run-dir> --decision PROCEED|CANCEL`.

**Vaihe B** — S7b EnvBootstrap → S7c ProvisionTestEnv → S8 Implementer → S9 Evolution →
S10 Push → S11 PRCreate → S12 Finalize

- **S7b EnvBootstrap** on fail-fast-portti riippuvuuksien asennukselle. Epäonnistunut asennus
  finalisoi ajon tilaan `blocked/env_bootstrap_failed` sen sijaan, että implementer polttaisi
  koko timeout-budjettinsa hiljaa.
- **S7c ProvisionTestEnv** on opt-in, kohderepon omistama hook
  (`<worktree>/.claude/provision-test-env.sh`). Puuttuva hook → no-op; epäonnistuminen
  fail-fastaa samoin kuin S7b (`blocked/provision_test_env_failed`).

**Jatkomoodit:**

- `--restart <run-dir>` — jatkaa `timed_out`-ajoa ramppaavalla timeoutilla
  (`base * (1 + retry_count)`, katto `RUN_ISSUES_CLAUDE_TIMEOUT_MAX`). Ohittaa pick/claimin ja
  palaa vaiheeseen B. Budjetti `RUN_ISSUES_MAX_RETRIES`.
- `--continue <run-dir>` — jatkaa `awaiting_clarification`-ajoa sen jälkeen kun issueen on
  vastattu: ottaa lukon uudelleen, kasvattaa `clarification_round`ia ja ajaa S6:n uudelleen
  vastaus kontekstina. Silmukkakatto `RUN_ISSUES_MAX_CLARIFICATIONS`.

## 5. Exit-koodit

Lähde: `orchestrate.sh`, otsikkokommentti.

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui — PR avattu, tai resume peruttiin siististi |
| 1 | Fataali — virheellinen käyttö / puuttuva `run.json` resumessa |
| 2 | Ei ehdokasissueta (poll-tila, ei tehtävää) |
| 3 | Lukko-/claim-kisa hävitty |
| 4 | Cycle review esti ajon (vain auto-tila) |
| 5 | Estynyt ennen implementeriä tai siinä — db-clone, S7b tai S7c epäonnistui, tai implementer palautti BLOCKED |
| 6 | PR:n avaus epäonnistui |
| 7 | Implementer (S8) timeouttasi — ajo finalisoitu `timed_out`, kelpaa `--restart`iin |
| 10 | Odottaa ihmisen katselmointia — jatka `--resume` |
| 11 | Odottaa tarkennusta — cycle review palautti NEEDS_CLARIFICATION; ajo finalisoitu `awaiting_clarification`, pollerin `scan_answered` jatkaa `--continue`lla |

## 6. `lib/`-rakenne

| Tiedosto | Vastuu |
|---|---|
| `claude-call.sh` | Yksittäisen orkestroidun askeleen claude-CLI-kutsu (timeout, lokitus, finalisointi) |
| `env-bootstrap.sh` | Pakettimanagerin tunnistus S7b:n fail-fast-asennusporttiin |
| `git-remote.sh` | Multi-remote-apurit: yksi klooni voi pollata useaa GitHub-orgia |
| `github-app-auth.sh` | Opt-in GitHub App -identiteetti orkestraattorille ja PR-vahdille |
| `gitignore.sh` | Pitää **kohderepon** `.gitignore`n ignoroimassa ajoaikaiset artefaktit |
| `hook-runner.sh` | Synkroninen commit, joka ajaa post-commit-hookit loppuun ennen paluuta |
| `issue-images.sh` | Issuen kuvien poiminta ja lataus, jotta agentit näkevät ne |
| `issue.sh` | GitHub-issue-operaatiot `gh`-CLI:n ympärillä |
| `issue.test.sh` | `verify_claim`in yksikkötestit (S2/S3-kilpajuoksu) |
| `labels.sh` | Label-hallinta REST-API:n kautta (ei `gh issue edit --add-label`) |
| `locking.sh` | Issue-kohtainen lukkohakemisto, atominen `mkdir(2)`:lla |
| `pr-watch-lib.sh` | PR:n luokittelu- ja merge-päätöslogiikka (irrotettu testattavaksi) |
| `render-prompt.test.sh` | `render_prompt`in yksikkötestit (rekursiivinen sijoitus) |
| `state.sh` | Ajon durable-tila `<run-dir>`-hakemistossa |
| `worktree.sh` | Ajokohtaiset git-worktreet kohderepossa |

## 7. Ympäristömuuttujat

### Orkestraattori

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_AUTO` | `0` | `1` = ei interaktiivisia kehotteita |
| `RUN_ISSUES_REVIEW_GATE` | `interactive` (`auto` jos `RUN_ISSUES_AUTO=1`) | S7-portin tila |
| `RUN_ISSUES_LABELS_CSV` | *(tyhjä)* | Label-suodatin poll-tilassa |
| `RUN_ISSUES_PR_LABELS_CSV` | `auto-merge` | Issuelta PR:lle propagoitavat labelit |
| `RUN_ISSUES_BASE_BRANCH` | *(repon oletushaara)* | Pakotettu base-haara |
| `RUN_ISSUES_MAX_RETRIES` | `1` | `--restart`-budjetti timeoutin jälkeen |
| `RUN_ISSUES_MAX_CLARIFICATIONS` | `3` | Tarkennussilmukan katto |
| `RUN_ISSUES_CLAUDE_TIMEOUT` | `3600` (claude-call.sh oletus 1800) | Perusaikabudjetti per claude-kutsu |
| `RUN_ISSUES_CLAUDE_TIMEOUT_MAX` | `3600` | Ramppaavan timeoutin katto |
| `RUN_ISSUES_CLAUDE_CMD` | `npx --no-install @anthropic-ai/claude-code` | Claude-CLI:n kutsu |
| `RUN_ISSUES_CLAUDE_MODEL` | *(tyhjä)* | Mallin ohitus |
| `RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT` | `1200` | S7b:n aikakatto |
| `RUN_ISSUES_ENV_FILE` | `$HOME/.config/run-issues/env` | Koneistokohtainen env-tiedosto |
| `RUN_ISSUES_LOCK_ROOT` | `$HOME/Library/Application Support/run-issues/locks` | Lukkohakemistojen juuri |
| `RUN_ISSUES_LOCK_STALE_SECS` | `86400` | Lukon vanhenemisraja |
| `RUN_ISSUES_SITUATION_ARTIFACT_MAX` | `60000` | Tilanneartefaktin kokokatto (tavua) |
| `RUN_ISSUES_MAX_IMAGES` | `10` | Issuesta ladattavien kuvien enimmäismäärä |
| `RUN_ISSUES_MAX_IMAGE_BYTES` | `10485760` | Yksittäisen kuvan kokokatto |
| `RUN_ISSUES_IMAGE_TIMEOUT` | `60` | Kuvalatauksen timeout |
| `RUN_ISSUES_REPO_SLUG_MAX` | `40` | Repo-slugin pituuskatto ajotunnisteissa |

### Poller

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_STALE_AFTER` | `3600` | Liveness-raja: vanhempi ajo tapetaan ja finalisoidaan `blocked/stalled_in_<state>`. **Täytyy** ylittää pisin laillinen yksivaiheinen claude-kutsu |
| `RUN_ISSUES_CLEAN_LABEL` | `auto-clean` | Label, joka laukaisee `auto-clean.sh`:n |

### PR-vahti

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `PR_WATCH_AUTO` | `0` | `1` = ei interaktiivisia kehotteita |
| `PR_WATCH_MERGE_LABEL` | `auto-merge` | Label, joka sallii auto-mergen |
| `PR_WATCH_LABELS_CSV` | *(tyhjä)* | Label-suodatin scan-tilassa |
| `PR_WATCH_ENABLE_CONFLICT_RESOLUTION` | `0` (poller nostaa `1`:ksi) | AI-avusteinen rebase-konfliktin ratkaisu |
| `PR_WATCH_CONFLICT_TIMEOUT` | `1800` | Konfliktinratkaisun aikakatto |
| `PR_WATCH_CI_MAX_POLLS` | `40` | CI-odotuksen kierrosten määrä |
| `PR_WATCH_CI_POLL_SECS` | `15` | CI-odotuksen kierrosväli (40 × 15 s = 10 min) |

### GitHub App (opt-in, ks. §8)

`RUN_ISSUES_GITHUB_APP_ID`, `RUN_ISSUES_GITHUB_APP_INSTALLATION_ID`,
`RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH`, `RUN_ISSUES_GHA_CACHE_FILE`,
`RUN_ISSUES_GHA_REFRESH_BUFFER_SECONDS` (`300`),
`RUN_ISSUES_GHA_TOKEN_ENDPOINT_BASE` (`https://api.github.com`).

## 8. Opt-in-mekanismit

Kaikki alla oleva on **pois päältä oletuksena**. Puuttuva konfiguraatio on hyvänlaatuinen
no-op, ei virhe.

- **`db-clone/`** — kohderepon `.claude/db-clone.json` ohjaa tietokannan kloonauksen ajon
  ajaksi (S5). Kloonin nimi injektoidaan implementerille muuttujana
  `RUN_ISSUES_DB_CLONE`. Ks. `db-clone/README.md`.
- **`provision-test-env`-hook** — kohderepon `<worktree>/.claude/provision-test-env.sh` (S7c)
  provisioi testien tarvitsemat ulkoiset resurssit ja injektoi osoitteet `KEY=VALUE`-muodossa
  implementerin ympäristöön. Erillinen koneisto db-clonesta, ei korvaaja. Ks.
  `provision-test-env.README.md`.
- **`PR_WATCH_ENABLE_CONFLICT_RESOLUTION`** — AI-avusteinen rebase-konfliktin ratkaisu.
  `pr-watch.sh` pitää sen pois päältä; `pr-watch-poller.sh` nostaa sen päälle watchlistin
  repoille, jotta auto-merge pääsee konfliktin läpi ilman ihmistä.
- **`lib/github-app-auth.sh`** — GitHub App -identiteetti henkilökohtaisen tokenin sijaan.
  Aktivoituu vain jos App-env-muuttujat on asetettu; muuten jokainen sivuvaikutus on vartioitu.

## 9. Soft-riippuvuus: `POST_COMMIT_SYNC=1`

`orchestrate.sh` exporttaa `POST_COMMIT_SYNC=1`, ja `lib/hook-runner.sh` ajaa committinsa sen
kanssa. Lippu kertoo dotfilesin post-commit-hookille, että se saa ajaa dokumenttipäivitys- ja
turvatarkistuscommitit **synkronisesti loppuun** ennen paluuta, jotta ne päätyvät samalle
feature-haaralle.

**Paketti ei vaadi tätä hookia.** Jos hookia ei ole, lippu on merkityksetön
ympäristömuuttuja eikä mikään rikkoudu — orkestraattori committaa normaalisti. Kyse on siis
soft-riippuvuudesta, ei asennusehdosta. Ks.
`docs/diagrams/run-issues-component-dependencies.mmd`.

Vastapari: `pr-watch.sh` **ei** aseta lippua. Merge-jälkeinen työ ajetaan mainissa, jossa
synkroninen hookketju ei ole toivottu.

## 10. Testien ajo

```bash
bash tests/run-all.sh        # paketin juuresta
bash tests/test-<nimi>.sh    # yksittäinen testi
```

Konventiot:

- Plain bash, ei testiframeworkia. Jokainen `test-*.sh` exittaa 0 = pass, ≠0 = fail.
- Kun esiehto puuttuu (ei `jq`:ta, ei paikallista tietokantaa, väärä host), testi tulostaa
  `SKIP: <syy>` ja exittaa **0**. Näin paketti on testattavissa ilman maintainern ympäristöä.
- `set -uo pipefail` (ei `-e`: testin pitää kerätä kaikki virheet, ei kaatua ensimmäiseen).
- Tulosteet `PASS: …` / `FAIL: …`, lopussa `[ "$FAIL" -eq 0 ]`.
- `run-all.sh` poimii `tests/test-*.sh`-globilla — uusi testi tulee ajoon nimeämällä.

Testipaketti ajaa ilman dotfiles-kontekstia. Se on samalla rakenteen regressiosuoja: jokainen
testi resolvoi `$HERE/../lib/…`, joten hakemistosiirto rikkoisi ne välittömästi.

## 11. LaunchAgent-migraatio

Plistit nimettiin uudelleen `com.maintainer.*` → `com.claude-issue-runner.*`. **launchd tunnistaa
agentin labelista, ei tiedostonimestä**, joten uuden plistin lataaminen ei korvaa vanhaa: ilman
bootoutia koneella ajaisi kaksi polleria samasta koodista. Ne lukisivat saman watchlistin ja
kilpailisivat samasta `global_max_concurrent`-katosta.

Aja **kerran** koneella, jolla vanhat agentit ovat ladattuina — **ennen** uusien
bootstrappaamista:

```bash
launchctl bootout gui/$(id -u)/com.maintainer.run-issues-poller
launchctl bootout gui/$(id -u)/com.maintainer.pr-watch-poller
rm -f ~/Library/LaunchAgents/com.maintainer.run-issues-poller.plist
rm -f ~/Library/LaunchAgents/com.maintainer.pr-watch-poller.plist
# Poista lähdeplistit myös ~/dotfiles-juuresta, muuten sync.sh lataa ne takaisin.
```

Välitilassa (bootout tehty, bootstrap tekemättä) auto-run on pysähdyksissä. Se on turvallinen
tila: mitään ei aja kahteen kertaan. Ks. `docs/diagrams/launchagent-migration-states.mmd`.

Uusien agenttien **deploy on paketin oman `install.sh`:n vastuulla (#4)**, ei dotfilesin
`sync.sh`:n: `sync.sh` globaa plistit vain dotfilesin juuresta eikä siis näe submodulen sisällä
olevia tiedostoja. Konventio itsessään säilyy — `Label` == tiedostonimi ilman `.plist`,
`plutil -lint` porttina, `$HOME` literaalina plistissä (laajenee, koska komento ajetaan
`/bin/bash -l -c` -kääreen läpi).

## 12. Tunnetut avoimet asiat

- **Plist-deploy → #4.** Dotfilesin `sync.sh` ei näe submodulen sisältöä, joten LaunchAgentien
  asennus siirtyy paketin omalle `install.sh`:lle. Epicin #8 sisältää tästä virheellisen
  oletuksen.
- **Plistien polut eivät ole siirrettäviä → #6.** `ProgramArguments` osoittaa polkuun
  `$HOME/dotfiles/claude/scripts/run-issues/…`, samoin `poller.sh`:n ja `pr-watch-poller.sh`:n
  omat `${DOTFILES}`-polut. Ne resolvoituvat oikein tässä asennusmallissa, mutta ovat
  dotfiles-sidonnaisia: ilman dotfilesia asennettuna ne eivät osu. Polkujen
  parametrisointi on #6.
- **`unblock-issues.sh`:n haarautunut resolvointi.** `pr-watch-poller.sh` etsii skriptin
  ensisijaisesti paketista (`${SCRIPT_DIR}/unblock-issues.sh`) ja vasta sitten vanhasta
  dotfiles-polusta. Kummankin haaran kattavaa testiä ei ole — se vaatisi resolvoinnin
  irrottamisen omaksi funktiokseen. Nyt testataan vain, että ensisijainen polku osuu.
- **`commands/factory-run.md` viittaa puuttuvaan skriptiin.** Ohje kehottaa ajamaan
  `templates/factory-init.sh`-skriptin; tiedostoa ei ole tässä repossa. Joko se jäi pois
  siirrosta (#2) tai viittaus on vanhentunut.
- **`README.md` puuttuu → #9.** Tämä tiedosto palvelee agenttia; ihmiselle suunnattu
  asennus- ja käyttöohje on vielä kirjoittamatta.
