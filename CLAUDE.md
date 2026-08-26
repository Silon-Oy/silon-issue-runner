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
- **Apuvälineet** — `cleanup-run.sh`, `auto-clean.sh`.
- **Claude-integraatio** — `agents/`, `commands/` (slash-komennot), `skills/`, `prompts/`.

## 2. Hakemistorakenne ja polkuvalinta

```
orchestrate.sh                 poller.sh              pr-watch.sh
pr-watch-poller.sh             cleanup-run.sh         auto-clean.sh
stop-run.sh                    status.sh              status-digest.sh
status-render.sh               action-server.sh       action-dispatch.sh
install.sh                     run-epic.sh            self-update.sh
provision-test-env.README.md   README.md              CLAUDE.md
lib/       18 bash-moduulia + action-service.py (ks. §6)
prompts/   orkestraattorin claude-kutsujen promptipohjat
tests/     plain-bash-testipaketti, ajuri run-all.sh
db-clone/  opt-in-tietokantakloonaus
agents/    Claude-agenttimäärittelyt (architect, developer, reviewer, refactorer)
commands/  slash-komennot (run-issues, run-epic, cleanup-run, pr-watch, refresh, factory-*)
skills/    Claude-skillit (claude-issue-runner: järjestelmän käyttöohje kohderepoon — labelit,
           poiminta, epicit, ongelmatilanteet, komennot)
docs/diagrams/  mermaid-kaaviot (.mmd)
examples/  run-issues-watchlist.example.json, run-issues-poller.env.example,
           status-digest.env.example, status-caddy.example
com.claude-issue-runner.run-issues-poller.plist
com.claude-issue-runner.pr-watch-poller.plist
com.claude-issue-runner.status-render.plist
com.claude-issue-runner.action-server.plist
com.claude-issue-runner.self-update.plist
.gitignore
```

### Miksi repo-juuri on litteä

