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
status.sh                      status-digest.sh       status-render.sh
install.sh
provision-test-env.README.md   README.md              CLAUDE.md
lib/       16 bash-moduulia (ks. §6)
prompts/   orkestraattorin claude-kutsujen promptipohjat
tests/     plain-bash-testipaketti, ajuri run-all.sh
db-clone/  opt-in-tietokantakloonaus
agents/    Claude-agenttimäärittelyt (architect, developer, reviewer, refactorer)
commands/  slash-komennot (run-issues, cleanup-run, pr-watch, refresh, factory-*)
skills/    Claude-skillit (run-issues-workflow: issue-konventiot kohderepoon)
docs/diagrams/  mermaid-kaaviot (.mmd)
examples/  run-issues-watchlist.example.json, run-issues-poller.env.example,
           status-digest.env.example, status-caddy.example
com.claude-issue-runner.run-issues-poller.plist
com.claude-issue-runner.pr-watch-poller.plist
com.claude-issue-runner.status-render.plist
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

**Vaihe A** — S1 PickIssue → S2 Lock → **S2b BlockedCheck** → S3 Claim → S4 Worktree →
S5 DBClone → S6 CycleReview

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
tarve. Sama koskee S0-preflightiä (exit 8), joka poistuu ennen lukkoa.

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
(worktree, branch, run-dir, assignaatio, `needs-human`-label, lukko — **issueta ei suljeta**,
toisin kuin `auto-clean.sh`). Siivottu issue täyttää normaalin poimintahaun (`no:assignee`) ja
tulee poimituksi seuraavalla tikillä täytenä uutena ajona tuoreesta basesta — ei vanhan
run-dirin jatkamista, koska blocked-ajon worktree on tyypillisesti haarautettu ennen esteen
poistanutta mergeä. Silmukkaraja on rakenteellinen ilman uutta laskuria: uudelleen blocked
päättyvä ajo postaa **uuden** markerin, ja `scan_blocked_answered` vaatii vastauksen uusimman
markerin jälkeen ⇒ yksi kommentti = korkeintaan yksi yritys. Suljettu issue tai markeriton
legacy-ajo ohitetaan hiljaa. `fetch_issue_json` palauttaa nyt myös issuen `state`n, jotta
avoimuustarkistus tehdään samasta hausta kuin markeri/vastaus.

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
| 1 | Fataali — virheellinen käyttö / puuttuva `run.json` resumessa |
| 2 | Ei ehdokasissueta (poll-tila, ei tehtävää) |
| 3 | Lukko-/claim-kisa hävitty |
| 4 | Cycle review esti ajon (vain auto-tila) |
| 5 | Estynyt ennen implementeriä tai siinä — S4 worktreen luonti epäonnistui (`worktree_base_unresolved` base-ref ei ratkennut / `worktree_leftover_branch` jäänne-haara edellisestä ajosta / `worktree_create_failed` muu `git worktree add` -virhe, #34), db-clone, S7b tai S7c epäonnistui, tai implementer palautti BLOCKED |
| 6 | PR:n avaus epäonnistui |
| 7 | Implementer (S8) timeouttasi — ajo finalisoitu `timed_out`, kelpaa `--restart`iin |
| 8 | Puuttuva pakollinen riippuvuus — S0-preflight-portti pysäytti ajon ennen S1:tä (ei lukkoa, ei claimia, ei run-diriä); stderr-viesti nimeää korjauskomennon |
| 9 | Issue on estetty avoimella `blocked_by`-riippuvuudella — S2b-portti (#28) kieltäytyi lukon ja claimin välissä; ajo finalisoitu `blocked/blocked_by_dependency`, lukko vapautettu, ei claimia. Fail-closed (lukukelvoton graafi = esto). Nimetyn ajon voi pakottaa `--force`illa |
| 10 | Odottaa ihmisen katselmointia — jatka `--resume` |
| 11 | Odottaa tarkennusta — cycle review palautti NEEDS_CLARIFICATION; ajo finalisoitu `awaiting_clarification`, pollerin `scan_answered` jatkaa `--continue`lla |

### Kokonaistila (`status.sh`, #59)

Oma avaruus, ei sekoiteta orkestraattorin koodeihin. Puhtaasti lukeva skripti, joten koodit
kertovat vain lukemisen onnistumisesta — ei mitään lukittua, claimattua tai luotua.

| Koodi | Merkitys |
|---|---|
| 0 | Luenta onnistui |
| 1 | Käyttövirhe (tuntematon lippu / kelvoton arvo) |
| 2 | Ei watchlistiä, ei yhtään levyllä olevaa repoa, tai `jq` puuttuu |
| 3 | Vajaa luenta — ≥1 `run.json` oli lukukelvoton/virheellinen; dokumentti silti validi ja täydellinen muun osan osalta (`degraded: true`), rikkinäiset polut `read_errors`-listassa. Kaksitasoinen luenta (bulk → per-file-fallback) eristää rikkinäisen, muut luetaan |

### Statussivun renderöinti (`status-render.sh`, #62)

Oma avaruus. `status.sh`:n JSONin ensimmäinen kuluttaja: kirjoittaa `index.html`in ja
`status.json`in atomisesti (`RUN_ISSUES_STATUS_OUT_DIR`, oletus
`${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www`). HTML on itsenäinen: inline-CSS, ei
ulkoisia resursseja, ei JavaScriptiä. **Kenttävalkolista, ei mustalista**: renderöijä poimii
nimetyt kentät (repo-slug, issue-numero + URL, PR-URL, `class`/`class_reason`, iät,
`current_state`, haara, `blocked_reason`, cachen ikä, `generated_at`) `jq`:lla eikä koskaan
itereoi run-objektia, jottei myöhemmin skeemaan lisätty kenttä (issuen otsikko, lokit,
promptit, polut) vuoda sivulle. Jokainen datamerkkijono escapataan (`jq @html`). Ilman
`--input`ia skripti ajaa `status.sh --json`in itse (LaunchAgent-polku); `status.sh`:n exit 3
(degraded) siedetään, muu ei-nolla ⇒ vanha sivu jää paikoilleen. Altistuspäätös (Caddy-vhost,
Tailscale-bind) ei kuulu pakettiin — vain `examples/status-caddy.example`. Turvamalli:
README §7.8. Vartija: `tests/test-status-render.sh`.

| Koodi | Merkitys |
|---|---|
| 0 | Renderöity — molemmat tiedostot kirjoitettu atomisesti (temp + `mv -f`) |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva arvo) |
| 2 | Syöte kelvoton — `status.sh` ei tuottanut validia JSONia tai `schema_version` tuntematon; vanha sivu jää paikoilleen (ei ylikirjoiteta rikkinäisellä renderöinnillä) |
| 3 | Kirjoitus epäonnistui (levy täynnä / oikeudet); temp siivotaan, vanha sivu jää ehjäksi |

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
| `issue.sh` | GitHub-issue-operaatiot `gh`-CLI:n ympärillä (ml. `count_open_blockers`, S2b:n autoritatiivinen esto-luku dependencies-API:sta, #28; `build_marker`/`parse_marker`/`detect_answer` vastattaville kommenteille; `fetch_issue_json` palauttaa myös `state`n blocked-uusinnan avoimuustarkistukseen, #57) |
| `issue.test.sh` | `verify_claim`in yksikkötestit (S2/S3-kilpajuoksu) |
| `labels.sh` | Label-hallinta REST-API:n kautta (ei `gh issue edit --add-label`) |
| `locking.sh` | Issue-kohtainen lukkohakemisto, atominen `mkdir(2)`:lla |
| `poller-config.sh` | Pollerien host-portti ja watchlistin resolvointi puhtaina funktioina. Erillinen lib siksi, että molemmat pollerit tarvitsevat saman päätöksen ja se on testattava **sourcaamalla** — poller itse exittaa source-hetkellä vieraalla koneella |
| `pr-watch-lib.sh` | PR:n luokittelu- ja merge-päätöslogiikka (irrotettu testattavaksi) |
| `preflight.sh` | Jaettu ulkoisten riippuvuuksien tarkistus. Puhtaat funktiot, vakavuus paluukoodissa: `install.sh` käyttää neuvoa-antavasti, orkestraattorin S0-portti (#7) tekee samasta lähteestä fataalin (exit 8). Korjauskomennot tulevat yhdestä lähteestä (`preflight_install_hint`) |
| `render-prompt.test.sh` | `render_prompt`in yksikkötestit (rekursiivinen sijoitus) |
| `state.sh` | Ajon durable-tila `<run-dir>`-hakemistossa |
| `status-read.sh` | `status.sh`:n puhtaat luku- ja luokittelufunktiot (#59): `_STATUS_NORMALIZE_JQ` (heterogeenisen `run.json`in normalisointi + `schema_gaps`), `status_read_bulk`/`status_read_perfile` (kaksitasoinen luenta), `_STATUS_CLASSIFY_JQ` + `status_classify` (viisi luokkaa prioriteettijärjestyksessä, INV-STATUS lukee vain `status`ia, INV-UNKNOWN fail-closed), `_STATUS_GITHUB_RECLASSIFY_JQ` (`_github_reclassify`, #60: `--github`-rikastuksen jälkeen ajettava jälkiluokittelu — no-op kun `github == null`, muuten nostaa `class_confidence`in `low`→`high` varmistuneelle PR:lle ja lisää `pr_ci_red`/`pr_changes_requested`/`pr_draft_stale`/`pr_not_open`-refinoinnit), ja `_iso_to_epoch` (siirretty poller.sh:sta; poller sourcaa sen täältä, jotta `scan_stalled`in liveness-kello ja `status.sh`:n `idle_seconds` lasketaan identtisesti) |
| `status-github.sh` | `status.sh --github`-rikastuksen opt-in-moduuli (#60): avoimet PR:t `gh pr list`illä **kerran per owner/repo** TTL-cachella, `github`-aliobjektin rakennus per PR (`status_github_pr_object`/`status_github_build_pr_map`), cache-primitiivit (`status_github_cache_file`/`status_github_load_cache`/`status_github_write_cache`, atominen `mktemp`+`mv -f` kuten `lib/state.sh`), verkkokutsu (`status_github_fetch_open_prs` `gha_with_token`in kautta) ja `NOT_OPEN`-objekti (`status_github_not_open_object`, `--github-full` erottaa `MERGED`/`CLOSED`in `status_github_closed_state`illä). **Ei omaa CI-rollupia eikä merge-päätöstä**: `ci` = `pr_ci_state`, `pr_decide_verdict` = `pr_decide` (`lib/pr-watch-lib.sh`), samalla `--json`-kenttäjoukolla kuin PR-vahti. Fail-soft: repon verkkovirhe → `repos_failed`, ei kaada tulostetta |
| `version.sh` | Ajossa olevan runner-version näkyväksi teko (#32): `runner_version` (lyhyt HEAD), `runner_behind_origin` (jäljessä `origin/main`ia), `runner_version_summary` (raporttirivi) ja `runner_fetch_throttled` (throttlattu `git fetch`). Fail-soft: puuttuva `.git`/verkko ⇒ `?`. Pollerit lokittavat tikin alussa, `orchestrate.sh --version` ja situation-kommentin `Runner-version:` lukevat samasta lähteestä |
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
| `RUN_ISSUES_SKIP_PREFLIGHT` | `0` | `1` = ohita S0-portti. Hätävara: portti ei saa koskaan olla syy siihen, ettei ajo käynnisty toimivalla koneella |

### Poller

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_POLLER_ENV_FILE` | `$HOME/.config/run-issues/poller.env` | Konekohtaisen konfiguraation tiedosto |
| `RUN_ISSUES_POLLER_HOSTS` | *(sisäänrakennettu legacy-lista, ks. §12)* | Pilkuin/välilyönnein eroteltuja glob-kuvioita, verrataan `hostname -s`:ään. `*` sallii kaikki. Ei osumaa ⇒ poller exittaa 0 luomatta mitään |
| `RUN_ISSUES_WATCHLIST` | *(tyhjä)* | Watchlistin polku. Asetettuna se on **ainoa** ehdokas — osumaton override on virhe, ei fallback |
| `RUN_ISSUES_LOG_DIR` | `$HOME/Library/Logs` | Kaikkien neljän lokitiedoston hakemisto per poller (`.log`, `.runs.log`, `.stdout.log`, `.stderr.log`) |
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

**Pollerit eivät lue `$HOME/.config/run-issues/env`-tiedostoa.** Se sisältää salaisuuksia,
jotka `orchestrate.sh` ja `pr-watch.sh` sourceavat itse. Poller ei tarvitse niistä yhtäkään ja
lokittaa runsaasti, joten salaisuudet pidetään sen prosessin ulkopuolella.
`tests/test-poller-config.sh` vartioi tätä.

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

### Statussivun renderöinti (`status-render.sh`, #62)

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_STATUS_OUT_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www` | Hakemisto, johon `index.html` ja `status.json` kirjoitetaan. `--out-dir` ohittaa |
| `RUN_ISSUES_LOG_DIR` | `$HOME/Library/Logs` | Skripti ohjaa oman stdout/stderrinsä `status-render.stdout.log`/`.stderr.log`-tiedostoihin täältä, kun ei aja TTY:llä (plistissä ei loki-avaimia, §11) |
| `RUN_ISSUES_HOME` | *(scriptin oma hakemisto)* | Testien injektiopiste; myös `status.sh`:n sijainti LaunchAgent-polulla (ilman `--input`ia) |

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
  `pr_draft_stale`-syyt sekä siirtää suljetun PR:n ajon `cleanup`iin (`_github_reclassify`,
  §6). **Fail-soft:** yhden repon verkkovirhe → `enrichment.repos_failed`, sen ajot jäävät
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
  agents/commands linkittyvät normaalisti ja `skills/run-issues-workflow` jää asentumatta. Se ei
  ole bugi vaan odotettu välitila: korjaus (skills-hakemiston jako per-tiedosto/per-hakemisto
  -symlinkeiksi) on dotfiles-repon puolen työ, samoin kuin agents/commands aikanaan.
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
- **`state.jsonl` kasvaa rajatta, valtaosin PR-vahtikohinaa (#59).** Mitattu Studiolla: 256
  run-diriä, `state.jsonl`-tiedostoja yhteensä 345 MB ja 1,19 M tapahtumaa, joista **>99,7 %**
  on PR-vahtipollerin `pr_watch_started`/`pr_classified`/`pr_watch_skipped`-riviä joka tikillä
  — myös jo suljetuille PR:ille (suurin yksittäinen tiedosto 6,7 MB). Tästä seuraa sitova
  koodisääntö, jota `status.sh` noudattaa: **`state.jsonl`iä ei lueta kokonaan missään
  koodipolussa; vain `tail -n N` on sallittu** (`scan_stalled` lukee hännän, `status.sh` samoin
  `RUN_ISSUES_STATUS_TAIL_LINES` rivin verran). Tiedostojen kohinan karsinta (esim. lopettaa
  `pr_classified`in kirjoitus suljetuille PR:ille, tai rotatoida vanhat tapahtumat) on oma
  siivousmuutoksensa, joka ei kuulunut #59:n lukevaan näkymään.
- **"maintainer" on kovakoodattu prompteihin ja komentoihin.** Nimi esiintyy seitsemässä tiedostossa
  (`prompts/`, `commands/`, `agents/`). Parametrisointi `{{HUMAN}}`-muuttujaksi kattaisi vain
  `prompts/`-hakemiston, koska `render_prompt` ei koske `commands/`- eikä `agents/`-tiedostoihin
  — ne lukee Claude Code suoraan levyltä. Puoliksi parametrisoitu järjestelmä olisi huonompi
  kuin kumpikaan puhdas vaihtoehto, joten #9 jätti tämän tietoisesti tekemättä. Toiminnallista
  vaikutusta ei ole: bot ja ihminen erotellaan markerin aikaleimalla, ei nimellä
  (`lib/issue.sh`).