**Paketin repo-juuri _on_ mount-piste.** Kummassakin asennusmallissa (§3) polkuun
`~/.claude/scripts/run-issues` päätyy paketin **juuri**, ei alihakemisto: oletusmallissa
`install.sh`:n symlinkkinä, ylläpitäjän mallissa git-submodulena dotfilesin puussa (#1).
Juuren sisällön on siis oltava täsmälleen se, mitä tuossa hakemistossa pitää näkyä.

Issue #3 tarjosi kaksi vaihtoehtoa, ja kumpikin hylättiin mitatun tuloksen perusteella
(todennettu kertakäyttöisellä `git submodule add` -kokeella ennen siirtoa):

| Vaihtoehto | Paketin juuri | Lopputulos mountin jälkeen |
|---|---|---|
| A — säilytä polut | `claude/scripts/run-issues/orchestrate.sh` | `…/run-issues/claude/scripts/run-issues/orchestrate.sh` — kaksinkertainen sisäkkäisyys |
| B — `scripts/` juureen | `scripts/orchestrate.sh` | `…/run-issues/scripts/orchestrate.sh` — yksi taso liikaa |
| **C — valittu** | `orchestrate.sh` | `…/run-issues/orchestrate.sh` — osuu |

A ja B rikkoisivat jokaisen viittauksen, joka osoittaa polkuun `…/run-issues/<skripti>`:
kolme slash-komentoa (`commands/{run-issues,cleanup-run,pr-watch}.md`),
`prompts/02-implementer.md` ja molemmat LaunchAgent-plistit. Rakenne C säilyttää ne kaikki
sanatarkasti. Pollerit resolvoivat omat riippuvuutensa `SCRIPT_DIR`istä (#6), joten ne
selviäisivät siirrosta itsekseen — mutta juuri siksi paketin juuri _on_ se hakemisto, johon
plistien ohjelmapolku osoittaa.

Siirto oli mahdollinen ilman koodimuutoksia, koska jokainen suoritettava skripti ja testi
resolvoi riippuvuutensa oman sijaintinsa suhteen (`SCRIPT_DIR` / `HERE`) eikä yksikään nouse
`../..`-tasolle.

**Invariantti:** juuressa ei saa olla `claude/`-hakemistoa. `tests/test-package-layout.sh`
vartioi tätä, koska rikkoutuminen olisi muuten hiljainen (paketti näyttäisi ehjältä, mutta
kaikki ulkoiset viittaukset osoittaisivat väärään paikkaan).

## 3. Asennusmalli

Malleja on kaksi, ja ne eroavat vain siinä **kuka tuottaa polun
`~/.claude/scripts/run-issues`**. Loppupää on identtinen: slash-komennot ja
`prompts/02-implementer.md` näkevät saman polun kummassakin.

**Oletus — klooni mihin tahansa + `install.sh`.** Paketilla ei ole vaadittua sijaintia
levyllä eikä dotfiles-repoa tarvita.

```
paketin repo-juuri (klooni missä tahansa)
  └─ install.sh: symlink → ~/.claude/scripts/run-issues
       └─ ~/.claude/scripts/run-issues/orchestrate.sh   ← slash-komentojen polku
```

**Ylläpitäjän kone — dotfiles-submodule (#1).** Polku on olemassa jo ennen asennusta, kahden
linkin päässä.

```
paketin repo-juuri
  └─ git submodule → ~/dotfiles/claude/scripts/run-issues
       └─ dotfilesin hakemistosymlinkki claude/scripts → ~/.claude/scripts
            └─ ~/.claude/scripts/run-issues/orchestrate.sh   ← sama polku, eri toimittaja
```

Submodule pinnataan tiettyyn committiin: dotfilesin `git pull` ei siis koskaan päivitä
orkestraattoria vahingossa, vaan päivitys on eksplisiittinen toimenpide. Pinnin kääntöpuoli on
että ajossa oleva koodi voi ajautua hiljaa `main`in taakse; #32:n jälkeen ajautuma on näkyvä
(pollerit lokittavat `version=<sha> behind_origin=<N>` tikin alussa ja varoittavat kun `N>0`,
`orchestrate.sh --version` tulostaa saman, ja situation-kommenteissa on `Runner-version:`-rivi;
lähde `lib/version.sh`, §6).

Kahdesta mallista seuraa, ettei asentajan `scripts`-sidonta voi olla ehdoton eikä puuttua:
submodule-mallissa polun tuottaa vieras puu, johon ei saa kirjoittaa, ja oletusmallissa mikään
muu ei tuota sitä lainkaan. `tests/test-install-links.sh` case 2 vartioi oletusmallia (klooni →
`install.sh` → `orchestrate.sh` suoritettavissa); sen kaatuminen tarkoittaa, että puhtaan
koneen slash-komennot osoittavat olemattomaan skriptiin.

`agents/`, `commands/` ja `skills/` päätyvät kummassakin ketjussa polkuun
`~/.claude/scripts/run-issues/…`, mikä ei riitä: Claude Code lukee ne hakemistoista
`~/.claude/agents/`, `~/.claude/commands/` ja `~/.claude/skills/`. Paketin oma `install.sh`
symlinkkaa agentit ja komennot sinne **per tiedosto** ja skillit **per hakemisto** (skill on
`<nimi>/SKILL.md` mahdollisine liitteineen), jotta muiden lähteiden agentit, komennot ja
skillit eivät korvaudu.

### `install.sh`

```bash
bash install.sh [--dry-run] [--with-launchagents] [--quiet]
```

Asentajan koko ongelma on **omistajuus jaetussa nimiavaruudessa**: `~/.claude/agents/` ja
`~/.claude/commands/` ovat hakemistoja, joihin useampi lähde kirjoittaa. Siitä seuraa yksi
invariantti, josta kaikki muu johdetaan:

> **INV-OWN** — asentaja saa luoda, korvata tai poistaa vain polun, joka **puuttuu** tai on
> **symlink, jonka kohde resolvoituu paketin juuren sisään**. Kaikki muu on vierasta ja
> koskematonta.

Kolme johdannaista, jotka kannattaa lukea kieltoina:

1. **Omistajuus luetaan levyltä, ei manifestista.** Manifest voi vanhentua ja antaisi silloin
   poisto-oikeuden tiedostoon, jota paketti ei enää toimita — mahdollisesti sellaiseen, jota se
   ei koskaan toimittanut. Symlinkin kohde ei voi valehdella.
2. **Suunnittelu ja soveltaminen ovat eri vaiheet.** Kaikki tarkistukset ajetaan ensin, mitään
   ei kirjoiteta; yksikin kieltäytyminen ⇒ nolla muutosta. Tarkista-ja-kirjoita samassa
   silmukassa jättäisi puun puoliksi asennetuksi, kun toinen hakemisto osoittautuu vieraaksi —
   juuri se hiljainen osittaisvirhe, jonka takia asentaja on olemassa.
3. **Asentaja ei kutsu `launchctl`ia.** Ks. §11.

Neljä vastuuta:

| Kohde | Toimenpide |
|---|---|
| `~/.claude/agents/`, `~/.claude/commands/` | Per-tiedosto-symlink jokaiselle paketin `*.md`-tiedostolle. Lähdejoukko on glob, ei kovakoodattu lista — uusi agentti tulee asennukseen pelkällä nimeämisellä. Paketin omistamat symlinkit, joita paketti ei enää toimita, siivotaan (prune). |
| `~/.claude/skills/` | Per-hakemisto-symlink jokaiselle paketin `skills/<nimi>/SKILL.md`:lle (linkki on hakemistotasolla, koska skill voi sisältää liitetiedostoja). Sama omistajuuspredikaatti ja prune kuin agenteilla. **Ero:** vieras hakemistosymlinkki tuottaa tässä `conflict`in (exit 4), ei `refuse`a. Agents/commands-kohdalla kieltäytyminen suojaa paketin **ydintoiminnallisuutta** — ilman agentteja ja komentoja runner ei toimi, joten koko ajon pysäyttäminen on oikein. Skill on lisätieto, jonka puuttuminen ei riko mitään; ylläpitäjän koneella `~/.claude/skills` on hakemistosymlinkki (`-> dotfiles`, ks. §12), ja refuse siellä kaataisi myös agents/commands-osuuden, koska kieltäytyminen on koko ajon laajuinen. Siksi skills degradoituu conflict-riviksi ja ydinasennus jatkuu. |
| `~/.claude/scripts/run-issues` | **Ehdollinen** sidonta: jos polku jo toimii (`orchestrate.sh` suoritettavissa), se jätetään rauhaan riippumatta siitä kuka sen tarjoaa — submodule-malli ja jokainen toistoajo osuvat tähän, ja lopputulos on **no-op**. Jos polkua ei ole ja paketti voi omistaa sen, luodaan symlink paketin juureen — tämä on oletusmalli, jossa slash-komennot muuten osoittaisivat olemattomaan skriptiin. Vieraaseen puuhun ei kirjoiteta. |
| `~/Library/LaunchAgents/` | Vain `--with-launchagents`. Ks. §11. Deploy ei vielä käynnistä mitään: poller exittaa hiljaa 0, kunnes host-portti osuu koneen nimeen (`RUN_ISSUES_POLLER_HOSTS`, §7 ja §12). |

Exit-koodit (oma avaruus, ei sekoiteta §5:n orkestraattorikoodeihin):

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui (tai `--dry-run` valmis) |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | **Kieltäydytty — mitään ei muutettu.** Kohdepolku on jonkun muun omistama |
| 3 | Apply epäonnistui kesken (odottamaton tiedostojärjestelmävirhe); uusi ajo konvergoi |
| 4 | Valmis, mutta vieras tiedosto varjostaa paketin toimittamaa nimeä — mitään ei ylikirjoitettu |

Kieltäytyminen on ylläpitäjän koneen ilmiö, ei asennuksen normaali lopputulos: yleisin syy on
`~/.claude/agents` **hakemistosymlinkkinä** (dotfilesin jakoa edeltävä muoto), jolloin asentaja
kertoo mitä pitää tehdä eikä kirjoita mitään. Hakemistojen jakaminen per-tiedosto-symlinkeiksi
on dotfiles-repon puolen työ (#5). Puhtaalla koneella hakemistot puuttuvat tai ovat tavallisia
hakemistoja, jolloin asennus menee läpi.

Riippuvuustarkistus (`lib/preflight.sh`) on asentajassa **neuvoa-antava**: puuttuva `gh` tai
`jq` ei estä symlinkkien luontia, koska työkalut voi asentaa jälkikäteen.

## 4. Tilakone

Lähde: `orchestrate.sh` (otsikkokommentti + `enter_state`-kutsut) ja
`docs/diagrams/run-issues-state-machine.mmd`.

**S0 Preflight** — pakollisten riippuvuuksien portti ennen S1:tä (git, gh, jq, gh-kirjautuminen,
claude-CLI). Puute ⇒ exit 8 ennen kuin mitään on lukittu, claimattu tai luotu; stderr-viesti
nimeää korjauskomennon. Puuttuva timeout-binääri on vain varoitus (ajo jatkuu kuten ennenkin).
Portti on top-levelissä, joten se koskee kaikkia neljää moodia (start / `--resume` / `--restart` /
`--continue`). Ohitus: `RUN_ISSUES_SKIP_PREFLIGHT=1`.

**Vaihe A** — S1 PickIssue → S2 Lock → **S2b BlockedCheck** → **S2c EpicCheck** → S3 Claim →
S4 Worktree → S5 DBClone → S6 CycleReview

- **S2b BlockedCheck** (#28) on autoritatiivinen esto-portti lukon ja claimin välissä.
  Poimintahaun `-is:blocked` lukee GitHubin *eventually consistent* -hakuindeksiä; kerran
  laahaava indeksi päästi 25 estettyä issueta poimintaan peräkkäisinä tikkeinä. Portti lukee
  riippuvuusgraafin **suoraan** (`gh api …/issues/{n}/dependencies/blocked_by`,
  `lib/issue.sh:count_open_blockers`) ja on **fail-closed**: lukukelvoton graafi tulkitaan
  estoksi. Sijainti lukon jälkeen ⇒ vain lukon voittaja maksaa API-kutsun; ennen claimia ⇒
  estettyä issueta ei koskaan assignata itselle. Avoin estäjä ⇒ `blocked/blocked_by_dependency`,
  lukko vapautetaan, exit 9. Estäjien lukumäärä lokitetaan kummassakin tapauksessa, joten väärä
  poiminta näkyy lokista eikä vasta törmäävistä PR:istä. Nimetyn ajon voi pakottaa `--force`illa;
  `-is:blocked` jää halvaksi esikarsinnaksi, ei korvaudu.

- **S2c EpicCheck** (#81) on autoritatiivinen epic-portti S2b:n vieressä, samalla mallilla ja
  samasta syystä. Epic-issue **kokoaa** ajettavat alaissueet mutta ei ole itse ajettava; jos se
  poimittaisiin, implementer ajettaisiin epicin kokoavaa runkoa vasten ja polttaisi koko
  timeout-budjetin tehtävään jota ei ole. Poimintahaun `-label:epic` (M1) lukee saman *eventually
  consistent* -indeksin kuin `-is:blocked`, joten portti tarkistaa labelin **suoraan**
  (`gh issue view --json labels`, `lib/issue.sh:is_epic`) lukon jälkeen ja claimia ennen. **Fail-closed**:
  lukukelvoton labelilista tulkitaan epiciksi. Epic ⇒ `blocked/is_epic_not_runnable`,
  lukukelvoton ⇒ `blocked/epic_check_failed`, lukko vapautetaan, exit 12. **Ei `needs-human`-labelia**
  (claimia edeltävä portti kuten S2b). Nimetyn ajon voi pakottaa `--force`illa. Ks. epic-tason
  automaatio alla ja `docs/epic-orchestration.md`.

- **S1 PickIssue** vaatii **nimetyn issuenumeron** (#99). Orkestraattori ei enää poimi: poll-tila
  poistettiin (`poll`-argumentti ⇒ exit 1, koodi 2 poistui käytöstä), samoin
  `RUN_ISSUES_LABELS_CSV`. Koko paketissa on enää **yksi** poimintahaku — pollerin polku, joka
  delegoi `lib/issue.sh:pick_oldest_candidate`ille (ent. `pick_oldest_unassigned`), joten haku ja
  sen suodattimet elävät yhdessä paikassa (sama konvergointi kuin #91:ssä epicin lapsijoukolle).

- **S3 Claim** assignoi `@me`:n **ja** lisää `auto-claimed`-varauslabelin (#99). Varaus siirtyi
  assignaatiosta erilliseen, **vain automaation kirjoittamaan** labeliin, koska `claim_issue`
  assignoi saman tilin jolla ihminenkin assignoi — "ihmisen assignaatio" ja "runnerin varaus"
  eivät olleet erotettavissa. Poimintahaku suodattaa `-label:auto-claimed` (ei enää `no:assignee`),
  joten käsin assignattu issue lähtee ajoon. `verify_claim`in sääntö on nyt **"assignee-joukko
  claimin jälkeen == joukko ennen claimia ∪ {@me}"** (joukko snapshotataan S3:ssa ennen claimia):
  etukäteen tehty assignaatio ei kaada ajoa, mutta toisen tilin kilpaileva runner huomataan yhä
  (ylimääräinen login ⇒ perääntyminen, exit 3). Label sidotaan `claim_issue`/`unclaim_issue`iin
  rakenteellisesti (lisäys claimissa, poisto joka unclaim-polussa) + `cleanup-run.sh`in raakaan
  purkuun; **blocked/stalled-finalisoinnit eivät poista sitä** (`lib/run-terminate.sh`) — estynyt
  ajo pysyy varattuna siivoukseen asti, kuten assignaatio ennen. Best-effort: label-kirjoituksen
  häiriö ei kaada claimia (tmux-dedup + S2-lukko estävät kaksoisajon).

- **S4 Worktree** ratkaisee feature-haaran base-refin **arvaamatta**: eksplisiittinen
  `base_branch` → `<remote>/<base_branch>`, muuten `<remote>/HEAD`. Jos remotella on refit
  mutta ei symbolista HEADia (yleistä `git remote add`illa lisätyillä remoteilla, joilla
  `<remote>/HEAD` puuttuu) eikä `base_branch`ia ole annettu, ajo fail-fastaa
  `blocked/worktree_base_unresolved` -tilaan (exit 5) ennen worktreen luontia sen sijaan, että
  haarautuisi hiljaa paikalliseen HEADiin — situation-kommentti nimeää korjauskomennon
  `git remote set-head <remote> -a`. Paikallinen HEAD -fallback jää vain aidosti uudelle
  repolle ilman yhtään remote-refiä (#27).

  `create_worktree` **erottaa epäonnistumisen syyn paluukoodilla** (#34), jottei
  orkestraattori attribuoi kaikkia virheitä base-refin ratkeamattomuudeksi ja kehota
  ajamaan `git remote set-head`iä silloinkin kun se oli jo voimassa: `2` = base-ref ei
  ratkennut (yllä), `3` = **jäänne-haara** saman issuen edellisestä ajosta (suljettu PR
  `--delete-branch`illa poisti vain remote-haaran, paikallinen jäi) → situation-kommentti
  nimeää `cleanup-run.sh --repo <path> --issue <N>`, `4` = muu `git worktree add` -virhe
  (olemassa oleva worktree-hakemisto, levytila, oikeudet) → syytä ei arvata, kommentti
  osoittaa lokiin, jossa gitin oma virheviesti näkyy. Kaikki kolme finalisoidaan
  `blocked`-tilaan omalla syykoodillaan (`worktree_base_unresolved` /
  `worktree_leftover_branch` / `worktree_create_failed`) ja poistuvat koodilla 5.

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

**Terminaalisen eston merkintä (#43).** Claimin jälkeinen terminaalinen esto lisää issuelle
**aina** `needs-human`-labelin (`_add_needs_human_label`) situation-kommentin lisäksi:
`db_clone_failed`, `cycle_review_blocker`, `implementer_blocked`, `git_push_failed`,
`pr_create_failed`, `origin_fetch_failed`, `worktree_*`, `env_bootstrap_*`,
`provision_test_env_failed`, `clarification_loop_exhausted` sekä pollerin
`stalled_in_<vaihe>`. Pelkkä kommentti ei riitä: se ei ole suodatettava, joten pysyvästi
jumiin jäänyt ajo näytti GitHubissa samalta kuin normaali kesken oleva ajo (yksi hiljainen
esto pysäytti kuuden issuen riippuvuusketjun yön yli). Labelin elinkaari on valmis —
`cleanup-run.sh` poistaa sen.

**Poikkeus: claimia edeltävät portit eivät labeloi.** `blocked_by_dependency` ja
`blocked_check_failed` (S2b) poistuvat ennen claimia, issue ei ole assignattuna meille, ja
aito `blocked_by` jatkuu itsestään kun estäjä sulkeutuu — se on odotustila, ei ihmisen
tarve. Sama koskee `is_epic_not_runnable` / `epic_check_failed` -portteja (S2c, #81): epic ei
kuulu poimintaan lainkaan, joten sen kohdalla `needs-human` olisi väärä signaali. Sama koskee
S0-preflightiä (exit 8), joka poistuu ennen lukkoa.

**Blocked-ajon uusintayritys ihmiskommentilla (#57).** Jokainen yllä lueteltu terminaalinen
`blocked/*`-esto, joka postaa situation-kommentin, upottaa siihen `awaiting-answer`-markerin
(`build_marker`, sama koneisto kuin tarkennussilmukassa) ja **blocked-muotoisen vastausohjeen**
("kun este on poistettu, kommentoi — ajo yritetään uudelleen"). Tämä kattaa myös pollerin
stalled-finalisoinnin (`blocked/stalled_in_*`), jonka kommentti rakennetaan `finalize_stalled`issa
käsin mutta kantaa saman markerin. Kanava on `_post_situation_to_issue`in / `_hand_to_human`in
`awaitable`-argumentti: `0` (ei vastattava), `clarification` (tarkennussilmukka, jatkaa
`--continue`lla) tai `blocked` (uusintayritys). Timeout-polun (`timed_out`,
`timeout_budget_exhausted`) hand-off pysyy **ei-vastattavana** — se jatkuu `--restart`illa, ei
kommentilla.

Kun ihminen vastaa markerin jälkeen, pollerin **`scan_blocked_answered`** (poller.sh,
`scan_answered`in sisarfunktio: sama host/remote-portti, `parse_marker`+`detect_answer`)
tunnistaa tämän koneen avoimen blocked-ajon ja ajaa siihen `cleanup-run.sh --issue`n
(worktree, branch, run-dir, assignaatio, `auto-claimed`-varaus, `needs-human`-label, lukko —
**issueta ei suljeta**, toisin kuin `auto-clean.sh`). Siivottu issue täyttää normaalin
poimintahaun (`-label:auto-claimed`, #99) ja tulee poimituksi seuraavalla tikillä täytenä
uutena ajona tuoreesta basesta — ei vanhan
run-dirin jatkamista, koska blocked-ajon worktree on tyypillisesti haarautettu ennen esteen
poistanutta mergeä. Silmukkaraja on rakenteellinen ilman uutta laskuria: uudelleen blocked
päättyvä ajo postaa **uuden** markerin, ja `scan_blocked_answered` vaatii vastauksen uusimman
markerin jälkeen ⇒ yksi kommentti = korkeintaan yksi yritys. Suljettu issue tai markeriton
legacy-ajo ohitetaan hiljaa. `fetch_issue_json` palauttaa nyt myös issuen `state`n, jotta
avoimuustarkistus tehdään samasta hausta kuin markeri/vastaus.

**Epic-tason automaatio (#81).** `auto-run` epic-issuella on **propagointisignaali**, ei
ajosignaali: se tarkoittaa "aja tämä epic" = "lisää `auto-run` epicin avoimille alaissueille ja
anna pollerin ajaa ketju normaalisti S2b-järjestyksen varassa". Epic itse ei koskaan aja (M1
poissulku + S2c-portti). Koneisto on ohut kerros olemassa olevan riippuvuusajon *päällä* eikä aja
alaissueita itse — se **valmistelee** ne (`docs/epic-orchestration.md`, #80). Pollerin uusi
**`scan_epics`-vaihe** (poller.sh, ennen poimintaa jotta samalla tikillä propagoitu lapsi on heti
poimittavissa) hakee avoimet epicit (`is:open label:epic` + watchlistin ajolabelit,
`lib/epic.sh:epic_list_open`) ja ajaa kullekin `epic_process_one`in, joka on **best-effort ja
idempotentti** (aina rc 0 — yhden epicin GitHub-häiriö ei kaada tikkiä):

- **Propagointi** — lisää ajolabelit (`auto-run` + watchlistin vaatimat) epicin **avoimille**
  alaissueille joilta ne puuttuvat (`labels_add`, **lapsen omaan repoon**, #92). Ohittaa suljetut,
  jo-labeloidut ja `wip`-lapset (`wip` on ihmisen opt-out, ei uutta labelia). Lapsijoukko
  resolvoidaan **jaetulla** `lib/issue.sh:list_epic_children`illä (natiivit `sub_issues` kanoninen,
  rungon task-lista fallback vain kun natiiveja on nolla; **cross-repo-lapsi säilytetään sen omalla
  `owner/repo`lla** (#92), tila ratkaistaan kyseisen repon avoin-joukosta) — sama funktio, jota
  Ohjaamon V4-näkymä (`lib/status-github.sh`) **oikeasti kutsuu** (#91), joten näkymä ja ajo eivät
  voi olla eri mieltä epicin lapsista. TSV kantaa nyt `owner/repo`-sarakkeen
  (`<number>\t<state>\t<labels>\t<owner/repo>\t<title>`); `_epic_parse_child_line` palauttaa
  `REPLY_REPO`n.
- **Eskalaatio** — kun alaissue saa `needs-human`-labelin, epic-issuelle postataan **kerran per
  lapsi** tilannekommentti (piilomarker epicin kommenteissa vartioi kertaluonteisuuden, #65:n
  SKIP_CLOSED-vaimennuksen hengessä) + kevyt suodatettava `epic-attention`-label. Marker on
  saman repon lapselle historiallinen `<!-- run-issues:epic-attention child=<N> -->` (taaksepäin
  yhteensopiva) ja cross-repo-lapselle repo-tarkennettu `child=<owner/repo>#<N>` (#92: kaksi repoa
  voi jakaa issue-numeron eivätkä saa kuitata toistensa eskalaatioita); kommentti nimeää lapsen
  `owner/repo#N`-muodossa. Riippumattomat haarat jatkavat itsestään (S2b ajaa vain ne lapset,
  joiden estäjät ovat kiinni).
- **Valmius (elinkaari)** — kun **kaikki** alaissueet ovat suljettuja (repoista riippumatta, #92),
  epic saa **kerran** yhteenvetokommentin (listaa alaissueet `owner/repo#N`-muodossa cross-repo-
  lapsille + best-effort PR:t kunkin lapsen omasta repossa) ja `epic-complete`-labelin. **Runner
  ei sulje epiciä** — sulkupäätös jää ihmiselle (epicin runko voi sisältää hyväksyntäkriteereitä),
  ja GitHubin natiivi auto-close voittaa jos repo on niin konfiguroitu (avoin päätös F; #81:n cycle
  review pinnasi tämän additiivisen muodon: kommentti + label, ei sulkua). Idempotenssi: label tai
  completion-marker läsnä ⇒ ei toistoa.

Epic-labelit (`epic`, `epic-attention`, `epic-complete`) ovat **kiinteitä nimiä**, eivät
konfiguroitavia — sama päätös kuin `epic`-labelilla itsellään (`docs/epic-orchestration.md` §6).
`/run-epic`-komento (M6) toteutettiin #82:ssa (`run-epic.sh`, ks. §5 exit-koodit); epicin
**keskeytys** (`--stop`) toteutettiin #90:ssä samaan skriptiin: pysäyttää elävät lapsiajot
delegoimalla `stop-run.sh`:lle ja poistaa ajolabelit **ensin epiciltä, sitten avoimilta lapsilta**
(järjestys estää `scan_epics`in re-propagoinnin), plan-then-apply-jaolla; osittaisuus (vieras
kone / terminaalitila) erottuu täydestä exit-koodilla 6. Ks. §5 exit-koodit.

**Jatkomoodit:**

- `--restart <run-dir>` — jatkaa `timed_out`-ajoa ramppaavalla timeoutilla
  (`base * (1 + retry_count)`, katto `RUN_ISSUES_CLAUDE_TIMEOUT_MAX`). Ohittaa pick/claimin ja
  palaa vaiheeseen B. Budjetti `RUN_ISSUES_MAX_RETRIES`.
- `--continue <run-dir>` — jatkaa `awaiting_clarification`-ajoa sen jälkeen kun issueen on
  vastattu: ottaa lukon uudelleen, kasvattaa `clarification_round`ia ja ajaa S6:n uudelleen
  vastaus kontekstina. Silmukkakatto `RUN_ISSUES_MAX_CLARIFICATIONS`.

## 5. Exit-koodit

Jokaisella suoritettavalla skriptillä on **oma exit-koodiavaruutensa** — sama numero
tarkoittaa eri asiaa eri skripteissä. Lähde on kunkin skriptin otsikkokommentti;
`tests/test-readme.sh` johtaa README:n odotukset suoraan näistä, joten uusi koodi ilman
README-riviä on punainen testi.

### Orkestraattori (`orchestrate.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui — PR avattu, tai resume peruttiin siististi |
| 1 | Fataali — virheellinen käyttö / puuttuva `run.json` resumessa / `poll`-argumentti (#99: automaattinen poiminta on pollerin tehtävä; orkestraattori vaatii numeron). **Koodi 2 (ei ehdokasta, poll-tila) poistui käytöstä** — poll-tilaa ei enää ole |
| 3 | Lukko-/claim-kisa hävitty |
| 4 | Cycle review esti ajon (vain auto-tila) |
| 5 | Estynyt ennen implementeriä tai siinä — S4 worktreen luonti epäonnistui (`worktree_base_unresolved` base-ref ei ratkennut / `worktree_leftover_branch` jäänne-haara edellisestä ajosta / `worktree_create_failed` muu `git worktree add` -virhe, #34), db-clone, S7b tai S7c epäonnistui, tai implementer palautti BLOCKED |
| 6 | PR:n avaus epäonnistui |
| 7 | Implementer (S8) timeouttasi — ajo finalisoitu `timed_out`, kelpaa `--restart`iin |
| 8 | Puuttuva pakollinen riippuvuus — S0-preflight-portti pysäytti ajon ennen S1:tä (ei lukkoa, ei claimia, ei run-diriä); stderr-viesti nimeää korjauskomennon |
| 9 | Issue on estetty avoimella `blocked_by`-riippuvuudella — S2b-portti (#28) kieltäytyi lukon ja claimin välissä; ajo finalisoitu `blocked/blocked_by_dependency`, lukko vapautettu, ei claimia. Fail-closed (lukukelvoton graafi = esto). Nimetyn ajon voi pakottaa `--force`illa |
| 10 | Odottaa ihmisen katselmointia — jatka `--resume` |
| 11 | Odottaa tarkennusta — cycle review palautti NEEDS_CLARIFICATION; ajo finalisoitu `awaiting_clarification`, pollerin `scan_answered` jatkaa `--continue`lla |
| 12 | Issue kantaa `epic`-labelia — S2c-portti (#81) kieltäytyi lukon ja claimin välissä. Epic kokoaa ajettavat alaissueet mutta ei ole itse ajettava; ajo finalisoitu `blocked/is_epic_not_runnable` (tai `blocked/epic_check_failed` jos labelit lukukelvottomat), lukko vapautettu, ei claimia, **ei `needs-human`-labelia** (claimia edeltävä portti kuten S2b). Fail-closed. Nimetyn ajon voi pakottaa `--force`illa |

### Kokonaistila (`status.sh`, #59)

Oma avaruus, ei sekoiteta orkestraattorin koodeihin. Puhtaasti lukeva skripti, joten koodit
kertovat vain lukemisen onnistumisesta — ei mitään lukittua, claimattua tai luotua.

| Koodi | Merkitys |
|---|---|
| 0 | Luenta onnistui |
| 1 | Käyttövirhe (tuntematon lippu / kelvoton arvo) |
| 2 | Ei watchlistiä, ei yhtään levyllä olevaa repoa, tai `jq` puuttuu |
| 3 | Vajaa luenta — ≥1 `run.json` oli lukukelvoton/virheellinen; dokumentti silti validi ja täydellinen muun osan osalta (`degraded: true`), rikkinäiset polut `read_errors`-listassa. Kaksitasoinen luenta (bulk → per-file-fallback) eristää rikkinäisen, muut luetaan |

### Statussivun renderöinti (`status-render.sh`, #62, #76, #78, #79)

Oma avaruus. `status.sh`:n JSONin ensimmäinen kuluttaja: kirjoittaa `index.html`in ja
`status.json`in atomisesti (`RUN_ISSUES_STATUS_OUT_DIR`, oletus
`${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www`).

**#76 muutti `index.html`in kevyeksi selainsovellukseksi.** Ennen (#62) skripti renderöi
`jq`:lla staattisen, tumman insinööritaulukon suoraan datasta. Nyt `index.html` on **staattinen,
dataton runko** + inline-CSS + inline-JS: JS hakee `status.json`in (samasta hakemistosta)
`fetch`illä 60 s välein ja renderöi näkymän **selaimessa** — ryhmittely repoittain (kiireisin
ryhmä ensin: pahin luokka `stalled > attention > running > pr_in_flight > cleanup`, sitten
vanhin ikä), suodatinchipit (oletus: `attention`+`stalled`+`running` näkyvissä; `cleanup` näkyy
ryhmän hännässä yhteenvetorivinä myös piilotettuna), rivitason järjestysvalinta (ikä/repo/luokka),
suomenkieliset `class_reason`-selitteet + suositeltu seuraava askel, vaalea perusteema (tumma
`prefers-color-scheme: dark`illa), ja tuoreus/degraded/yhteysvirhe-tilat. **Keräyspuoleen
(`status.sh`, `status.json`-skeema) ei kosketa** — sama versioitu JSON, sama kenttäjoukko.

**Kenttävalkolista säilyy, mutta se on nyt kahden invariantin varassa** (ei enää renderöijän
`jq`-poiminnan): (1) `status.sh` kokoaa jokaisen `runs[]`-objektin **nimetyistä** kentistä
(repo-slug, issue-numero + URL, PR-URL, `class`/`class_reason`, iät, `current_state`, haara,
`blocked_reason`) eikä koskaan kopioi issuen otsikkoa/runkoa, lokeja, prompteja tai
absoluuttisia polkuja `runs[]`iin; (2) inline-JS lukee **vain** noita nimettyjä kenttiä ja
insertoi jokaisen datamerkkijonon `textContent`illä (**ei koskaan** `innerHTML`illä) eikä
itereoi run-objektia — joten `<script>`-niminen haara näkyy tekstinä eikä suoriudu, eikä
skeemaan myöhemmin lisätty kenttä vuoda sivulle. `status.json` kirjoitetaan yhä verbatim (kone
lukee sitä), ja se tarjoillaan samasta pääsynhallitusta hakemistosta kuin `index.html` (README
§7.8) — sama altistusraja kuin #62:ssa.

Sivun markup on dataton, joten se ei voi kaatua dataan; skripti silti portittaa
`schema_version`in (JS on kirjoitettu skeema-v1:n kenttänimille, väärän muotoinen dokumentti
tuottaisi hiljaa väärän sivun). Ilman `--input`ia skripti ajaa `status.sh --json`in itse
(LaunchAgent-polku); `status.sh`:n exit 3 (degraded) siedetään, muu ei-nolla ⇒ vanha sivu jää
paikoilleen. Altistuspäätös (Caddy-vhost, Tailscale-bind) ei kuulu pakettiin — vain
`examples/status-caddy.example`. Turvamalli: README §7.8. Vartija: `tests/test-status-render.sh`
(ml. `class_reason`-selitekartan kattavuus, `textContent`-todennus, ulkoisten resurssien
poissaolo).

**#78 toi gh-rikastuksen sivulle asti** ilman keräyspuolen skeemamuutosta. Renderöijän
`RUN_ISSUES_RENDER_GITHUB=1` ajaa LaunchAgent-polulla `status.sh --github`in (§7), jolloin
jokaisen ajon `github`-aliobjekti täyttyy (#60). JS lukee siitä **vain nimetyt** kentät osana
samaa valkolistaa: `github.issue_title` (rivin pääteksti — ilman rikastusta rivi näyttää V1:n
tapaan haaranimen alarivillä), sekä avoimen PR:n riveille `github.ci` (GREEN/RED/PENDING →
suomenkielinen CI-chip), `github.pr_decide_verdict` (→ "vahti mergeää seuraavalla tikillä" /
"odottaa CI:tä" / "ei auto-merge-labelia" jne., tuntematon koodi näkyy raakana) ja
`github.cache_age_seconds` (tuoreus). Chipit **vain** kun `github.pr_state == "OPEN"`.
**Provenienssi:** issue-otsikko elää *vain* `github.issue_title`ssä, ei ajon päätasolla —
`status.sh`:n keräyspuoli lisää sen `github`-aliobjektiin (`lib/status-github.sh`:n
`gh issue list --json number,title` **kerran per owner/repo** samaan TTL-cacheen kuin PR-lista,
best-effort: issue-haun virhe pudottaa vain otsikot, ei merkitse repoa `repos_failed`iksi).
**Otsikot sivulla nostavat altistusrimaa: sivu on pidettävä vain tailnetissä (README §7.8).**
Vartijat: `tests/test-status-github.sh` (otsikot + cache + provenienssi), `test-status-render.sh`
(RENDER_GITHUB-toggle, gh-kenttien valkolista, chip-sanamuodot), `test-status-schema.sh`
(ei päätason `issue_title`ia).

**#79 toi epic-rollupin näkymään** ilman `runs[]`-skeemamuutosta. `status.sh --github` emittoi
uuden top-level-listan `epics[]` (avoimet `epic`-labeloidut issuet + niiden alaissueet;
skeema alla). JS renderöi yhden epic-kaistan per epic sen **repo-ryhmän sisällä**: edistymispalkki
(suljetut/kaikki alaissueet), ajossa oleva alaissue korostettuna, jonossa olevat lista- eli
riippuvuusjärjestyksessä estäjineen ("jonossa · estäjä #N" = lähin edeltävä yhä avoin alaissue;
ensimmäinen ilman ajoa → "odottaa poimintaa"), ja suljetut alaissueet yliviivattuina
kuittausriveinä niin kauan kuin epic on auki. **Dedup:** alaissueen ajo näkyy **kerran** —
kaistalla, ei myös irtorivinä repo-ryhmässä (`epicMember`-joukko + `subKey`-liitos; **cross-repo
(#92):** liitos tehdään lapsen **omalla** `repo_slug`illa (`subSlug`), joten toisessa repossa oleva
alaissue liittyy sen repo-ryhmän ajoon ja siivoutuu sieltä; kaistalla se saa repo-tagin
(`epic-sub-repo`)). Epic ilman
avointa alaissuetta ja ilman elävää (ei-`cleanup`) ajoa **ei tuota kaistaa** — **poikkeus (#91):**
`source: "unreadable"` -epic tuottaa aina kaistan, joka näyttää otsikon + huomion "lapsijoukkoa ei
saatu luettua" edistymispalkin sijaan (ei koskaan hiljaa katoa, ei koskaan väärää edistymää
lukukelvottomasta graafista). Suljetun alaissueen
`cleanup`-ajo säilyy silti top-level `cleanup`-laskurissa (kuittausrivi ei poista sitä
siivousjonon lukumäärästä). Otsikot (epic + alaissue) kulkevat saman valkolistatun,
`textContent`-insertoidun polun kuin V3 (escapattu, vain tailnet). Sivu on yhä dataton runko —
`epics[]` haetaan `status.json`ista selaimessa. Vartijat: `tests/test-status-github.sh`
(epic-keräys: sub_issues-API + task-lista-fallback + cache), `test-status-render.sh` (epic-kaistan
kentät + sanamuodot + XSS-escape), `test-status-schema.sh` (`epics[]` tyhjä paikallisessa tilassa).

**`epics[]`-skeema (schema_version 1):** jokainen alkio on
`{repo_slug, epic_number, epic_title, epic_url, sub_issues: [{number, state, repo, repo_slug}], source}`,
missä `state` on `"open"|"closed"`; **cross-repo (#92):** `sub_issues[].repo` on lapsen oma
`owner/repo` (GitHub-johdettu, cachessa) ja `sub_issues[].repo_slug` sen paikallinen slug (status.sh
injektoi emit-hetkellä — sama repo kuin epicillä ⇒ epicin slug, cross-repo + paikallinen ajo ⇒ ajon
slug, muuten repo-basename; ei cachessa, koska slug on paikallinen käsite). `source` on `"sub_issues"` (natiivi sub-issues-rajapinta,
ensisijainen), `"task_list"` (rungon `- [ ] … #N` -fallback vanhoille epiceille) tai
`"unreadable"` (#91: jaetun `list_epic_children`in fail-closed-tila — natiivigraafi ei lukenut,
`sub_issues` on tyhjä eikä task-lista-fallbackiin pudota). Lista on `[]` ilman
`--github`-rikastusta, aivan kuten `github`-aliobjekti on `null`. `runs[]`-skeemaan ei kosketa
(#79/#91 scope-out).

**#105 toi runnerin versiotilan skeemaan** additiivisena top-level-objektina (kuten `epics[]`
#79): `schema_version` pysyy `1`:ssä, `runs[]` ei muutu. **`runner`-objekti (schema_version 1):**
`{version, behind_origin, pinned_version, update_state, pin_age_seconds}`, missä `version` on lyhyt
HEAD-sha (`"?"` git-tiedon puuttuessa), `behind_origin` committien määrä `origin/main`ista (`null`
kun tuntematon), `pinned_version` emo-repon pinni tälle työpuulle (`null` kun ei submodule =
oletusasennusmalli, `"?"` kun superprojekti lukukelvoton), `update_state` yksi neljästä
(`up_to_date`/`pin_pending`/`behind_upstream`/`unknown`) ja `pin_age_seconds` pinnatun commitin ikä
(`null` kun objekti ei ole paikallisesti). **Erona `epics[]`iin objekti emittoidaan `--github`ista
riippumatta** — tieto on paikallista git-metadataa (`lib/version.sh`, §6), ei GitHub-rikastusta, eikä
sen tuottaminen tee uutta verkkokutsua (`behind_origin` on yhtä tuore kuin viimeisin
`runner_fetch_throttled`). Fail-soft: ei-git-hakemistossa objekti on
`{version:"?", behind_origin:null, pinned_version:null, update_state:"unknown", pin_age_seconds:null}`,
ei tyhjää dokumenttia eikä ei-nolla-exitiä. `status-render.sh` näyttää tilan sivun yläosassa **vain
kun se ei ole `up_to_date`** (`pin_pending` neutraalina, ei varoituksena). Vartijat
`tests/test-status-schema.sh` (objekti + kentät + ei-git), `tests/test-status-render.sh`
(up_to_date⇒piilossa, pin_pending/behind_upstream⇒selitteet, `textContent`-insertointi).

| Koodi | Merkitys |
|---|---|
| 0 | Renderöity — molemmat tiedostot kirjoitettu atomisesti (temp + `mv -f`) |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva arvo) |
| 2 | Syöte kelvoton — `status.sh` ei tuottanut validia JSONia tai `schema_version` tuntematon; vanha sivu jää paikoilleen (ei ylikirjoiteta rikkinäisellä renderöinnillä) |
| 3 | Kirjoitus epäonnistui (levy täynnä / oikeudet); temp siivotaan, vanha sivu jää ehjäksi |

### Yksittäisen ajon pysäytys (`stop-run.sh`, #64)

Oma avaruus. Ohut operaattoripinta `lib/run-terminate.sh`:n `run_terminate`lle (#63): resolvoi
kohdeajon (`--run-dir <path>` **tai** `--repo <path> --issue <N> [--remote <name>]`), valvoo
turvaportit ja delegoi pysäytyksen syyllä `stopped_by_operator` ja contextilla `stopped` — **ei
toteuta lopetuslogiikkaa uudelleen**. Constraint 5 seuraa ilmaiseksi: `run_terminate` ei koske
worktreehen/haaraan/run-diriin, joten pysäytys on ei-destruktiivinen (purku jää
`cleanup-run.sh`ille / `auto-clean`-labelille). Ei `--all`ia eikä oletuskohdetta (constraint 1):
massapysäytys on koko orkestraattorin pysäyttäminen (`launchctl`), ei tämän. Host-portti on
**stop-runin oma** tarkistus (`run.json.host` vs `hostname -s`), koska `run_terminate` palauttaa
vieraalla hostilla hiljaa `0`, ei exit 4:ää — defense-in-depth säilyy. Terminaalitila-portti
(exit 5) käyttää samaa "vain live-ajo on stopattavissa ilman `--force`ia" -logiikkaa kuin
`cleanup-run.sh`:n `--force`: live-ajon status on aina `initialized` (S8 restart/continue
palauttaa sen), joten mikä tahansa muu status on finalisoitu ajo. Tilannekommentti haarautuu
`run_terminate`ssa contextin mukaan: `stopped` saa pysäytyssanaisen rungon **ilman**
awaiting-answer-markeria (scope-out: ei automaattista uudelleenkäynnistystä ⇒
`scan_blocked_answered` ei saa laueta), toisin kuin `stalled`. Vartija: `tests/test-stop-run.sh`.

| Koodi | Merkitys |
|---|---|
| 0 | Pysäytetty — tmux tapettu, ajo finalisoitu `blocked/stopped_by_operator`, `needs-human`-label + kommentti postattu, lukko purettu ajon omasta identiteetistä. Tai `--dry-run` tulosti suunnitelman kirjoittamatta mitään |
| 1 | Käyttövirhe (tuntematon lippu, puuttuva kohde, tai `--run-dir` yhdistettynä `--repo`/`--issue`/`--remote`iin) |
| 2 | Kohdetta ei löytynyt — `--run-dir`illä ei `run.json`ia (tai se osoittaa `run-issues-archive/`iin), tai `--repo`+`--issue`+`--remote` ei osunut yhteenkään ajoon |
| 3 | `--issue` osui useampaan ajoon (esim. kaksi remotea) — kieltäytyy arvaamasta, tarkenna `--run-dir`illä. Mitään ei tehty |
| 4 | Vieras host — `run.json.host` ≠ `hostname -s`; ajo kuuluu toiselle koneelle, mihinkään ei koskettu |
| 5 | Terminaalitila — ajon status ei ole `initialized`; `--force` pysäyttää silti (esim. `completed`-ajon elävän PR-kontekstin purkaminen vaatii tietoisen valinnan). Mihinkään ei koskettu |

### Epicin käynnistys ja keskeytys (`run-epic.sh`, #82 + #90)

Oma avaruus. `/run-epic`-slash-komennon taustaskripti: epicin eksplisiittinen käynnistys- ja
keskeytyspinta, symmetrinen `stop-run.sh`:n kanssa (ohut operaattoripinta, suunnittele–sovella
kuten `install.sh`).

**Käynnistys (#82, cross-repo #92).** Validoi epicin rakenteen **ennen mitään kirjoitusta** (avoin +
olemassa, ≥1 alaissue natiivi/task-lista, `blocked_by`-graafi syklitön). **Alaissueet saavat olla
eri repoissa (#92):** kunkin lapsen `blocked_by` luetaan sen omasta repossa ja ajolabelit
propagoidaan sinne. Lisää sitten `epic`-labelin jos puuttuu (idempotentti; `docs/epic-orchestration.md`
§5.2 avoin päätös I — muuntaa kokoavan issuen epiciksi) ja propagoi ajolabelit avoimille
alaissueille **jaetulla `propagate_run_labels`illa** (lib/epic.sh) — sama polku kuin pollerin
`scan_epics`illa, ei toista toteutusta (AC4). `--dry-run` tulostaa saman raportin (**lapset
repoittain**, ensimmäinen ajokelpoinen lapsi, estetyt + estäjät, ketjun pituus, ja **varoitus
lapsista joiden repo ei ole tämän koneen watchlistissä** — mikään paikallinen poller ei aja niitä,
#92) kirjoittamatta mitään; `--start-now`
käynnistää ensimmäisen ajokelpoisen lapsen heti (`orchestrate.sh`, `RUN_EPIC_ORCHESTRATE`
testien injektiopisteenä). Syklintarkistus on Kahnin algoritmi ilman assosiatiivisia taulukoita
(bash 3.2). Fail-closed: lukukelvoton lapsi-/estäjägraafi ⇒ exit 5, ei ajoa.

**Keskeytys (`--stop`, #90).** Symmetrinen käynnistyksen kanssa, sama plan-then-apply ja **sama
jaettu lapsijoukon resolvointi** (`list_epic_children`). Haarautuu launch-polusta **ennen**
`blocked_by`-graafia ja syklintarkistusta (joita pysäytys ei tarvitse). Kaksiosainen: (1)
**elävät lapsiajot** pysäytetään **delegoimalla** `stop-run.sh`:lle (`RUN_EPIC_STOP_RUN` testien
injektiopisteenä) — turvakriittistä lopetuslogiikkaa (tmux-tappo, `state_finalize`, lukonpurku)
**ei monisteta** (AC3); vieraan koneen ajoa ei kosketa (host-portti) eikä terminaalitilan ajoa
pakoteta; (2) **jonossa olevat** vapautetaan poistamalla ajolabelit `labels_remove`illa
(`labels_add`in sisar, AC2) **ensin epiciltä, sitten avoimilta lapsilta** — järjestys estää
`scan_epics`in re-propagoinnin. Ajot luokitellaan run-dirien `run.json`ista lukemalla (host +
status, read-only preview; `stop-run.sh` on gate-autoriteetti apply-hetkellä). `--dry-run` ei
kirjoita mitään. `--stop` + `--start-now` = käyttövirhe (exit 1). Osittainen onnistuminen
erottuu täydestä: exit 6 jos ≥1 elävää ajoa jäi pysäyttämättä. Ei siivoa
worktreetä/haaraa/run-diriä (ei cleanup). Vartija: `tests/test-run-epic.sh`.

Koodit 1/2/3/5 ovat yhteisiä molemmille moodeille; 4 on vain käynnistys, 6 vain `--stop`.

| Koodi | Merkitys |
|---|---|
| 0 | Käynnistys: validoitu + propagoitu. `--stop`: epic kokonaan pysäytetty (kaikki elävät lapsiajot pysäytetty, ajolabelit poistettu). Tai `--dry-run` tulosti suunnitelman |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva tai epäkelpo epic-numero / `--stop` yhdessä `--start-now`n kanssa) |
| 2 | Epic-issueta ei löytynyt tai se ei ole avoin — mitään ei luettu fetchin jälkeen |
| 3 | Epic ilman alaissueita (ei natiiveja, ei task-listaa) — ei propagoitavaa/pysäytettävää |
| 4 | Käynnistys: syklinen `blocked_by`-graafi alaissueiden välillä — sykli nimetään, ei kirjoituksia |
| 5 | Lukuvirhe — lapsijoukkoa tai jonkin lapsen `blocked_by`-graafia ei saatu luettua (fail-closed) |
| 6 | `--stop`: osittainen — epic vapautettiin mutta ≥1 elävää lapsiajoa ei voitu pysäyttää (vieras kone / terminaalitila ilman `--force`ia / moniselitteinen / delegoitu `stop-run.sh` epäonnistui). Muu käsiteltiin; täysi pysäytys on 0 |

### Ohjaamon toimintopalvelu (`action-server.sh`, #77)

Oma avaruus. Kääre omistaa elinkaaren ja delegoi socketin `lib/action-service.py`:lle
`exec`illä, joten **Pythonin exit-koodi on prosessin exit-koodi** — siksi koodit jakautuvat
siihen, mitä kääre päättää ennen `exec`iä (1/2) ja mitä palvelu päättää (0/3/4).

| Koodi | Merkitys |
|---|---|
| 0 | Puhdas exit — host-portti no-op, `--check` OK, tai palvelu pysähtyi SIGTERMiin |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | Puuttuva pakollinen riippuvuus (`python3` / `jq` / Tailscale-CLI) — ennen `exec`iä |
| 3 | Bind epäonnistui — ei Tailscale-osoitetta johon sitoa (ei koskaan wildcard), tai portti varattu. **launchd `KeepAlive` yrittää uudelleen** — tämä on boot-ennen-tailnetiä-toipuminen |
| 4 | Konfiguraatio kieltäytyy — ei sallittua identiteettiä, tokenia eikä originia (fail-closed) |

### Ohjaamon toiminnon delegointi (`action-dispatch.sh`, #77)

Oma avaruus. Ohut kuori: jokainen neljästä toiminnosta delegoi olemassa olevalle
skriptille/labelille eikä toteuta purku-/merge-/restart-logiikkaa itse.

| Koodi | Merkitys |
|---|---|
| 0 | Delegoitu komento onnistui |
| 1 | Käyttövirhe (tuntematon toiminto / puuttuva tai virheellinen selektori) |
| 2 | Delegoitu komento **epäonnistui** — sen tuloste on stdout/stderrissä sellaisenaan (turvamalli 5: näytä virhe, älä yritä itse) |
| 3 | Delegoitava puuttuu (skripti ei suoritettavissa, tmux puuttuu restartista) |

### Self-update (`self-update.sh`, #112)

Oma avaruus. Tikkaava LaunchAgent, joka pitää asennetun paketin ajan tasalla (§7.10 README): pull
(vain kehittäjäkoneella, vartioitu ff-only) + `install.sh --with-launchagents --quiet`. Pull on aina
fail-soft; asentajan refuse/conflict on NOTE. `tests/test-self-update.sh` vartioi vartiot,
idle-portin ja asennuskutsun; `tests/test-readme.sh` johtaa README-koodit otsikosta.

| Koodi | Merkitys |
|---|---|
| 0 | Tikki valmis, tai siististi ohitettu (idle-portti / kill-switch `RUN_ISSUES_SELF_UPDATE=0` / pull-vartio). Pull on aina fail-soft: verkkovirhe tai jäljessä oleva `main` on NOTE, ei virhe |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | Asennusvaihe epäonnistui odottamatta (asentajan exit ei ∈ {0,2,4}); lokitettu, seuraava tikki yrittää uudelleen. Asentajan oma refuse (2) / conflict (4) on NOTE eikä yllä tänne |

## 6. `lib/`-rakenne

| Tiedosto | Vastuu |
|---|---|
| `action-token.sh` | Ohjaamon toimintokanavan jaettu CSRF-token (#77): `action_token_ensure` luo idempotentisti 256-bittisen tokenin tiedostoon (mode 0600), `status-render.sh` ja `action-server.sh` konvergoivat samaan arvoon (create-if-absent-hardlink-kilpailu). Bearer-salaisuus — ei koskaan `status.json`iin, audit-lokiin eikä situation-kommenttiin. Puhtaita funktiomääritelmiä |
| `action-service.py` | **Ainoa Python-tiedosto.** Ohjaamon toimintopalvelun HTTP + auth -ydin (#77): `ThreadingHTTPServer`, `tailscale whois` fail-closed socket-peer-IP:stä (ei koskaan forwardattu header), kolmikerroksinen CSRF (Origin-valkolista + pakotettu preflight-header + jaettu token), audit-loki (avaa–append–sulje + kokorotaatio), ja `execve` `action-dispatch.sh`iin — **ei koskaan koske gh:hun/labeleihin/orkestraattoriin itse**. Python 3.9 stdlib |
| `claude-call.sh` | Yksittäisen orkestroidun askeleen claude-CLI-kutsu (timeout, lokitus, finalisointi) |
| `env-bootstrap.sh` | Pakettimanagerin tunnistus S7b:n fail-fast-asennusporttiin |
| `git-remote.sh` | Multi-remote-apurit: yksi klooni voi pollata useaa GitHub-orgia |
| `github-app-auth.sh` | Opt-in GitHub App -identiteetti orkestraattorille ja PR-vahdille |
| `gitignore.sh` | Pitää **kohderepon** `.gitignore`n ignoroimassa ajoaikaiset artefaktit |
| `hook-runner.sh` | Synkroninen commit, joka ajaa post-commit-hookit loppuun ennen paluuta |
| `issue-images.sh` | Issuen kuvien poiminta ja lataus, jotta agentit näkevät ne |
| `issue.sh` | GitHub-issue-operaatiot `gh`-CLI:n ympärillä (ml. `pick_oldest_candidate` paketin **ainoa** poimintahaku, ent. `pick_oldest_unassigned` — `no:assignee` → `-label:auto-claimed`, #99, pollerin delegoima; `claim_issue`/`unclaim_issue` assignoivat + lisäävät/poistavat `auto-claimed`-varauslabelin rakenteellisesti (`AUTO_CLAIMED_LABEL`, kiinteä nimi, vain automaation kirjoittama), `issue_assignees` snapshottaa assignee-joukon S3:ssa ja `verify_claim` tarkistaa "joukko claimin jälkeen == joukko ennen ∪ {@me}" (käsin assignattu issue ei kaada ajoa, kilpaileva toinen tili huomataan yhä), #99; `count_open_blockers`, S2b:n autoritatiivinen esto-luku dependencies-API:sta, #28; `list_blocked_by` saman graafin lukeva sisar joka palauttaa estäjien numerot+tilat `/run-epic`in syklintarkistukseen ja ajojärjestykseen, #82; `is_epic` S2c:n autoritatiivinen epic-luku ja `list_epic_children` epicin lapsijoukon **yksi jaettu resolvointi** natiivi→fallback, TSV `<number>\t<state>\t<labels>\t<owner/repo>\t<title>` — kaikki kuluttajat kutsuvat tätä, myös näkymä (`lib/status-github.sh`, #91), joten näkymä ja ajo eivät voi olla eri mieltä lapsijoukosta; fallback-tila autoritatiivinen avoimien issueiden joukosta (ei checkbox-arvaus), lähde (`sub_issues`/`task_list`) `--source-file`in kautta luettavissa, identiteetti kutsujan valinta `--gh-runner`illa (näkymä ajaa `gha_with_token`in läpi, ajo paljasta `gh`:ta), fail-closed rc 2 lukukelvottomasta natiivigraafista, #81/#91; **cross-repo (#92):** jokainen lapsi kantaa oman `owner/repo`nsa (natiivi `repository_url`ista, task-lista `owner/repo#N`-viittauksesta), cross-repo-lapsen tila ratkaistaan kyseisen repon avoin-joukosta (kerran per repo, fail-closed) — ei enää pudoteta pois; `count_open_blockers` laskee cross-repo-estäjän jo valmiiksi (pelkkä `.state`-suodatus, AC4); `build_marker`/`parse_marker`/`detect_answer` vastattaville kommenteille; `fetch_issue_json` palauttaa myös `state`n blocked-uusinnan avoimuustarkistukseen, #57) |
| `issue.test.sh` | `verify_claim`in yksikkötestit (S2/S3-kilpajuoksu) |
| `epic.sh` | Epic-tason auto-run-automaatio (#81): `epic_list_open` (avoimet epicit hakuna) ja `epic_process_one` (pollerin `scan_epics`-vaiheen entry) — ajolabelien idempotentti propagointi epicin avoimille alaissueille, `needs-human`-lapsen kertaluonteinen eskalaatio epiciin (per-child marker, #65-henki) ja valmiuden näkyväksi teko (yhteenvetokommentti + `epic-complete`-label, ei sulkua). Propagoinnin **yksi jaettu primitiivi** `_epic_propagate_child` (AC4, #82): sekä `epic_process_one` että julkinen `propagate_run_labels` (lapsijoukon resolvointi + propagointi, `/run-epic`in kirjoituspolku) kutsuvat sitä — ei kahta label-propagointitoteutusta. `_epic_parse_child_line` säilyttää `list_epic_children`in tyhjän label-sarakkeen (tab on IFS-whitespace ⇒ `IFS=$'\t' read` romahduttaisi sen) ja palauttaa `REPLY_REPO`n (lapsen `owner/repo`, #92) ⇒ propagointi/eskalaatio/valmius kohdistuvat lapsen omaan repoon; `_epic_child_ref`/`_epic_attn_marker` nimeävät cross-repo-lapsen `owner/repo#N`-muodossa ja repo-tarkennetulla markerilla (saman repon lapsi säilyttää vanhan `child=<N>`-muodon, taaksepäin yhteensopiva). Puhtaita funktioita, sourcaa omat riippuvuutensa (`issue.sh`/`labels.sh`); best-effort (aina rc 0). Vartijat `tests/test-epic.sh`, `tests/test-run-epic.sh` |
| `labels.sh` | Label-hallinta REST-API:n kautta (ei `gh issue edit --add-label`) |
| `locking.sh` | Issue-kohtainen lukkohakemisto, atominen `mkdir(2)`:lla |
| `poller-config.sh` | Pollerien host-portti ja watchlistin resolvointi puhtaina funktioina. Erillinen lib siksi, että molemmat pollerit tarvitsevat saman päätöksen ja se on testattava **sourcaamalla** — poller itse exittaa source-hetkellä vieraalla koneella |
| `log-rotate.sh` | Pollerien koon perusteella laukeava lokirotaatio (#65): `rotate_log_if_big` siirtää lokitiedoston `.1`:ksi rajan ylittyessä, yksi sukupolvi. Erillinen lib eikä `poller-config.sh`, jotta sen puhtausväite säilyy — tämä tekee levykirjoituksen (`mv`). Sourcetaan **ennen** pollerin `exec`-uudelleenohjausta, koska jo avatun fd:n tiedoston siirto olisi no-op |
| `pr-watch-lib.sh` | PR:n luokittelu- ja merge-päätöslogiikka (irrotettu testattavaksi). Ml. `pr_last_decision` (#65): lukee state.jsonlin **hännästä** viimeisimmän `pr_classified`-päätöksen, jotta `pr-watch.sh` osaa vaieta toistuvan `SKIP_CLOSED`-tapahtumatrion |
| `preflight.sh` | Jaettu ulkoisten riippuvuuksien tarkistus. Puhtaat funktiot, vakavuus paluukoodissa: `install.sh` käyttää neuvoa-antavasti, orkestraattorin S0-portti (#7) tekee samasta lähteestä fataalin (exit 8). Korjauskomennot tulevat yhdestä lähteestä (`preflight_install_hint`) |
| `render-prompt.test.sh` | `render_prompt`in yksikkötestit (rekursiivinen sijoitus) |
| `run-terminate.sh` | Elävän ajon turvallinen lopetus kutsuttavana funktiona (#63): `run_terminate <run-dir> <reason-slug> [<context>]` — host-portti, eksakti tmux-tappo, `state_finalize`+`state_event`, best-effort `needs-human`-label + tilannekommentti, lukon purku ajon **omasta** tallennetusta identiteetistä (`repo_slug`+`remote`, #67). Irrotettu `poller.sh:finalize_stalled`in rungosta, joka `exit 0`si source-hetkellä vieraalla koneella eikä siksi ollut kutsuttavissa muualta; `stop-run.sh` (#64) käyttää samaa polkua monistamatta turvakriittistä logiikkaa. Puhtaasti funktiomääritelmiä, sourcetaan turvallisesti (sourcaa omat riippuvuutensa). Loki `_run_terminate_log`illa (`declare -F log` → `$LOG` → stderr). Tilannekommentti haarautuu `context`in mukaan (#64): `stalled` kantaa awaiting-answer-markerin (`scan_blocked_answered` uusii ajon vastauksella, #57), `stopped` **ei** kanna markeria (scope-out: ei automaattista uudelleenkäynnistystä) ja osoittaa siivoukseen. `finalize_stalled` on nyt ohut kutsuja joka välittää `stalled_in_<current_state>`; vartija `tests/test-poller-stale-detection.sh` (muuttumaton) + `tests/test-run-terminate.sh` |
| `state.sh` | Ajon durable-tila `<run-dir>`-hakemistossa |
| `status-read.sh` | `status.sh`:n puhtaat luku- ja luokittelufunktiot (#59): `_STATUS_NORMALIZE_JQ` (heterogeenisen `run.json`in normalisointi + `schema_gaps`), `status_read_bulk`/`status_read_perfile` (kaksitasoinen luenta), `_STATUS_CLASSIFY_JQ` + `status_classify` (viisi luokkaa prioriteettijärjestyksessä, INV-STATUS lukee vain `status`ia, INV-UNKNOWN fail-closed), `_STATUS_GITHUB_RECLASSIFY_JQ` (`_github_reclassify`, #60: `--github`-rikastuksen jälkeen ajettava jälkiluokittelu — no-op kun `github == null`, muuten nostaa `class_confidence`in `low`→`high` varmistuneelle PR:lle ja lisää `pr_ci_red`/`pr_changes_requested`/`pr_draft_stale`/`pr_not_open`-refinoinnit sekä PR:ttömän ajon `issue_closed`-refinoinnin, #96: `pr_state` null + varmistettu `issue_state == "CLOSED"` → `cleanup/issue_closed/high`, jotta suljetun issuen PR:tön ajo ei jää `attention`iin), ja `_iso_to_epoch` (siirretty poller.sh:sta; poller sourcaa sen täältä, jotta `scan_stalled`in liveness-kello ja `status.sh`:n `idle_seconds` lasketaan identtisesti) |
| `status-github.sh` | `status.sh --github`-rikastuksen opt-in-moduuli (#60, #78, #79): avoimet PR:t `gh pr list`illä **kerran per owner/repo** TTL-cachella, `github`-aliobjektin rakennus per PR (`status_github_pr_object`/`status_github_build_pr_map`), cache-primitiivit (`status_github_cache_file`/`status_github_load_cache`/`status_github_write_cache`, atominen `mktemp`+`mv -f` kuten `lib/state.sh`), verkkokutsu (`status_github_fetch_open_prs` `gha_with_token`in kautta) ja `NOT_OPEN`-objekti (`status_github_not_open_object`, `--github-full` erottaa `MERGED`/`CLOSED`in `status_github_closed_state`illä). **Ei omaa CI-rollupia eikä merge-päätöstä**: `ci` = `pr_ci_state`, `pr_decide_verdict` = `pr_decide` (`lib/pr-watch-lib.sh`), samalla `--json`-kenttäjoukolla kuin PR-vahti. Fail-soft: repon verkkovirhe → `repos_failed`, ei kaada tulostetta. **#78:** issue-otsikot (`status_github_fetch_open_issues` `gh issue list --json number,title`, `status_github_build_issue_map` number→title) samaan per-owner TTL-cacheen; `status.sh` injektoi otsikon jokaisen ajon `github.issue_title`ksi issue-numerolla (myös ei-PR-ajoille `status_github_issue_only_object`illa, jolloin rivi saa otsikon mutta ei chippejä). Issue-haku on best-effort: virhe pudottaa vain otsikot, ei merkitse repoa `repos_failed`iksi (PR-haku on primäärinen ja omistaa `repos_failed`in). **#79 + #91:** epic-jäsenyys (`status_github_fetch_epics` `gh issue list --label epic --state open --json number,title,body`, `status_github_build_epics` koostaa) samaan per-owner TTL-cacheen **täysin resolvoituna** (cache-osuma ei tee yhtään gh/api-kutsua). **#91: lapsijoukon resolvointi ei ole enää oma** — `status_github_build_epics` kutsuu **jaettua** `lib/issue.sh:list_epic_children`iä (`--gh-runner gha_with_token` säilyttää App-identiteetin, `--body`+`--open-map` estävät lisäkutsun per epic), eikä moduuli enää kutsu `/sub_issues`-endpointtia tai jäsennä task-listaa itse (poistetut `status_github_fetch_sub_issues`/`status_github_parse_task_list`). Task-listan tila resolvoidaan avoimien issueiden karttaa vasten jaetussa funktiossa (kartassa → `open`, ei-kartassa+ruksi → `closed`, ei-kartassa+tyhjä → ohitetaan). **Fail-closed:** lukukelvoton natiivigraafi (rc 2) ⇒ epic saa `source: "unreadable"` + tyhjä `sub_issues`, ei pudota task-lista-fallbackiin. `status.sh` injektoi `repo_slug`in (ajojen efektiivinen slug) ja emittoi top-level `epics[]`in; best-effort, ei omista `repos_failed`ia **#96 + #103:** avointen kartasta puuttuvan issuen detail-luku (`status_github_issue_detail`, ent. `status_github_issue_state`, `gh issue view --json state,stateReason,title`, malli `status_github_closed_state`:sta): yksi kutsu palauttaa tilan **ja** suljetun issuen `stateReason`in + otsikon (avoin lista on `--state open`, joten suljetun otsikko ei ole muualla), upper-cased + fail-soft tyhjä. **#103** laajensi luvun PR:ttömistä ajoista **kaikkiin** ajoihin (kartasta puuttuva issue, deduplattu ⇒ rajattu erillisten suljettujen issueiden määrään, ei lineaarinen ajoissa). `status.sh` rakentaa yhden per-owner **issue-meta-kartan** (avoin lista → `{state:OPEN, reason:null, title}`; detail-luvut → `{state, reason, title}`) ja liittää `github.issue_title` + `github.issue_state` + `github.issue_state_reason` **jokaiseen** github-objektiin (avoin PR, NOT_OPEN, issue-only). Luokittelu ennallaan (avoin PR voittaa yhä `_github_reclassify`ssä ⇒ issue_state PR-rivillä on vain näkymää varten; #96 omistaa `cleanup/issue_closed`in). Cachetettu samaan per-owner TTL-entryyn `issue_details`-avaimena; **cache-entry josta avain puuttuu käsitellään vanhentuneena** (ei tyhjänä — estää #96:n hiljaisen no-opin legacy-entryllä). Renderöijä näyttää suljetun issuen chipin, joka erottaa `NOT_PLANNED`in (`Issue suljettu · ei suunniteltu`) `COMPLETED`ista |
| `version.sh` | Ajossa olevan runner-version näkyväksi teko (#32): `runner_version` (lyhyt HEAD), `runner_behind_origin` (jäljessä `origin/main`ia), `runner_version_summary` (raporttirivi) ja `runner_fetch_throttled` (throttlattu `git fetch`). Fail-soft: puuttuva `.git`/verkko ⇒ `?`. Pollerit lokittavat tikin alussa, `orchestrate.sh --version` ja situation-kommentin `Runner-version:` lukevat samasta lähteestä. **#105:** submodule-pinnin näkyväksi teko Ohjaamoon: `_runner_pinned_full`/`runner_pinned_version` (emo-repon pinni tälle työpuulle, `git rev-parse --show-superproject-working-tree` → `HEAD:<rel>`; tyhjä kun ei submodule = oletusasennusmalli, `?` kun superprojekti lukukelvoton; dotfiles-polkua **ei kovakoodata**), `runner_update_state` (yksi neljästä — `up_to_date`/`pin_pending`/`behind_upstream`/`unknown` — johdettu olemassa olevista paloista, ei uutta verkkokutsua; pinni-vertailu **täysillä shoilla** eikä objektia tarvita) ja `runner_pin_commit_epoch` (pinnatun commitin ikä, `""` kun objekti ei ole paikallisesti). Vartija `tests/test-version.sh` |
| `worktree.sh` | Ajokohtaiset git-worktreet kohderepossa |

## 7. Ympäristömuuttujat

### Orkestraattori

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_AUTO` | `0` | `1` = ei interaktiivisia kehotteita |
| `RUN_ISSUES_REVIEW_GATE` | `interactive` (`auto` jos `RUN_ISSUES_AUTO=1`) | S7-portin tila |
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
| `RUN_ISSUES_SKIP_PREFLIGHT` | `0` | `1` = ohita S0-portti. Hätävara: portti ei saa koskaan olla syy siihen, ettei ajo käynnisty toimivalla koneella |

### Poller

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_POLLER_ENV_FILE` | `$HOME/.config/run-issues/poller.env` | Konekohtaisen konfiguraation tiedosto |
| `RUN_ISSUES_POLLER_HOSTS` | *(sisäänrakennettu legacy-lista, ks. §12)* | Pilkuin/välilyönnein eroteltuja glob-kuvioita, verrataan `hostname -s`:ään. `*` sallii kaikki. Ei osumaa ⇒ poller exittaa 0 luomatta mitään |
| `RUN_ISSUES_WATCHLIST` | *(tyhjä)* | Watchlistin polku. Asetettuna se on **ainoa** ehdokas — osumaton override on virhe, ei fallback |
| `RUN_ISSUES_LOG_DIR` | `$HOME/Library/Logs` | Kaikkien neljän lokitiedoston hakemisto per poller (`.log`, `.runs.log`, `.stdout.log`, `.stderr.log`) |
| `RUN_ISSUES_LOG_MAX_BYTES` | `10485760` (10 MB) | Lokirotaation raja (#65). Tikin alussa, ennen ensimmäistä kirjoitusta ja **ennen** `exec`-uudelleenohjausta, molemmat pollerit rotatoivat jokaisen neljästä lokistaan (`mv` → `.1`, yksi sukupolvi) jos koko ylittää rajan. `0` = rotaatio pois päältä. `mv` samalla levyllä on atominen, joten rinnakkainen lukija näkee aina ehjän vanhan tai uuden tiedoston |
| `RUN_ISSUES_HOME` | *(pollerin oma `SCRIPT_DIR`)* | **Testien injektiopiste**, ei käyttäjäkonfiguraatio. Luetaan vain ympäristöstä |
| `RUN_ISSUES_STALE_AFTER` | `3600` | Liveness-raja: vanhempi ajo tapetaan ja finalisoidaan `blocked/stalled_in_<state>`. **Täytyy** ylittää pisin laillinen yksivaiheinen claude-kutsu |
| `RUN_ISSUES_CLEAN_LABEL` | `auto-clean` | Label, joka laukaisee `auto-clean.sh`:n |
| `PR_WATCH_GLOBAL_MAX` | *(watchlistin `pr_watch_max_concurrent`, tai sen puuttuessa `global_max_concurrent`)* | **Vain `pr-watch-poller.sh`.** PR-vahdin oma rinnakkaisuuskatto (#47). PR-skannaus on sekuntien työ, joten se voi käydä selvästi korkeammalla katolla kuin kymmenien minuuttien orkestraattoriajot ilman että `poller.sh`:n rinnakkaisuus kasvaa. Ympäristömuuttuja voittaa watchlist-avaimen |

Watchlistin resolvointijärjestys ilman overridea: `$HOME/.config/run-issues/watchlist.json` →
`$HOME/dotfiles/machine-studio/run-issues-watchlist.json`. Jälkimmäinen on **vain fallback**
(ks. §12); ensisijainen polku ei koskaan ole dotfiles-puu.

**PR-vahdin rotaatiokursori (#47).** `pr-watch-poller.sh` iteroi watchlistiä
rotaatiokursorilla: se muistaa mihin repoon jäi ja jatkaa seuraavalla tikillä siitä eteenpäin
kiertäen listan ympäri, jotta jokainen repo pääsee vuoroon `ceil(N / PR_WATCH_MAX)` tikin
sisällä. Ilman kursoria iterointi alkoi joka tikki indeksistä 0 ja katkesi kattoon — koska
skannaukset ovat lyhyitä, vain listan `PR_WATCH_MAX` ensimmäistä repoa käytiin koskaan ja hännän
auto-merge-PR:t jäivät ikuisesti auki ilman virhettä missään. Kursorin tila on yksi rivi
(jatkorepon polku, ei indeksi) tiedostossa `$RUN_ISSUES_LOG_DIR/.pr-watch-cursor`; polkuun
sidottuna se kestää watchlistin muokkauksen (muualta lisätty/poistettu entry ei siirrä
jatkokohtaa) ja puuttuva/korruptoitunut tiedosto vain aloittaa alusta. `poller.sh` **ei** käytä
kursoria — sen pitkät ajot varaavat slotit yli tikkien, joten se ei kärsi samasta
nälkiintymisestä. `tests/test-pr-watch-poller-rotation.sh` vartioi rotaatiota, kattoa ja
kursorin kestävyyttä.

**Toimituskanava.** launchd ei anna agentille omaa ympäristöä, eivätkä login-tiedostot sisällä
mitään run-issues-kohtaista, joten LaunchAgent-ajossa — ainoassa tuotantotilassa —
`poller.env` on ainoa kanava, jolla kone voi konfiguroida pollerinsa. Se **sourcetaan**, joten
**tiedosto voittaa ympäristömuuttujan**. Poikkeuksia kaksi, molemmat rakenteellisia:
`RUN_ISSUES_HOME` ja `RUN_ISSUES_POLLER_ENV_FILE` resolvoidaan ennen sourcea, joten ne
luetaan vain ympäristöstä. Malli: `examples/run-issues-poller.env.example`.
**`status-render.sh` sourceaa saman `poller.env`in (#78)**, koska se on samanlainen
LaunchAgent samassa ympäristöttömyydessä: yksi konekohtainen tiedosto konfiguroi kaikki
LaunchAgentit, ja `RUN_ISSUES_RENDER_GITHUB` luetaan sitä kautta LaunchAgent-polulla.
`tests/test-poller-config.sh` case 9 laskee siksi myös `status-render.sh`:n poller.env-lukijaksi.
**`self-update.sh` sourceaa saman `poller.env`in samasta syystä (#112)**: sieltä se lukee
`RUN_ISSUES_SELF_UPDATE`-kill-switchin ja jaetut loki-/rotaatiomuuttujat.

**Pollerit eivät lue `$HOME/.config/run-issues/env`-tiedostoa.** Se sisältää salaisuuksia,
jotka `orchestrate.sh` ja `pr-watch.sh` sourceavat itse. Poller ei tarvitse niistä yhtäkään ja
lokittaa runsaasti, joten salaisuudet pidetään sen prosessin ulkopuolella.
`tests/test-poller-config.sh` vartioi tätä.

### Self-update (`self-update.sh`, #112)

LaunchAgent (StartInterval 3600), joka pitää asennetun paketin ajan tasalla: kehittäjäkoneella
vartioitu `git pull --ff-only` + `install.sh`, ylläpitäjän submodule-koneella vain `install.sh`
(pull ohitetaan aina, §4/§11). Ei host-porttia — opt-in on agentin bootstrap. Sourceaa saman
`poller.env`in kuin pollerit. Ohjaa oman stdout/stderrinsä `run-issues-self-update.{stdout,stderr}.log`iin
ja rotatoi kolme lokiaan `RUN_ISSUES_LOG_MAX_BYTES`illa (ennen `exec`-uudelleenohjausta, §6
`lib/log-rotate.sh`).

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_SELF_UPDATE` | `1` | `0` = ohita tikki (kill-switch). Luetaan `poller.env`istä |
| `RUN_ISSUES_SELF_UPDATE_INSTALL` | *(pakettijuuren `install.sh`)* | **Testien injektiopiste** asennusvaiheen kutsulle, `RUN_EPIC_ORCHESTRATE`-mallin mukaan. Ei käyttäjäkonfiguraatio |
| `RUN_ISSUES_HOME` | *(scriptin oma `SCRIPT_DIR`)* | Pakettijuuri, johon git-operaatiot, versiorivi ja asennusvaihe kohdistuvat. Testien injektiopiste, luetaan vain ympäristöstä |
| `RUN_ISSUES_WATCHLIST` | *(tyhjä)* | Idle-portin lukema watchlist (sama resolvointi kuin pollerilla). Elävä ajo (`run.json` `initialized`, host == tämä kone) jossain watchlistin repossa ⇒ koko tikki ohitetaan |
| `RUN_ISSUES_LOG_DIR`, `RUN_ISSUES_LOG_MAX_BYTES`, `RUN_ISSUES_POLLER_ENV_FILE`, `RUN_ISSUES_LAUNCH_AGENTS_DIR` | *(kuten pollerit / asennin)* | Lokihakemisto + rotaatioraja, poller.env-polku, ja LaunchAgent-hakemisto uuden plistin havaitsemiseen (bootstrap-NOTE) |

### Kokonaistila (`status.sh`, #59)

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_WATCHLIST` | *(tyhjä)* | Watchlistin override. **Sama semantiikka kuin pollerilla:** asetettuna se on ainoa ehdokas — osumaton override on virhe (exit 2), ei fallback. Ilman overridea sama resolvointijärjestys kuin pollereilla (`poller_resolve_watchlist`) |
| `RUN_ISSUES_STALE_AFTER` | `3600` | Jumiutumisraja `idle_seconds`-vertailulle ja `running`/`stalled`-luokittelulle. **Sama muuttuja kuin pollerilla tarkoituksella:** näkymä ja poller eivät saa olla eri mieltä jumiudesta. `--stale-after` ohittaa |
| `RUN_ISSUES_STATUS_TAIL_LINES` | `40` | Montako riviä `state.jsonl`in **hännästä** luetaan per ajo (`pr_local_verdict` + `idle_seconds`). Tiedostoa ei lueta koskaan kokonaan (mitattu reunaehto: `state.jsonl` on 345 MB / 99,7 % PR-vahtikohinaa) — vain `tail -n N` |
| `RUN_ISSUES_STATUS_CACHE_FILE` | `${XDG_CACHE_HOME:-$HOME/Library/Caches}/run-issues/status-github.json` | **Vain `--github` (#60).** GitHub-rikastuksen TTL-cache, avaimena owner/repo. Atominen kirjoitus (`mktemp`+`mv -f`) |
| `RUN_ISSUES_STATUS_CACHE_TTL` | `300` | **Vain `--github`.** Cachen tuoreusikkuna sekunteina. `--cache-ttl <s>` ohittaa, `--no-cache` pakottaa haun |
| `RUN_ISSUES_HOME` | *(scriptin oma hakemisto)* | Testien injektiopiste, luetaan vain ympäristöstä |

`--github` lukee myös PR-vahdin togglet (`PR_WATCH_ENABLE_CONFLICT_RESOLUTION`,
`PR_WATCH_ENABLE_CI_REPAIR`, `PR_WATCH_MERGE_LABEL`) päättääkseen `pr_decide_verdict`in — oletus
`1`/`1`/`auto-merge` (sama kuin pollerit, jotka näitä repoja oikeasti hoitavat), jotta verdict
kertoo mitä vahti **tekisi juuri nyt**. GitHub App -identiteetti kunnioitetaan jos konfiguroitu
(`gha_with_token`, §8, GitHub App -env).

### Kooste (`status-digest.sh`, #61)

Kaikki valinnaisia; `examples/status-digest.env.example` dokumentoi ne. Flag voittaa
env-muuttujan, joka voittaa oletuksen. Env-tiedosto sourcetaan **ensin** (kuten `poller.env`),
joten sen arvot ovat oletuksia joita lippu yhä ohittaa.

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_DIGEST_ENV_FILE` | `$HOME/.config/run-issues/digest.env` | Ensin sourcettava konfiguraatiotiedosto. Puuttuva = oletukset. **Ei salaisuuksia** — `gws` kantaa omat tunnisteensa |
| `RUN_ISSUES_DIGEST_TO` | *(tyhjä)* | Vastaanottaja(t), pilkuin. `--to` ohittaa. Tyhjä (eikä `--to`) ⇒ runko stdoutiin |
| `RUN_ISSUES_DIGEST_MAX_SILENCE` | `7` | Hiljaisuusraja vuorokausina: muuttumatonkin tilanne lähetetään tämän jälkeen (hiljaisuus ≠ rikki). `--max-silence` ohittaa; `0` poistaa heartbeatin. Mitataan aina aiempaa lähetystä/baselinea vasten (epoch 0 = ensiajo ≠ ylitys) |
| `RUN_ISSUES_DIGEST_MIN_CLASS` | `stalled` | Alin mukaan otettava luokka: `attention` (vain ihmistä vaativat) tai `stalled` (attention + jumittuneet/orvot). `--min-class` ohittaa |
| `RUN_ISSUES_DIGEST_MAX_ROWS` | `10` | Rivikatto per `class_reason`-ryhmä ennen "…ja M muuta" |
| `RUN_ISSUES_DIGEST_SUBJECT_PREFIX` | `run-issues -kooste` | Otsikon etuliite |
| `RUN_ISSUES_DIGEST_GWS` | `gws` | Lähetyskomento. Testien injektiopiste (osoita olemattomaan ⇒ stdout-polku) |
| `RUN_ISSUES_DIGEST_STATE_FILE` | `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/last-digest.sha` | Sormenjälkitiedosto. Rivi 1 = sha256, rivi 2 = viimeisin lähetys-epoch. Kirjoitetaan atomisesti (`mktemp` + `mv -f`) |

### Statussivun renderöinti (`status-render.sh`, #62, #78)

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_STATUS_OUT_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www` | Hakemisto, johon `index.html` ja `status.json` kirjoitetaan. `--out-dir` ohittaa |
| `RUN_ISSUES_RENDER_GITHUB` | `0` | **#78.** `1` = LaunchAgent-polku (ilman `--input`ia) ajaa `status.sh --github`in, jolloin sivulle tulee issue-otsikot (`github.issue_title` rivin pääteksti) ja CI/mergevalmius-chipit avoimen PR:n riveille. Fail-soft: jos `--github`-ajo epäonnistuu kokonaan (exit ≠ 0/3), skripti putoaa paikalliseen luentaan ja renderöi V1-sivun. `status.sh --github` on itsekin fail-soft (repon verkkovirhe → `repos_failed`, ei kaada), joten fallback on varajärjestely. `0` = pelkkä paikallinen luenta, bitilleen kuin ennen #78:aa. Vaikuttaa vain no-`--input`-polkuun. **Otsikot sivulla → sivua ei saa altistaa julkisesti (README §7.8).** Asennusesimerkissä (`examples/run-issues-poller.env.example`) oletukseksi `1` |
| `RUN_ISSUES_LOG_DIR` | `$HOME/Library/Logs` | Skripti ohjaa oman stdout/stderrinsä `status-render.stdout.log`/`.stderr.log`-tiedostoihin täältä, kun ei aja TTY:llä (plistissä ei loki-avaimia, §11) |
| `RUN_ISSUES_HOME` | *(scriptin oma hakemisto)* | Testien injektiopiste; myös `status.sh`:n sijainti LaunchAgent-polulla (ilman `--input`ia) |
| `RUN_ISSUES_ACTION_BASE` | *(tyhjä)* | **#77.** Toimintopalvelun URL selaimen näkökulmasta (esim. `http://studio:8081`). Asetettuna `status-render.sh` upottaa sivulle base-URLin + jaetun tokenin (`<meta>`) ja renderöi neljä toimintonappia; JS POSTaa palveluun. **Tyhjä = puhdas V1-lukupinta, ei nappeja** (koko V2 opt-in). Token vain `index.html`iin, ei koskaan `status.json`iin |

### Ohjaamon toimintopalvelu (`action-server.sh`, `action-dispatch.sh`, #77)

Tailnetiin sidottu HTTP-toimintopalvelu, joka delegoi neljä Ohjaamo-nappia olemassa oleville
skripteille/labeleille. `action-server.sh` (bash) omistaa elinkaaren; `lib/action-service.py`
(Python-stdlib) omistaa socketin + autentikoinnin; `action-dispatch.sh` (bash) delegoi. **Sama
host-portti ja lokirotaatio kuin pollereilla** (§7 poller-taulukko); `poller.env` on sama
konfiguraatiokanava (LaunchAgent-ympäristöttömyys).

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_ACTION_HOSTS` | *(legacy-lista, kuten pollerit)* | Host-portti, sama muoto ja semantiikka kuin `RUN_ISSUES_POLLER_HOSTS`. Ei osumaa ⇒ palvelu exittaa 0 luomatta mitään |
| `RUN_ISSUES_ACTION_BIND` | `tailscale ip -4` ensimmäinen | Bind-osoite. **Ei koskaan wildcard**: jos tyhjä eikä Tailscale-osoitetta ratkea ⇒ exit 3 (launchd yrittää uudelleen — boot-ennen-tailnetiä-toipuminen). Testit asettavat `127.0.0.1` |
| `RUN_ISSUES_ACTION_PORT` | `8081` | Kuunneltava portti (8080 on Caddyn) |
| `RUN_ISSUES_ACTION_ALLOWED_USERS` | *(tämän noden oma tailnet-omistaja)* | Sallittujen LoginName-lista (CSV). Oletus resolvoidaan `tailscale status --json`illa. **Luottamusraja on tailnet-käyttäjä, ei laite** — myös puhelin/läppäri läpäisee (haluttu). Tyhjä ⇒ fail-closed exit 4 |
| `RUN_ISSUES_ACTION_ORIGIN` | `http://<bind>:8080` | Sallittujen Origin-headerien valkolista (CSV). CSRF-kerros 1 |
| `RUN_ISSUES_ACTION_TOKEN_FILE` | `$HOME/.config/run-issues/action-token` | Jaettu token (`lib/action-token.sh`, mode 0600). CSRF-kerros 3 |
| `RUN_ISSUES_TAILSCALE_BIN` | *(resolvoidaan)* | Tailscale-CLI:n polku: env → `command -v` → app-nippu → brew. Ei raakaa LocalAPI:a (standalone-variantilla ei socketia). Testien shim-piste |
| `RUN_ISSUES_ACTION_PYTHON` | `python3` | Python-tulkin ohitus |
| `RUN_ISSUES_LOG_DIR`, `RUN_ISSUES_LOG_MAX_BYTES` | *(kuten pollerit)* | Palvelun stdout/stderr + audit-loki (`run-issues-action.audit.log`) tänne; rotaatio samalla rajalla. Audit-loki rotatoidaan **avaa–append–sulje**-kuviolla (pitkäikäinen daemon ei rotatoisi jo avattua fd:tä) |

### PR-vahti

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `PR_WATCH_AUTO` | `0` | `1` = ei interaktiivisia kehotteita |
| `PR_WATCH_MERGE_LABEL` | `auto-merge` | Label, joka sallii auto-mergen |
| `PR_WATCH_LABELS_CSV` | *(tyhjä)* | Label-suodatin scan-tilassa |
| `PR_WATCH_ENABLE_CONFLICT_RESOLUTION` | `0` (poller nostaa `1`:ksi) | AI-avusteinen rebase-konfliktin ratkaisu |
| `PR_WATCH_CONFLICT_TIMEOUT` | `1800` | Konfliktinratkaisun aikakatto |
| `PR_WATCH_ENABLE_CI_REPAIR` | `0` (poller nostaa `1`:ksi) | AI-avusteinen punaisen CI:n korjaus (FIX_CI, ks. §8) |
| `PR_WATCH_MAX_CI_REPAIRS` | `1` | CI-korjauksen yrityskatto per PR (johdetaan run-dirin tapahtumalogista) |
| `PR_WATCH_CI_REPAIR_TIMEOUT` | `1800` | CI-korjauksen claude-kutsun aikakatto |
| `PR_WATCH_CI_LOG_MAX` | `60000` | Agentin promptiin syötettävän CI-lokiotteen kokokatto (tavua) |
| `PR_WATCH_CI_MAX_POLLS` | `40` | CI-odotuksen kierrosten määrä |
| `PR_WATCH_CI_POLL_SECS` | `15` | CI-odotuksen kierrosväli (40 × 15 s = 10 min) |

### Asennin

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_CLAUDE_HOME` | `$HOME/.claude` | Kohdehakemisto, johon agentit ja komennot linkitetään |
| `RUN_ISSUES_LAUNCH_AGENTS_DIR` | `$HOME/Library/LaunchAgents` | Plistien kohdehakemisto (`--with-launchagents`) |

Molemmat ovat olemassa yhtä syytä varten: **testit eivät saa koskea oikeaan
`~/.claude`-hakemistoon**, koska sitä ajaa poller samalla koneella. Jokainen asentajan polku
johdetaan `$HOME`:sta tai näistä overrideista — tildelaajennusta ei käytetä missään, jotta
`HOME=$(mktemp -d)` todella pitää.

### GitHub App (opt-in, ks. §8)

`RUN_ISSUES_GITHUB_APP_ID`, `RUN_ISSUES_GITHUB_APP_INSTALLATION_ID`,
`RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH`, `RUN_ISSUES_GHA_CACHE_FILE`,
`RUN_ISSUES_GHA_REFRESH_BUFFER_SECONDS` (`300`),
`RUN_ISSUES_GHA_TOKEN_ENDPOINT_BASE` (`https://api.github.com`).

## 8. Opt-in-mekanismit

Kaikki alla oleva on **pois päältä oletuksena**. Puuttuva konfiguraatio on hyvänlaatuinen
no-op, ei virhe.

- **`status.sh --github`** (#60) — kokonaistilan opt-in GitHub-rikastus. Ilman lippua `status.sh`
  on puhtaasti lukeva ja jokaisen ajon `github`-aliobjekti on `null` (käytös bitilleen kuin
  #59:ssä). Lipun kanssa `lib/status-github.sh` täyttää jokaisen ajon `github`-aliobjektin
  hakemalla avoimet PR:t `gh pr list`illä **kerran per owner/repo** (ei per ajo) TTL-cachella
  (`RUN_ISSUES_STATUS_CACHE_*`, §7). `ci` = `pr_ci_state`, `pr_decide_verdict` = `pr_decide`
  (`lib/pr-watch-lib.sh`) — ei omaa kopiota kummastakaan, sama `--json`-kenttäjoukko kuin
  PR-vahdilla, joten payloadit ovat vaihtokelpoisia. Rikastus nostaa `class_confidence`in
  `low`→`high` varmistuneelle PR:lle ja lisää luokitteluun `pr_ci_red`/`pr_changes_requested`/
  `pr_draft_stale`-syyt, siirtää suljetun PR:n ajon `cleanup`iin, ja siirtää PR:ttömän ajon
  `cleanup/issue_closed`iin kun issue on varmistetusti suljettu (#96, `status_github_issue_detail`)
  (`_github_reclassify`, §6). #103 lisäsi jokaiselle rikastetulle ajolle `github.issue_state`in +
  `issue_state_reason`in (ml. PR-rivit, näkymää varten) ja suljetun issuen otsikon; luokittelu
  ennallaan. **Fail-soft:** yhden repon verkkovirhe → `enrichment.repos_failed`, sen ajot jäävät
  `github: null` + `low`, muut repot rikastuvat, exit-koodi ja paikallinen luokittelu ennallaan.
  Autentikointi `gha_with_token`in kautta (GitHub App kunnioitetaan). `--github-full` erottaa
  suljetun PR:n `MERGED`/`CLOSED`iksi (per suljettu PR `gh pr view`), molemmat johtavat
  siivoukseen. `tests/test-status-github.sh` vartioi (gh-shim `PATH`issa laskee kutsut).
- **`db-clone/`** — kohderepon `.claude/db-clone.json` ohjaa tietokannan kloonauksen ajon
  ajaksi (S5). Kloonin nimi injektoidaan implementerille muuttujana
  `RUN_ISSUES_DB_CLONE`. Ks. `db-clone/README.md`.
- **`provision-test-env`-hook** — kohderepon `<worktree>/.claude/provision-test-env.sh` (S7c)
  provisioi testien tarvitsemat ulkoiset resurssit ja injektoi osoitteet `KEY=VALUE`-muodossa
  implementerin ympäristöön. Erillinen koneisto db-clonesta, ei korvaaja. Ks.
  `provision-test-env.README.md`.
- **`status-digest.sh` + `gws`** (#61) — työntökooste huomiota vaativista ajoista.
  `status.sh --json | status-digest.sh` (tai `--from-file`) ryhmittelee `attention`- ja
  `stalled`-ajot `class_reason`in mukaan suomenkieliseksi `text/plain`-rungoksi (iät
  vuorokausina, linkit issueen/PR:ään) ja lähettää sen `gws`illä Gmailiin. `status.sh` tekee
  tilanteesta *löydettävän*, tämä *huomatun*: dashboard jota pitää muistaa avata epäonnistui,
  kun customer-a-report #92 odotti 71 vrk `awaiting_clarification`-tilassa ilman että mikään työnsi
  tietoa. Nojaa **vain** paikalliseen JSONiin (`github: null` on laillinen), ei gh-rikastukseen.
  **Kolme opt-in-porrasta, kaikki hyvänlaatuisia no-oppeja:** (1) `gws` ei ole paketin
  riippuvuus — ilman sitä tai ilman vastaanottajaa runko tulostetaan stdoutiin (exit 0), sama
  SKIP-henki kuin testeissä, joten koosteen voi putkittaa mihin tahansa kanavaan; (2)
  toistokuoleman torjunta: sormenjälki = `sha256` järjestetystä `(run_id, class,
  class_reason)`-listasta tallennetaan `RUN_ISSUES_DIGEST_STATE_FILE`iin (rivi 1 sha, rivi 2
  lähetys-epoch, kirjoitus atominen `mktemp`+`mv -f`), ja muuttumaton tilanne ei lähetä mitään
  ellei `--force`; (3) `--max-silence <vrk>` (oletus 7): jos mitään ei ole lähetetty näin
  kauan, lähetetään silti (tyhjässä tapauksessa "kaikki kunnossa" -viesti) — hiljaisuus ei saa
  tarkoittaa "rikki". `schema_version` tarkistetaan: tuntematon versio ⇒ exit 2 ilman
  lähetystä (skeemasopimus alkaa maksaa itsensä takaisin). Konfiguraatio §7:ssä, malli
  `examples/status-digest.env.example`, testit `tests/test-status-digest.sh`. Ajastus
  (LaunchAgent/cron) on erillinen pieni lisäys, ei tässä. Exit-koodit: 0 lähetetty/ei
  tarvetta, 1 käyttö-/syötevirhe, 2 tuntematon `schema_version`, 3 lähetys epäonnistui (runko
  silti stdoutissa).
- **`PR_WATCH_ENABLE_CONFLICT_RESOLUTION`** — AI-avusteinen rebase-konfliktin ratkaisu.
  `pr-watch.sh` pitää sen pois päältä; `pr-watch-poller.sh` nostaa sen päälle watchlistin
  repoille, jotta auto-merge pääsee konfliktin läpi ilman ihmistä.
- **`PR_WATCH_ENABLE_CI_REPAIR`** — AI-avusteinen punaisen CI:n korjaus. Kun auto-merge-PR:n
  vaadittu check menee punaiseksi, `pr_decide` palauttaa `FIX_CI`n (vain kun tämä on `1`;
  muuten punainen ⇒ `WAIT_CI` kuten ennen), ja `pr_fix_ci` ajaa AI-agentin
  (`prompts/05-ci-repair.md`) **feature-worktreessä** korjaamaan todellisen virheen, pushaa,
  ja **revalidoi CI:n** ennen mergeä. Sama koneisto kuin konfliktipolussa: jaetut seamit
  `_pr_call_agent` + `_pr_force_push`, pakollinen CI-revalidointi turvaporttina, luovutus
  ihmiselle (`needs-human`-label + kommentti, exit 8) jos agentti ei korjaa, ei committaa,
  tai CI jää punaiseksi. Agentti **ei saa** viherryttää CI:tä huijaamalla (testin poisto,
  assertion löysäys, `skip`/timeout) — tämä on promptin ja revalidoinnin vartioima ehdoton
  rajoite. Yrityskatto `PR_WATCH_MAX_CI_REPAIRS` johdetaan run-dirin tapahtumalogista
  (`pr_ci_repair_attempted`), koska vahti on tilaton. `pr-watch.sh` pitää tämän pois päältä;
  `pr-watch-poller.sh` nostaa `1`:ksi watchlistin repoille. Edge-caset koodissa: `UNSTABLE`
  (vaaditut checkit vihreitä) ei mene `FIX_CI`hin; `DIRTY`+punainen rebasetaan ensin (`pr_decide`
  päättää `BEHIND`/`DIRTY`n ennen CI:tä), joten korjaus- ja rebase-polut eivät ketjuunnu.

  **Käynnistysvarmuus ja toipuminen (#45).** Kolme kytkeytyvää vartijaa, jotka estävät yhtä
  käynnistysvirhettä jäädyttämästä PR:ää käsin-mergettäväksi:
  1. **Luokitteluvaiheen preflight.** Ennen kuin `FIX_CI` dispatchataan `pr_fix_ci`:hin,
     `watch_one` ajaa `pr_ci_repair_preflight`in — saman `--version`-tarkistuksen kuin S0
     (`lib/preflight.sh`), joka pyydystää oletuskutsun `npx --no-install`-ansan (rc=127 vaikka
     `npx` on polulla). CLI:n puuttuessa `FIX_CI` alennetaan `WAIT_CI`:ksi **ennen**
     `pr_ci_repair_attempted`-eventtiä, joten yrityskatto ei kulu agenttiin joka ei koskaan
     käynnisty eikä PR:ää koskaan blokata. Vain oletuskutsu probataan; overrider
     `RUN_ISSUES_CLAUDE_CMD`:n ensimmäisen tokenin olemassaolo tarkistetaan (`have`-politiikka).
  2. **Rehellinen raportointi.** Jos agenttikutsu silti palauttaa `rc=127` (transientti
     käynnistysvirhe), `pr_fix_ci` erottaa sen "ei löytänyt korjausta" -tapauksesta:
     `_pr_ci_handover_to_human`in `kind=launch_failed` kirjoittaa PR-kommenttiin "agenttia ei
     voitu käynnistää (rc=127)" eikä harhaanjohtavaa "agentti ei tuottanut committia".
  3. **Ei pysyvää jäätymistä.** Luovutus finalisoi ajon `blocked/ci_repair_failed_pr_<n>`.
     `scan_candidates` uudelleen-emittoi **juuri nämä** blocked-ajot (kapea ehto — muut
     blocked-tilat kuten `stalled_in_*`, `env_bootstrap_failed`, `pr_conflicted` jäävät pois
     kuten ennen), joten CI:n vihertyessä PR palaa käsittelyyn. `needs-human` on pidätyslippu:
     sen ollessa PR:llä vahti ohittaa ajon hiljaa (ei uudelleenkommentointia joka tikillä);
     kun ihminen poistaa sen, ajo re-armataan ja mergetään jos CI on vihreä — juuri se, mitä
     luovutuskommentti lupaa.
- **`lib/github-app-auth.sh`** — GitHub App -identiteetti henkilökohtaisen tokenin sijaan.
  Aktivoituu vain jos App-env-muuttujat on asetettu; muuten jokainen sivuvaikutus on vartioitu.
- **Ohjaamon toimintopalvelu** (`action-server.sh`, #77) — statussivun mutaatiokanava. Kaksi
  opt-in-porrasta, molemmat hyvänlaatuisia no-oppeja: (1) **sivun puoli** — ilman
  `RUN_ISSUES_ACTION_BASE`ia `status-render.sh` ei upota tokenia eikä nappeja, ja sivu on
  bitilleen V1-lukupinta (turvamalli 6: sivu toimii täysin vaikka palvelu olisi alhaalla); (2)
  **palvelun puoli** — `install.sh --with-launchagents` deployaa `KeepAlive`-plistin, mutta host-portti
  pitää sen no-oppina, kunnes kone matchaa `RUN_ISSUES_ACTION_HOSTS`:n. Palvelu delegoi neljä
  toimintoa (`stop-run.sh` / `auto-clean`+`auto-merge`-labelit / `orchestrate.sh --restart` tai
  `needs-human`-poisto) `execve`llä — **ei riviäkään uutta purku-, merge- tai restart-logiikkaa**
  (turvamalli 5 rakenteellisena: Python ei koske gh:hun/labeleihin, `action-dispatch.sh` delegoi).
  Autentikointi fail-closed `tailscale whois`illa socket-peer-IP:stä + kolmikerroksinen CSRF
  (Origin + preflight-header + jaettu token). Ks. turvamalli README §7.9. Vartija:
  `tests/test-action-server.sh`.

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

Uusien agenttien **deploy on paketin oman `install.sh`:n vastuulla**, ei dotfilesin
`sync.sh`:n: `sync.sh` globaa plistit vain dotfilesin juuresta eikä siis näe submodulen sisällä
olevia tiedostoja. Konventio itsessään säilyy — `Label` == tiedostonimi ilman `.plist`,
`plutil -lint` porttina. `tests/test-package-layout.sh` vartioi `Label`-invarianttia,
joka on nyt kantava: asentaja johtaa tulostamansa `launchctl`-labelin tiedostonimestä.

**`com.claude-issue-runner.action-server.plist` on paketin ainoa pitkäikäinen daemon** (#77):
muut neljä agenttia tikkaavat `StartInterval`illä, mutta toimintopalvelu pitää kuuntelevaa
socketia, joten se on `KeepAlive`-daemon. `KeepAlive.SuccessfulExit=false` hoitaa kaksi asiaa
yhdellä: host-portti (vieras kone → exit 0 → **ei** uudelleenkäynnistystä) ja bind-toipuminen
(Tailscale-osoite ei vielä ylhäällä bootissa → exit ≠ 0 → uusi yritys `ThrottleInterval`in
päästä). §11:n invariantit ennallaan: ei `StandardOutPath`/`StandardErrorPath`-avaimia (palvelu
omistaa lokipolkunsa itse), `$HOME` laajenee vain `ProgramArguments`issa, `Label` ==
tiedostonimi, ohjelmapolku asentajan `scripts`-sidonnan alla. Asentaja ja `install.sh`:n
per-plist-glob (`com.claude-issue-runner.*.plist`) poimivat sen automaattisesti.

**`com.claude-issue-runner.self-update.plist` on paketin viides plist ja ainoa itsepäivittävä
agentti** (#112, `StartInterval` 3600). Se on tavallinen tikkaava agentti — **ei** daemon: `StartInterval`
nimenomaan siksi, ettei epäonnistunut `install.sh` crash-looppaisi (`KeepAlive` yrittäisi heti
uudelleen). Se on ainoa agentti, joka voi liikuttaa paketin omaa koodia (`git pull --ff-only`
kehittäjäkoneella; submodule-koneella pull ohitetaan aina, §4/§7.10). Samat §11-invariantit: ei
loki-avaimia (skripti omistaa kolme lokipolkuaan), `$HOME` vain `ProgramArguments`issa, `Label` ==
tiedostonimi, ohjelmapolku `$HOME/.claude/scripts/run-issues/self-update.sh` asentajan
`scripts`-sidonnan alla. Per-plist-glob poimii sen automaattisesti; `tests/test-package-layout.sh`
vartioi invariantit. self-update **ei kutsu `launchctl`ia** (samat syyt kuin asentaja): jos
asennusvaihe linkittää uuden plistin, self-update lokittaa `launchctl bootstrap` -NOTE-rivin.

**`$HOME` laajenee plistissä vain `ProgramArguments`issa**, koska laajennuksen tekee
`/bin/bash -l -c` -kääre, ei launchd. `StandardOutPath` ja `StandardErrorPath` ovat launchd:n
omia avaimia eikä se laajenna niissä mitään, joten literaali `$HOME` osuisi hakemistoon jonka
nimi kirjaimellisesti on `$HOME`. Siksi plisteissä **ei ole näitä avaimia lainkaan** (#6):
poller omistaa kaikki neljä lokipolkuaan itse ja ohjaa oman stdout/stderrinsä
`$RUN_ISSUES_LOG_DIR`-hakemistoon, jolloin yksi muuttuja siirtää ne kaikki. Vaihtoehto olisi
ollut materialisoida plist polut valmiiksi laajennettuina (näin dotfilesin `sync.sh` tekee),
mutta se rikkoisi asentajan omistajuuspredikaatin: `install.sh` tunnistaa omansa siitä että
kohde on **symlinkki paketin juuren sisään** (INV-OWN), eikä materialisoidussa kopiossa ole
sellaista merkkiä. `tests/test-package-layout.sh` vartioi molempia invariantteja: loki-avaimia
ei ole, ja ohjelmapolku on `$HOME/.claude/scripts/run-issues/…`.

`install.sh --with-launchagents` deployaa **vain tiedostot** (symlinkkeinä pakettiin, jotta ne
päivittyvät sen mukana) ja tulostaa `launchctl`-komennot ajettaviksi. Se **ei kutsu
`launchctl`ia itse**, kolmesta syystä: launchd mutatoi elävää käyttäjäsessiota; se ei ole
idempotentti uudelleenohjatun `$HOME`:n alla, joten kutsua ei voisi testata; ja yllä kuvattu
`com.maintainer.*` → `com.claude-issue-runner.*` -migraatio vaatii kertaluontoisen harkitun bootoutin,
jota skripti ei voi päättää käyttäjän puolesta.

Ennen deployta asentaja lukee plistin `ProgramArguments`-taulukon viimeisen alkion, laajentaa
`$HOME`:n ja tarkistaa että ohjelma resolvoituu. **Jos ei resolvoidu, deploy kieltäytyy
(exit 2).** Rikkinäisen agentin asentaminen olisi asentamatta jättämistä pahempaa: launchd
lataisi sen, epäonnistuisi joka `StartInterval`-tikillä eikä raportoisi mitään.

"Resolvoituu" on tässä laajempi kuin `[ -x ]`: suunnittelu ja soveltaminen ovat eri vaiheet
(INV-OWN, seuraus 2), joten puhtaalla koneella plistin ohjelmapolun luova `scripts`-sidonta on
tarkistushetkellä vasta suunnitelmarivi. Tiukka `[ -x ]` kieltäytyisi siis **aina**, myös
ajolla joka on juuri suunnittelemassa polun. `program_resolves` hyväksyy siksi myös
`SCRIPTS_BINDING_TARGET`in kautta resolvoituvan polun — mutta vain plistien oman
`$CLAUDE_HOME/scripts/run-issues/`-prefiksin osalta; kaikki muu putoaa kieltäytymiseen.
Tämä tekee `main()`:n järjestyksestä (`plan_scripts_binding` ennen `plan_launchagents`)
kantavan, ja `tests/test-install-launchagents.sh` vartioi sitä assertoimalla että deployn
jälkeen ohjelmapolku on oikeasti suoritettavissa.

## 12. Tunnetut avoimet asiat

- **PR-vahdin merge-strategia (P6) on kiinteä, ei konfiguroitava** (#41). `pr-watch.sh` yrittää
  ensin `gh pr merge --rebase --delete-branch` ja putoaa `--merge`iin, jos GitHub torjuu
  rebase-mergen. Torjunta on **pysyvä, ei ohimenevä**: GitHub kieltäytyy rebase-mergestä aina
  kun feature-haaralla on merge-commit (normaali tila, kun konflikti on ratkaistu mergeämällä
  base haaraan), eikä haaran muoto muutu itsestään — ilman varapolkua jokainen tikki toistaisi
  saman epäonnistumisen ja yksi rebase-kyvytön PR jumittaisi koko riippuvuusjonon. Molempien
  yritysten `gh`-virheteksti lokitetaan, jotta aito merge-esto nimeää syynsä aiemman
  läpinäkymättömän `merge failed` -rivin sijaan. Konfiguroitava `PR_WATCH_MERGE_STRATEGY`
  rajattiin ulos cycle reviewssä ei-minimaalisena; varapolku kattaa raportoidun vian.
  `tests/test-pr-watch-merge-fallback.sh` vartioi järjestystä (rebase ensin, `--merge` vasta
  sen kaaduttua) ja sitä että ajo finalisoituu `merged`.
- **`POLLER_HOSTS_LEGACY_DEFAULT` on taaksepäin-yhteensopivuusshim.** `lib/poller-config.sh`
  sisältää sisäänrakennetun oletuslistan niistä konenimistä, joilla pollerit ajoivat ennen kuin
  host-portista tuli konfiguroitava. Se on tietoinen poikkeus §1:n lupaukseen "ei
  henkilökohtaista konfiguraatiota": ilman sitä nykyinen auto-run-kone pysähtyisi sillä
  hetkellä kun #6 mergetään, mikä oli epicin nimenomainen ei-tavoite. Poistetaan sinä päivänä
  kun kyseinen kone asettaa `RUN_ISSUES_POLLER_HOSTS`:n omaan `poller.env`iinsä.
  `tests/test-poller-config.sh` pinnaa listan sisällön, jotta muutos siihen on päätös eikä
  vahinko.
- **Dotfiles-fallback säilyy legacynä.** Watchlist etsitään yhä vanhasta
  `~/dotfiles`-puusta molemmissa pollereissa, jos ensisijainen ei osu. Polku kulkee yhden
  nimetyn muuttujan (`LEGACY_DOTFILES_DIR`) kautta, jotta "riippuuko tämä yhä vanhasta
  rakenteesta?" on yhden rivin kysymys. Poistettavissa kun kyseisen koneen watchlist on
  siirretty polkuun `~/.config/run-issues/watchlist.json`.
- **`~/.claude/agents` ja `~/.claude/commands` hakemistosymlinkkeinä → #5.** Niin kauan kuin
  dotfiles symlinkkaa koko hakemiston, `install.sh` kieltäytyy (exit 2). Korjaus on
  dotfiles-repon puolella eikä kuulu tähän pakettiin.
- **`~/.claude/skills` hakemistosymlinkkinä → #5 (sama juurisyy, eri hakemisto).** Ylläpitäjän
  koneella `~/.claude/skills` on yhä hakemistosymlinkki (`-> dotfiles`); `agents` ja `commands`
  on jaettu per tiedosto, `skills` ei vielä. Tällä koneella `install.sh` tulostaa skillistä
  **conflict-rivin ja exit 4:n** (ei refusea, jottei koko asennus kaadu — §3), joten
  agents/commands linkittyvät normaalisti ja `skills/claude-issue-runner` jää asentumatta. Se ei
  ole bugi vaan odotettu välitila: korjaus (skills-hakemiston jako per-tiedosto/per-hakemisto
  -symlinkeiksi) on dotfiles-repon puolen työ, samoin kuin agents/commands aikanaan.
- **Skillin sisältö on kahden vartijan varassa.** `tests/test-skill-labels.sh` johtaa
  labelisanaston koodista (poimintakysely, `labels_*`-kutsujen labeliargumentit, `*_LABEL`-arvot,
  konfiguroitavien oletukset) ja vaatii skilliltä jokaisen — **koodiin lisätty label ilman
  skill-riviä on punainen testi**, ei hiljainen ajautuma. Fail-closed: jos johdettu joukko kutistuu
  alle kahdeksan alkion tai ankkuri `needs-human` katoaa, testi kaatuu sen sijaan että läpäisisi
  tyhjästä. `tests/test-skill-surface.sh` tekee saman komento- ja skriptipinnalle molempiin
  suuntiin (skillin nimeämä `/komento` ⇒ `commands/<nimi>.md` olemassa; toimitettu komento ⇒
  skillissä nimetty, pois lukien perusteltu poissulkulista). Kytkös lunastettu: **#99** muutti
  poimintaehdot (`no:assignee` → `-label:auto-claimed`) ja lisäsi `auto-claimed`-labelin, ja
  skillin päivitys tuli samassa muutoksessa — vartijat todensivat sen.
- **`install.sh --uninstall` puuttuu.** Paketin omistamien symlinkkien poisto on tehtävä
  käsin. Omistajuuspredikaatti (symlinkin kohde paketin juuren sisällä) riittäisi sellaisenaan
  toteutukseen.
- **`docs/diagrams/*.mmd`-syntaksilla ei ole vartijaa, ja 5/13 diagrammia ei tällä
  hetkellä parsiudu.** Issue #12:n valinnainen osa (`tests/test-diagrams.sh`, mmdc-pohjainen
  SKIP-konvention mukainen syntaksitesti) jätettiin **tietoisesti tekemättä**: sen premissi
  (diagrammit ovat valideja) osoittautui vääräksi. mermaid-cli 11.16.0:lla kaatuvat
  `preflight-gate-failure-map`, `run-issues-auto-clean-flow` (tyhjä `%%`-erotinrivi ennen
  deklaraatiota — mermaidin kommenttistrippausregex vaatii `[^\n]+` `%%`:n jälkeen),
  `run-issues-component-dependencies` (lainaamaton `.` dotted-nuolen labelissa
  `reads run.json`, rivi ~69), sekä `pr-watch-state-machine` ja
  `run-issues-timeout-restart-sequence` (vähemmän ilmeinen state/sequence-bodyn syntaksi,
  paikannus vaatii bisektoinnin). Vartija + näiden 5 diagrammin korjaus on oma
  dokumentaatiohygienian muutoksensa, joka ei kuulunut #12:n δψ-refaktorointiin ja ansaitsee
  oman katselmuksensa. Rikkinäinen diagrammi renderöityy tyhjäksi, joten korjaus on puhdasta
  parannusta — mutta label-uudelleensanoitus muuttaa dokumentaation sisältöä.
- **`-is:blocked` edellyttää github.com:ia.** Poimintahaun estosuodatin nojaa GitHubin
  natiiviin `is:blocked`-kvalifikaattoriin. Jos ominaisuus puuttuu GitHub Enterprise
  Serveristä, poiminta hiljenisi siellä (tuntematon negatiivinen kvalifikaattori palauttaa
  kaikki, ei virhettä). Merkitys tälle asennukselle on nolla: kaikki repot ovat github.com:issa.
  Sama koskee S2b-portin (#28) dependencies-API:a: jos `…/dependencies/blocked_by` puuttuu tai
  virheilee, `count_open_blockers` tulkitsee sen estoksi (fail-closed) ⇒ portti kieltäytyisi
  ajamasta. Hätävara on nimetyn ajon `--force`.
- **`commands/factory-run.md` viittaa puuttuvaan skriptiin.** Ohje kehottaa ajamaan
  `templates/factory-init.sh`-skriptin; tiedostoa ei ole tässä repossa. Joko se jäi pois
  siirrosta (#2) tai viittaus on vanhentunut.
- **Työnjako `README.md` ↔ tämä tiedosto.** `README.md` on ihmiselle (asennus, turvamalli,
  perehdytys), tämä tiedosto agentille (täysi tekninen referenssi). Ympäristömuuttujien täysi
  lista on §7:ssä; README listaa niistä vain asennus- ja konfigurointiaikaisen osajoukon ja
  viittaa tänne. Jos fakta muuttuu, **tämä tiedosto on lähde**. `tests/test-readme.sh` vartioi
  README:n rakennetta ja johtaa exit-koodiodotuksensa suoraan skripteistä, joten uusi
  exit-koodi ilman README-riviä on punainen testi.
- **`state.jsonl`-kohina PR-vahdista — kasvun lähde tukittu (#65), takautuva siivous jäljellä.**
  Mitattu Studiolla (#59): 256 run-diriä, `state.jsonl`-tiedostoja yhteensä 345 MB ja 1,19 M
  tapahtumaa, joista **>99,7 %** oli PR-vahtipollerin
  `pr_watch_started`/`pr_classified`/`pr_watch_skipped`-riviä joka tikillä — myös jo suljetuille
  PR:ille (suurin yksittäinen tiedosto 6,7 MB). **#65 pysäytti kasvun:** `pr-watch.sh` kirjaa
  ensimmäisen `SKIP_CLOSED`-siirtymän (PR sulkeutui) mutta **vaikenee toistuvasta** kolmikosta,
  kun run-dirin edellinen kirjattu päätös oli myös `SKIP_CLOSED`. Edellinen päätös luetaan
  `pr_last_decision`illa (`lib/pr-watch-lib.sh`) **vain hännästä** — mikä tekee edelleen sitovaksi
  koodisäännön, jota `status.sh`kin noudattaa: **`state.jsonl`iä ei lueta kokonaan missään
  koodipolussa; vain `tail -n N` on sallittu** (`scan_stalled` lukee hännän, `status.sh` samoin
  `RUN_ISSUES_STATUS_TAIL_LINES` rivin verran). Jäljellä: **jo levyllä olevien 345 MB:n
  takautuva tiivistäminen** on eri asia kuin kasvun pysäytys — se poistuu run-dirien
  siivouksen myötä (#65 scope-out). Sisaravaus: pollerilokien rotaatio (`RUN_ISSUES_LOG_MAX_BYTES`,
  §7; `lib/log-rotate.sh`, §6) tukkii saman rajattoman kasvun `.runs.log`ista (mitattu 190 MB).
- **"maintainer" on kovakoodattu prompteihin ja komentoihin.** Nimi esiintyy seitsemässä tiedostossa
  (`prompts/`, `commands/`, `agents/`). Parametrisointi `{{HUMAN}}`-muuttujaksi kattaisi vain
  `prompts/`-hakemiston, koska `render_prompt` ei koske `commands/`- eikä `agents/`-tiedostoihin
  — ne lukee Claude Code suoraan levyltä. Puoliksi parametrisoitu järjestelmä olisi huonompi
  kuin kumpikaan puhdas vaihtoehto, joten #9 jätti tämän tietoisesti tekemättä. Toiminnallista
  vaikutusta ei ole: bot ja ihminen erotellaan markerin aikaleimalla, ei nimellä
  (`lib/issue.sh`).
- **Epic-ajon auto-run-semantiikka (#81), `/run-epic` (#82), keskeytys (#90), näkymän
  konvergointi jaettuun resolvointiin (#91) ja cross-repo-tuki (#92) on toteutettu.**
  `docs/epic-orchestration.md` (#80) määrittelee koko arkkitehtuurin. #81 toteutti sen
  auto-run-tason muutoskohdat M1–M5 ja M7: epicin poissulku poiminnasta (`-label:epic`
  molemmissa hauissa) + S2c-portti (`is_epic`, exit 12), lapsijoukon jaettu resolvointi
  (`list_epic_children`), ajolabelien idempotentti propagointi + `needs-human`-eskalaatio +
  valmiuskommentti/-label (`lib/epic.sh`, pollerin `scan_epics`). **#82 toteutti M6:n**
  `/run-epic`-komennon (`commands/run-epic.md` + `run-epic.sh`): validointi (avoin, ei-tyhjä,
  syklitön `blocked_by`-graafi, sama repo) suunnittele–sovella-jaolla, `epic`-labelin lisäys jos
  puuttuu, ajolabelien propagointi jaetulla `propagate_run_labels`illa (AC4), `--dry-run` ja
  `--start-now`. **#90 toteutti keskeytyksen** (`--stop`, §4.3, päätös H) samaan skriptiin:
  elävien lapsiajojen pysäytys delegoimalla `stop-run.sh`:lle (turvalogiikkaa ei monisteta) +
  ajolabelien poisto `labels_remove`illa **ensin epiciltä, sitten avoimilta lapsilta** (estää
  `scan_epics`in re-propagoinnin), plan-then-apply, exit 6 osittaisuudelle. **#91 poisti näkymän
  toisen resolvoinnin:** `lib/status-github.sh` kuluttaa jaettua `list_epic_children`iä
  (`status_github_fetch_sub_issues`/`status_github_parse_task_list` poistettu), fallback-tila on
  autoritatiivinen avoimien issueiden joukosta molemmilla puolilla, natiivin luvun epäonnistuminen
  on fail-closed molemmilla (näkymässä `source: "unreadable"`), ja lapsijoukko resolvoidaan
  identtisesti — näkymä ja ajo eivät voi enää ajautua eri lapsijoukkoon (§1.3-invariantti
  voimassa). **#92 poisti cross-repo-rajauksen:** `list_epic_children`in TSV kantaa nyt lapsen oman
  `owner/repo`n (natiivi `repository_url`ista, task-lista `owner/repo#N`-viittauksesta; tila
  ratkaistaan kyseisen repon avoin-joukosta, kerran per repo, fail-closed rc 2), ja jokainen
  kuluttaja käsittelee lapsen sen omassa repossa: propagointi + eskalaatio + valmius (`lib/epic.sh`,
  eskalaatiomarker repo-tarkennettu cross-repolle, saman repon lapsi säilyttää vanhan
  `child=<N>`-muodon), `count_open_blockers` laskee cross-repo-estäjän (S2b, AC4), `/run-epic`
  raportoi lapset repoittain + varoittaa watchlistin ulkopuolisista repoista, ja Ohjaamon `epics[]`
  kantaa per-lapsi `repo`/`repo_slug`-kentät (view joins + display). **Scope-out säilyy:** ei
  cross-repo-worktreetä/PR:ää, ei cross-org-App-tunnistautumista (vieraan orgin lapsi kirjoitetaan
  henkilökohtaisella identiteetillä tai epäonnistuu näkyvästi).
