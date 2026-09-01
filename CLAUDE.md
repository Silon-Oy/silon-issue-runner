# CLAUDE.md — claude-issue-runner

## 0. Mitä tässä tiedostossa on

**Invariantit, mitatut rajoitteet ja tietoiset ei-päätökset.** Ne eivät ole johdettavissa
koodista, ja ne rikkoutuisivat uudelleen ilman kirjausta.

**Mitä tässä ei ole, ja mistä se löytyy:**

| Tieto | Lähde |
|---|---|
| Exit-koodit | Skriptin otsikkokommentti `# Exit codes:` — `README.md` §9 on `tests/test-readme.sh`:n vartioima peilaus |
| Ympäristömuuttujien nimet ja oletukset | Koodin `${VAR:-oletus}` + skriptin `# Env:` — `docs/env-reference.md` on täysi peilaus |
| Miksi yksittäinen muutos tehtiin | Kyseisen issuen PR-kuvaus ja `git log` |
| Kertynyt perusteluaineisto ennen 2026-09-01 | `docs/design-history.md` (historiallinen, ei ylläpidetty) |
| Epic-arkkitehtuuri kokonaisuutena | `docs/epic-orchestration.md` |
| Asennus, turvamalli, perehdytys ihmiselle | `README.md` |

**Tämä tiedosto ei kasva issue kerrallaan.** Uuden muutoksen perustelu kuuluu sen PR-kuvaukseen.
Tänne lisätään vain, jos muutos synnyttää *uuden invariantin* tai *mitatun rajoitteen* — ja
silloin se **korvaa** vanhan rivin, ei kasaannu sen viereen. Kokokatto on `tests/test-claude-md-size.sh`.

## 1. Mikä tämä repo on

Itsenäisesti asennettava paketti `/run-issues`-orkestraattorille: GitHub-issuesta valmiiseen
pull requestiin ilman ihmistä silmukassa, sekä PR-vahti (`pr-watch.sh`), joka vie PR:n
merge-tilaan asti.

Paketti irrotettiin dotfiles-reposta (#2), koska se on yleiskäyttöinen työkalu eikä yhden
ihmisen ympäristökonfiguraatiota. Tässä repossa **ei ole henkilökohtaista konfiguraatiota**:
ei watchlistiä (vain skeemaesimerkki `examples/`-hakemistossa), ei koneistokohtaisia
env-tiedostoja, ei salaisuuksia. Poikkeus on kirjattu §13:een.

Osat: **orkestraattori** (`orchestrate.sh` + `lib/` + `prompts/`), **pollerit** (`poller.sh`,
`pr-watch-poller.sh`), **PR-vahti** (`pr-watch.sh`), **apuvälineet** (`cleanup-run.sh`,
`auto-clean.sh`, `stop-run.sh`, `status*.sh`, `run-epic.sh`, `self-update.sh`) ja
**Claude-integraatio** (`agents/`, `commands/`, `skills/`, `prompts/`).

## 2. Repo-juuri on mount-piste

**Invariantti: juuressa ei saa olla `claude/`-hakemistoa, eikä skriptejä saa siirtää
alihakemistoon.**

Kummassakin asennusmallissa polkuun `~/.claude/scripts/run-issues` päätyy paketin **juuri**,
ei alihakemisto. Juuren sisällön on siis oltava täsmälleen se, mitä tuossa hakemistossa pitää
näkyä. Issue #3 mittasi vaihtoehdot kertakäyttöisellä `git submodule add` -kokeella:

| Vaihtoehto | Paketin juuri | Lopputulos mountin jälkeen |
|---|---|---|
| A — säilytä dotfiles-polut | `claude/scripts/run-issues/orchestrate.sh` | kaksinkertainen sisäkkäisyys |
| B — `scripts/` juureen | `scripts/orchestrate.sh` | yksi taso liikaa |
| **C — valittu** | `orchestrate.sh` | osuu |

A ja B rikkoisivat jokaisen viittauksen polkuun `…/run-issues/<skripti>`: kolme slash-komentoa,
`prompts/02-implementer.md` ja LaunchAgent-plistit. Rikkoutuminen olisi **hiljainen** — paketti
näyttäisi ehjältä, mutta ulkoiset viittaukset osoittaisivat väärään paikkaan. Siksi
`tests/test-package-layout.sh` vartioi tätä.

Siirto onnistui ilman koodimuutoksia, koska jokainen skripti ja testi resolvoi riippuvuutensa
oman sijaintinsa suhteen (`SCRIPT_DIR` / `HERE`) eikä yksikään nouse `../..`-tasolle. **Pidä
tämä voimassa.**

## 3. Asennusmalli ja INV-OWN

Malleja on kaksi, ja ne eroavat vain siinä **kuka tuottaa polun `~/.claude/scripts/run-issues`**:

- **Oletus** — klooni mihin tahansa + `install.sh` luo symlinkin paketin juureen.
- **Ylläpitäjän kone** — dotfiles-submodule (#1) tuottaa polun jo ennen asennusta. Submodule on
  pinnattu committiin: päivitys on eksplisiittinen, mutta ajossa oleva koodi voi ajautua hiljaa
  `main`in taakse (siksi `lib/version.sh` tekee ajautuman näkyväksi).

**Seuraus:** asentajan `scripts`-sidonta ei voi olla ehdoton eikä puuttua — submodule-mallissa
polun tuottaa vieras puu johon ei saa kirjoittaa, oletusmallissa mikään muu ei tuota sitä.
Sidonta on siis **ehdollinen**: toimiva polku jätetään rauhaan riippumatta kuka sen tarjoaa.

`agents/`, `commands/` ja `skills/` päätyvät kummassakin ketjussa polkuun
`~/.claude/scripts/run-issues/…`, mikä ei riitä: Claude Code lukee ne hakemistoista
`~/.claude/{agents,commands,skills}/`. `install.sh` symlinkkaa agentit ja komennot sinne **per
tiedosto** ja skillit **per hakemisto**, jotta muiden lähteiden tiedostot eivät korvaudu.

### INV-OWN

> Asentaja saa luoda, korvata tai poistaa vain polun, joka **puuttuu** tai on **symlink, jonka
> kohde resolvoituu paketin juuren sisään**. Kaikki muu on vierasta ja koskematonta.

Kolme johdannaista, luettavina kieltoina:

1. **Omistajuus luetaan levyltä, ei manifestista.** Manifest voi vanhentua ja antaisi silloin
   poisto-oikeuden tiedostoon, jota paketti ei enää toimita. Symlinkin kohde ei voi valehdella.
2. **Suunnittelu ja soveltaminen ovat eri vaiheet.** Kaikki tarkistukset ensin, mitään ei
   kirjoiteta; yksikin kieltäytyminen ⇒ nolla muutosta. Tarkista-ja-kirjoita samassa silmukassa
   jättäisi puun puoliksi asennetuksi — juuri se hiljainen osittaisvirhe, jonka takia asentaja
   on olemassa. Sama plan-then-apply -jako on `run-epic.sh`:ssa ja `stop-run.sh`:ssa.
3. **Asentaja ei kutsu `launchctl`ia.** Ks. §10.

**Skills on tarkoituksella lievempi:** vieras hakemistosymlinkki tuottaa `conflict`in (exit 4),
ei `refuse`a (exit 2). Kieltäytyminen on koko ajon laajuinen, ja agents/commands-kohdalla se
suojaa **ydintoiminnallisuutta** — ilman niitä runner ei toimi. Skill on lisätieto; refuse
siellä kaataisi myös ydinasennuksen.

Riippuvuustarkistus (`lib/preflight.sh`) on asentajassa **neuvoa-antava**, orkestraattorin
S0-portissa fataali. Sama lähde, eri vakavuus.

## 4. Tilakone

Lähde: `orchestrate.sh`:n otsikkokommentti + `enter_state`-kutsut,
`docs/diagrams/run-issues-state-machine.mmd`.

```
S0 Preflight → S1 PickIssue → S2 Lock → S2b BlockedCheck → S2c EpicCheck → S3 Claim
   → S4 Worktree → S5 DBClone → S6 CycleReview → [S7 Review-portti]
   → S7b EnvBootstrap → S7c ProvisionTestEnv → S8 Implementer → S9 Evolution
   → S10 Push → S11 PRCreate → S12 Finalize
```

### Porttien säännöt

**Kaikki portit ovat fail-closed:** lukukelvoton tieto tulkitaan estoksi. Tämä on tietoinen
valinta joka portissa, ei sattumaa.

- **S2b BlockedCheck ja S2c EpicCheck ovat autoritatiivisia, koska hakuindeksi ei ole.**
  Poimintahaun suodattimet lukevat GitHubin *eventually consistent* -indeksiä; kerran laahaava
  indeksi päästi 25 estettyä issueta poimintaan peräkkäisinä tikkeinä. Siksi molemmat portit
  lukevat totuuden **suoraan** (`count_open_blockers` dependencies-API:sta, `is_epic`
  labeleista). Halpa esikarsinta hakukyselyssä säilyy, se ei korvaudu.
- **Sijainti lukon jälkeen, claimia ennen** on molemmilla sama ja tarkoituksellinen: vain lukon
  voittaja maksaa API-kutsun, eikä estettyä issueta koskaan assignata itselle.
- **Claimia edeltävät portit eivät lisää `needs-human`-labelia.** Ne poistuvat ennen claimia,
  issue ei ole meidän, ja aito `blocked_by` jatkuu itsestään kun estäjä sulkeutuu — se on
  odotustila, ei ihmisen tarve. Sama koskee S0-preflightiä.
- **Epic ei ole ajettava.** `auto-run` epicillä on **propagointisignaali**, ei ajosignaali:
  se tarkoittaa "lisää `auto-run` epicin avoimille alaissueille". Jos epic poimittaisiin,
  implementer polttaisi koko timeout-budjetin tehtävään jota ei ole.
- **Nimetyn ajon voi aina pakottaa `--force`illa.** Fail-closed-portti ei saa olla syy siihen,
  ettei ajo käynnisty toimivalla koneella. Sama periaate: `RUN_ISSUES_SKIP_PREFLIGHT`,
  `RUN_ISSUES_RATE_LIMIT_BACKOFF=0`, `RUN_ISSUES_SELF_UPDATE=0`, `RUN_ISSUES_ARCHIVE_AFTER_DAYS=0`.

### Claimin jälkeinen esto labeloidaan aina

Terminaalinen esto claimin jälkeen lisää issuelle **aina** `needs-human`-labelin
(`_add_needs_human_label`) situation-kommentin lisäksi. **Pelkkä kommentti ei riitä: se ei ole
suodatettava**, joten jumiin jäänyt ajo näytti GitHubissa samalta kuin normaali kesken oleva —
yksi hiljainen esto pysäytti kuuden issuen riippuvuusketjun yön yli. `cleanup-run.sh` poistaa
labelin, joten elinkaari on suljettu.

### Varaus on label, ei assignaatio (#99)

`claim_issue` assignoi saman tilin jolla ihminenkin assignoi, joten "ihmisen assignaatio" ja
"runnerin varaus" eivät olleet erotettavissa. Varaus on nyt **vain automaation kirjoittama**
`auto-claimed`-label, ja poiminta suodattaa sillä (`no:assignee` poistui) — käsin assignattu
issue lähtee ajoon. `verify_claim`in sääntö: **assignee-joukko claimin jälkeen == joukko ennen
∪ {@me}**. Etukäteen tehty assignaatio ei kaada ajoa, kilpaileva toinen tili huomataan yhä.

Label sidotaan `claim_issue`/`unclaim_issue`iin **rakenteellisesti**. Blocked/stalled-finalisoinnit
**eivät** poista sitä: estynyt ajo pysyy varattuna siivoukseen asti.

### Vastattavat kommentit ja jatkomoodit

Terminaalinen `blocked/*`-esto upottaa situation-kommenttiin `awaiting-answer`-markerin. Kun
ihminen vastaa, pollerin `scan_blocked_answered` siivoaa ajon (`cleanup-run.sh --issue`,
**issueta ei suljeta**) ja issue tulee poimituksi normaalisti uutena ajona tuoreesta basesta —
ei vanhan run-dirin jatkamista, koska blocked-ajon worktree on tyypillisesti haarautettu ennen
esteen poistanutta mergeä.

**Silmukkaraja on rakenteellinen ilman laskuria:** uudelleen blocked päättyvä ajo postaa uuden
markerin, ja vastaus vaaditaan *uusimman* markerin jälkeen ⇒ yksi kommentti = korkeintaan yksi
yritys.

Timeout-polku on **ei-vastattava**: se jatkuu `--restart`illa ramppaavalla timeoutilla, ei
kommentilla. Tarkennussilmukka jatkuu `--continue`lla.

## 5. Mitattu — älä riko

Nämä neljä sääntöä syntyivät tuotantohäiriöistä ja mittauksista. Jokainen niistä on sellainen,
että koodi näyttää oikealta ilman sääntöäkin.

### 5.1 Kutsua ei saa koskaan portittaa kiintiölukemalla

2026-08-29 luettiin `gh api rate_limit`, tehtiin kolme kutsua ja luettiin uudelleen: `search`-,
`graphql`- ja `core`-laskurit **eivät liikkuneet lainkaan**. Estotilan aikana sama endpoint
raportoi `graphql 5000/5000, used 0` samalla kun jokainen kutsu kaatui. **Estävä raja on
sekundäärinen eikä ole näkyvissä.**

Siksi rate-limitin havainto on **tekstuaalinen** (`rate_limit_matches` gh:n virhetekstille), ei
mittariin perustuva. Tilatiedosto on **molempien pollerien jakama** — ne kuluttavat samaa
kiintiötä, joten toisen perääntyminen ei auta jos toinen jatkaa. `status.sh` lukee takarajan
muttei **koskaan kirjoita** sitä: sivun päivityksen ei kuulu voida hidastaa pollereita.

### 5.2 Hakuyhteys on erikseen estettävissä — siksi listaukset ovat REST:iä

`gh issue list` reitittää **`--label`-suodatetun** kyselyn GraphQL-`search`-yhteyden kautta;
pelkkä `--state` ei. Tuo yhteys oli estettynä **27 tuntia** 2026-08-28/29 samalla kun REST
vastasi normaalisti. Mittaus yhdellä repolla, **suodattamaton kontrolli lomitettuna**:

| Kutsumuoto | Tulos |
|---|---|
| `gh issue list --limit 1` (kontrolli) | OK ×3 |
| `gh issue list --label X --state all` | torjuttu |
| `gh issue list --search "…"` | torjuttu |
| `gh issue list --state open`, `gh pr list`, `gh issue view` | OK |
| `gh api repos/…/issues?labels=…` | OK |

**Kontrolli on koko koe.** Ilman sitä molemmat haarat kaatuvat ja johtopäätös olisi "tili on
estetty" — mikä johti aiemmin väärään diagnoosiin.

Kaksi seurausta, jotka eivät ole pelkkiä käännöksiä:

1. **Negatiiviset labelisuodattimet paranivat.** `-label:x` epäonnistui **auki**: tuntematon
   negatiivinen kvalifikaattori täsmää kaikkeen, joten kirjoitusvirhe vuoti poissuljettuja
   issueita poimintaan. jq:n `index()`-jäsenyystesti epäonnistuu umpeen.
2. **`-is:blocked` katosi.** Sillä ei ole REST-vastinetta, ja pelkkä poisto **linkoaisi**: S2b
   torjuu estetyn issuen ennen claimia, joten sama issue poimittaisiin joka tikki ikuisesti.
   Tilalla ehdokkaiden koettaminen `count_open_blockers`illa vanhimmasta alkaen
   (`RUN_ISSUES_PICK_BLOCKED_PROBES`).

REST **ANDaa** `labels=`-listan kuten erilliset `label:"x"`-termit, ja REST `/issues` palauttaa
**myös PR:t** — `.pull_request` on aina suodatettava pois.

### 5.3 `state.jsonl`iä ei lueta kokonaan missään koodipolussa

Vain `tail -n N` on sallittu. Mitattu: 256 run-diriä, `state.jsonl` yhteensä **345 MB** ja
1,19 M tapahtumaa, joista **>99,7 %** oli PR-vahdin toistuvaa kolmikkoa (suurin yksittäinen
tiedosto 6,7 MB). `scan_stalled`, `status.sh` ja `pr_last_decision` lukevat kaikki hännän.

### 5.4 Kustannusinvariantti: kysy työstä, älä historiasta

Toistuva vika: skannaus, jonka hinta on `O(historialliset run-dirit)` eikä `O(työ)`.
Kolme mitattua tapausta samasta juuresta:

| Paikka | Ennen | Korjaus |
|---|---|---|
| `scan_clean` | 337 GraphQL-kutsua/tikki (~4000/h) — yksi `gh issue view` per paikallinen issue | Kysy **labelia**, ei issueita: yksi listaus per repo, leikkaus muistissa |
| `status.sh --github` | 318 turhaa `gh issue view`iä/päivitys | Suljettu issue on **terminaalitila** ⇒ detail kannetaan cache-missin yli |
| PR-vahdin skannaus | 798 hakua/h, ~kaikki jo suljettujen PR:ien uudelleentarkistusta | Lopullisuustarkistus **haun eteen** paikallisesta tilasta |

**Vartija on kutsumäärä, ei valinta.** Valintaportit voivat pysyä vihreinä samalla kun kustannus
palaa lineaariseksi, joten testit assertoivat kutsumäärän eksplisiittisesti gh-shimillä
(`test-scan-clean.sh`, `test-pr-watch-scan-cost.sh`, `test-status-github.sh`) eivätkä päättele
sitä tuloksesta.

Kaksi tukirakennetta: run-dirien arkistointi (`lib/archive.sh`) siirtää terminaalitilaiset
run-dirit pois kuumilta poluilta, ja lokirotaatio (`lib/log-rotate.sh`) tukkii saman rajattoman
kasvun `.runs.log`ista (mitattu 190 MB).

### 5.5 Testien on tehtävä kahdella koneella sama asia

`orchestrate.sh` ja `pr-watch.sh` sourceavat koneen env-tiedoston prosessin sisällä. Tiedosto
on käsin kirjoitettua shelliä täynnä `export FOO=bar` -rivejä, ja **`export` voittaa
komentoetuliitteen** — joten sourceaus ylikirjoitti kutsujan tietoisen valinnan. Testit
stubbaavat agentin `RUN_ISSUES_CLAUDE_CMD`illa, joten koneella jonka env-tiedosto exporttaa
oikean CLI:n `tests/run-all.sh` **käynnisti oikeita, laskutettavia 3600 s agenttiajoja**
väliaikaisrepoa vasten (mitattu 2026-08-31). Mikään tuloste ei kertonut siitä.

Korjaus on `lib/machine-env.sh`:n **nimiavaruussääntö, ei poikkeuslista:** `RUN_ISSUES_*` ja
`PR_WATCH_*` ⇒ kutsujan jo asettama arvo voittaa tiedoston (asetettu tyhjäksi = asetettu);
kaikki muu (salaisuudet, joita kukaan ei aseta käsin) säilyttää `tiedosto voittaa` -semantiikan.
**Poikkeuslista olisi väärä muoto** — se jättäisi seuraavan lisätyn muuttujan kattamatta, mikä
on täsmälleen se tapa jolla tämä vika säilyi.

### 5.6 Havainto sidotaan tilaan, ei tekoon

`pr-watch.sh` ajoi purun vain siinä haarassa, jossa vahti **itse** mergesi. Jokainen muu reitti
mergeen — toisen koneen vahti, web-UI, käsin ajettu `gh pr merge`, rotaatiokursorin
nälkiinnyttämä repo — jätti artefaktit ikuisesti, ja §5.5:n vaimennuksen jälkeen **hiljaa**.
Mitattu Studiolla: 331 ajoa, 314 luokassa `cleanup`, **309 worktreetä levyllä = 166,9 GB**.

Pollerin `scan_finished` päättää nyt **mitkä** ajot ovat valmiita ja delegoi **miten**
`cleanup-run.sh`ille. Kaksi sääntöä, jotka on helppo rikkoa vahingossa:

- **Sovitus ei kommentoi, ei labeloi eikä koskaan sulje issueta.** Se reagoi sulkemiseen, joten
  sen aiheuttaminen tekisi signaalista itsensä toteuttavan — ja 300+ kommentin ryöppy olisi
  haitallisempi kuin ongelma jonka se ilmoittaa.
- **Viisi fail-closed-porttia:** elävä ajo, vieras host, issue ei varmistetusti kiinni, avoin PR,
  ja **pushaamattomat commitit haaralla** (`git branch -D` on tuhoava; S10:n `--set-upstream`
  tekee "onko pushattu" paikallisesti ratkaistavaksi).

Takautuva 166,9 GB:n purku on erillinen valvottu kertaoperaatio.

### 5.7 Lokikohina vaimennetaan tarkoituksella

Yksi rivi per ohitettu tikki, ei per kutsu. Alkuperäinen häiriö kirjoitti **1754 identtistä
riviä** eikä yksikään niistä ollut signaali. Sama periaate: `SKIP_CLOSED`in ensimmäinen
siirtymä kirjataan, toisto vaietaan.

**Poikkeus, joka on yhtä tärkeä:** epäonnistunut haku (`SKIP_UNKNOWN`) on aina lokitettava
mutta **ei koskaan kirjattava `state.jsonl`iin päätöksenä**. Tyhjä payload tarkoittaa että haku
epäonnistui, ei että PR on kiinni — ja väärä kirjaus opettaisi hännästä luettavaan historiaan
päätöksen, joka pudottaisi PR:n ajosta pysyvästi.

## 6. Exit-koodit

**Jokaisella suoritettavalla skriptillä on oma exit-koodiavaruutensa** — sama numero tarkoittaa
eri asiaa eri skripteissä. Älä yhtenäistä niitä.

Lähde on kunkin skriptin otsikkokommentti (`# Exit codes:`). `tests/test-readme.sh` **johtaa
README:n odotukset suoraan näistä**, joten uusi koodi ilman README-riviä on punainen testi.
Täydet taulukot: `README.md` §9.

Sanasto, joka toistuu avaruuksien yli: **0** onnistui tai siisti no-op · **1** käyttövirhe ·
**2** kieltäydytty / ei kohdetta, mitään ei muutettu · korkeammat koodit = tilakohtainen
lopputulos (esto, kilpailu, timeout, odottaa ihmistä).

## 7. `lib/`-rakenne

Yksi rivi per moduuli. Jos tarvitset funktiotason yksityiskohtia, lue tiedosto.

| Tiedosto | Vastuu |
|---|---|
| `action-service.py` | **Ainoa Python-tiedosto.** Ohjaamon HTTP + auth -ydin: fail-closed `tailscale whois`, kolmikerroksinen CSRF, audit-loki, `execve` dispatcheriin — ei koskaan koske gh:hun itse |
| `action-token.sh` | Ohjaamon jaettu CSRF-token. Bearer-salaisuus: ei koskaan `status.json`iin, lokiin eikä kommenttiin |
| `archive.sh` | Terminaalitilaisten run-dirien siirto `run-issues-archive/`iin. PR-suoja on paikallinen, ei gh-kutsu |
| `claude-call.sh` | Yksittäisen orkestroidun askeleen claude-CLI-kutsu (timeout, lokitus, finalisointi) |
| `env-bootstrap.sh` | Pakettimanagerin tunnistus S7b:n fail-fast-asennusporttiin |
| `epic.sh` | Epic-tason automaatio: ajolabelien propagointi, `needs-human`-eskalaatio, valmiuskommentti. Best-effort (aina rc 0) |
| `git-remote.sh` | Multi-remote-apurit: yksi klooni voi pollata useaa GitHub-orgia |
| `github-app-auth.sh` | Opt-in GitHub App -identiteetti. Kattaa kirjoitukset **ja** raskaimmat luvut |
| `gitignore.sh` | Pitää **kohderepon** `.gitignore`n ignoroimassa ajoaikaiset artefaktit |
| `hook-runner.sh` | Synkroninen commit, joka ajaa post-commit-hookit loppuun ennen paluuta |
| `issue-images.sh` | Issuen kuvien poiminta ja lataus, jotta agentit näkevät ne |
| `issue.sh` | GitHub-issue-operaatiot. Sisältää paketin **ainoan** poimintakyselyn (`pick_oldest_candidate`) ja lapsijoukon **ainoan** resolvoinnin (`list_epic_children`) |
| `labels.sh` | Label-hallinta REST-API:n kautta (ei `gh issue edit --add-label`) |
| `locking.sh` | Issue-kohtainen lukkohakemisto, atominen `mkdir(2)`:lla |
| `log-rotate.sh` | Kokoon perustuva lokirotaatio. Erillään `poller-config.sh`:sta, jotta sen puhtausväite säilyy — tämä kirjoittaa levylle |
| `machine-env.sh` | Koneen env-tiedoston sourceaus **kutsujan etuoikeudella** (§5.5). Jaettu `orchestrate.sh`:n ja `pr-watch.sh`:n kesken, jotta sääntö on yhdessä paikassa |
| `poller-config.sh` | Host-portti ja watchlistin resolvointi **puhtaina funktioina**. Erillinen, koska poller itse exittaa source-hetkellä vieraalla koneella eikä olisi testattavissa |
| `pr-watch-lib.sh` | PR:n luokittelu ja merge-päätös irrotettuna testattavaksi |
| `preflight.sh` | Jaettu riippuvuustarkistus. Korjauskomennot yhdestä lähteestä (`preflight_install_hint`) |
| `rate-limit.sh` | Rate-limitin **tekstuaalinen** tunnistus ja jaettu perääntyminen (§5.1) |
| `run-terminate.sh` | Elävän ajon turvallinen lopetus **kutsuttavana funktiona**. Irrotettu pollerista, joka `exit 0`si source-hetkellä; `stop-run.sh` ja `run-epic.sh --stop` käyttävät samaa polkua monistamatta turvalogiikkaa |
| `state.sh` | Ajon durable-tila `<run-dir>`-hakemistossa |
| `status-github.sh` | `status.sh --github`-rikastus. Ei omaa CI-rollupia eikä merge-päätöstä — kutsuu `pr-watch-lib.sh`:n omia |
| `status-read.sh` | `status.sh`:n puhtaat luku- ja luokittelufunktiot. `_iso_to_epoch` asuu täällä, jotta poller ja näkymä laskevat iän identtisesti |
| `version.sh` | Ajossa olevan version ja submodule-pinnin näkyväksi teko. Fail-soft: puuttuva `.git` ⇒ `?` |
| `worktree.sh` | Ajokohtaiset git-worktreet kohderepossa |
| `issue.test.sh`, `render-prompt.test.sh` | Yksikkötestit (`verify_claim`, `render_prompt`) |

**Jaetut primitiivit — älä monista.** Kolme kohtaa, joissa kahden toteutuksen ajautuminen on
aiemmin ollut oikea vika: poimintakysely (`pick_oldest_candidate`), epicin lapsijoukko
(`list_epic_children` — **myös näkymä kutsuu tätä**, joten näkymä ja ajo eivät voi olla eri
mieltä) ja ajon lopetus (`run_terminate`).

## 8. Ympäristömuuttujat

Nimet, oletukset ja vaikutukset: `docs/env-reference.md` (täysi) ja `README.md` §5
(asennusaikainen osajoukko). Tässä vain säännöt, jotka eivät näy taulukosta.

**Toimituskanava.** launchd ei anna agentille omaa ympäristöä, eivätkä login-tiedostot sisällä
mitään run-issues-kohtaista. LaunchAgent-ajossa — **ainoassa tuotantotilassa** — `poller.env`
on siis ainoa kanava, jolla kone voi konfiguroida itsensä. Se **sourcetaan**, joten **tiedosto
voittaa ympäristömuuttujan**. Poikkeuksia kaksi, molemmat rakenteellisia: `RUN_ISSUES_HOME` ja
`RUN_ISSUES_POLLER_ENV_FILE` resolvoidaan ennen sourcea.

Saman `poller.env`in lukevat kaikki LaunchAgentit: molemmat pollerit, `status-render.sh`,
`self-update.sh` ja `action-server.sh`. Yksi konekohtainen tiedosto konfiguroi kaikki.

**Kaksi env-tiedostoa, vastakkaiset etuoikeudet.** Tämä on helppo sekoittaa, ja sekoittaminen
maksoi kerran oikeita agenttiajoja (§5.5):

| Tiedosto | Kuka lukee | Etuoikeus |
|---|---|---|
| `poller.env` | LaunchAgentit | **Tiedosto voittaa** ympäristömuuttujan — se on koneen ainoa konfigurointikanava |
| `env` (salaisuudet) | `orchestrate.sh`, `pr-watch.sh` | **Kutsuja voittaa** `RUN_ISSUES_*`- ja `PR_WATCH_*`-nimiavaruudessa; muualla tiedosto voittaa (`lib/machine-env.sh`) |

**Pollerit eivät lue `env`-tiedostoa lainkaan.** Se sisältää salaisuudet, poller ei tarvitse
niistä yhtäkään ja lokittaa runsaasti ⇒ salaisuudet pidetään sen prosessin ulkopuolella.
`tests/test-poller-config.sh` vartioi tätä.

**Watchlist:** `RUN_ISSUES_WATCHLIST` asetettuna on **ainoa** ehdokas — osumaton override on
virhe, ei fallback. Ilman overridea: `$HOME/.config/run-issues/watchlist.json` →
`$HOME/dotfiles/machine-studio/…` (legacy, §13).

**Testien injektiopisteet, eivät käyttäjäkonfiguraatiota:** `RUN_ISSUES_HOME`,
`RUN_ISSUES_CLAUDE_HOME`, `RUN_ISSUES_LAUNCH_AGENTS_DIR`, `RUN_EPIC_ORCHESTRATE`,
`RUN_EPIC_STOP_RUN`, `RUN_ISSUES_SELF_UPDATE_INSTALL`, `RUN_ISSUES_DIGEST_GWS`. Kahdella
ensimmäisellä on yksi syy: **testit eivät saa koskea oikeaan `~/.claude`-hakemistoon**, koska
sitä ajaa poller samalla koneella. Siksi jokainen polku johdetaan `$HOME`:sta tai overridesta —
tildelaajennusta ei käytetä missään, jotta `HOME=$(mktemp -d)` todella pitää.

## 9. Opt-in-mekanismit

**Kaikki on pois päältä oletuksena, ja puuttuva konfiguraatio on hyvänlaatuinen no-op, ei
virhe.** Tämä on koko listan kantava sääntö.

| Mekanismi | Aktivoituu | Ilman sitä |
|---|---|---|
| `status.sh --github` | lippu | jokaisen ajon `github` on `null`, `epics[]` tyhjä |
| `lib/github-app-auth.sh` | App-env-muuttujat | paljas `gh`, henkilökohtainen kiintiö |
| `db-clone/` | kohderepon `.claude/db-clone.json` | S5 no-op |
| `provision-test-env` | kohderepon `.claude/provision-test-env.sh` | S7c no-op |
| `status-digest.sh` | `gws` + vastaanottaja | runko stdoutiin, exit 0 |
| Ohjaamon toimintopalvelu | `RUN_ISSUES_ACTION_BASE` **ja** host-portti | sivu on puhdas lukupinta, ei nappeja |
| `PR_WATCH_ENABLE_CONFLICT_RESOLUTION` | poller nostaa `1`:ksi | konflikti jää ihmiselle |
| `PR_WATCH_ENABLE_CI_REPAIR` | poller nostaa `1`:ksi | punainen CI ⇒ `WAIT_CI` |

Neljä sääntöä, jotka eivät näy taulukosta:

- **Rikastus ei saa muuttaa lopputulosta, vain tarkkuutta.** `--github` nostaa
  `class_confidence`in ja tarkentaa syytä; yhden repon verkkovirhe → `repos_failed`, sen ajot
  jäävät `github: null`, muut rikastuvat, exit-koodi ennallaan.
- **CI-korjaus ei saa viherryttää CI:tä huijaamalla** (testin poisto, assertion löysäys,
  `skip`). Tämä on promptin **ja** pakollisen CI-revalidoinnin vartioima ehdoton rajoite.
  Turvaportti on revalidointi, ei luottamus agenttiin.
- **Käynnistysvirhettä ei saa raportoida löydöksenä.** `rc=127` (CLI puuttuu) on eri asia kuin
  "agentti ei löytänyt korjausta", ja yrityskatto ei saa kulua agenttiin joka ei koskaan
  käynnistynyt. Siksi preflight ajetaan **ennen** yritys-eventtiä.
- **`needs-human` on pidätyslippu.** Sen ollessa paikallaan vahti ohittaa ajon hiljaa (ei
  uudelleenkommentointia joka tikillä); kun ihminen poistaa sen, ajo re-armataan.

Ohjaamon toimintopalvelu delegoi neljä toimintoa `execve`llä olemassa oleville skripteille —
**ei riviäkään uutta purku-, merge- tai restart-logiikkaa**. Python ei koske gh:hun eikä
labeleihin. Turvamalli: `README.md` §7.9.

## 10. LaunchAgent-invariantit

- **launchd tunnistaa agentin `Label`ista, ei tiedostonimestä.** Uuden plistin lataaminen ei
  korvaa vanhaa: ilman `bootout`ia koneella ajaisi kaksi polleria samasta koodista, jakaen
  watchlistin ja kilpaillen samasta rinnakkaisuuskatosta. Konventio: `Label` == tiedostonimi
  ilman `.plist`, `plutil -lint` porttina. Historiallinen `com.maintainer.*` → `com.claude-issue-runner.*`
  -migraatio: `README.md`.
- **`$HOME` laajenee plistissä vain `ProgramArguments`issa**, koska laajennuksen tekee
  `/bin/bash -l -c` -kääre. `StandardOutPath`/`StandardErrorPath` ovat launchd:n omia avaimia
  eikä se laajenna niissä mitään ⇒ literaali `$HOME` osuisi hakemistoon nimeltä `$HOME`. Siksi
  **plisteissä ei ole näitä avaimia lainkaan**: jokainen skripti omistaa lokipolkunsa itse ja
  ohjaa oman stdout/stderrinsä `$RUN_ISSUES_LOG_DIR`iin. Vaihtoehto (materialisoidut polut)
  rikkoisi INV-OWNin, koska kopiossa ei ole symlinkkiä omistajuuden merkkinä.
- **`install.sh` ei kutsu `launchctl`ia**, se tulostaa komennot: launchd mutatoi elävää
  käyttäjäsessiota, kutsu ei ole idempotentti uudelleenohjatun `$HOME`:n alla eikä siis
  testattavissa, ja migraatio vaatii harkitun kertaluontoisen bootoutin.
- **Deploy kieltäytyy, jos plistin ohjelmapolku ei resolvoidu** (exit 2). Rikkinäisen agentin
  asentaminen olisi asentamatta jättämistä pahempaa: launchd lataisi sen, epäonnistuisi joka
  tikillä eikä raportoisi mitään. "Resolvoituu" on laajempi kuin `[ -x ]` — plan-then-apply
  (INV-OWN 2) tarkoittaa että polku voi olla vasta suunnitelmarivi, joten `program_resolves`
  hyväksyy myös `SCRIPTS_BINDING_TARGET`in kautta resolvoituvan polun. Tämä tekee `main()`:n
  järjestyksestä kantavan.
- **Neljä agenttia tikkaa `StartInterval`illä, yksi on daemon.** `action-server.sh` pitää
  kuuntelevaa socketia ⇒ `KeepAlive`. `KeepAlive.SuccessfulExit=false` hoitaa kaksi asiaa
  yhdellä: host-portti (vieras kone → exit 0 → ei uudelleenkäynnistystä) ja bind-toipuminen
  (Tailscale ei vielä ylhäällä bootissa → exit ≠ 0 → uusi yritys). `self-update.sh` on
  tarkoituksella **tikkaava eikä daemon**, jottei epäonnistunut `install.sh` crash-looppaisi.

## 11. Soft-riippuvuus: `POST_COMMIT_SYNC=1`

`orchestrate.sh` exporttaa sen, ja `lib/hook-runner.sh` ajaa committinsa sen kanssa. Lippu
kertoo dotfilesin post-commit-hookille, että se saa ajaa dokumenttipäivitys- ja
turvatarkistuscommitit **synkronisesti loppuun**, jotta ne päätyvät samalle feature-haaralle.

**Paketti ei vaadi tätä hookia.** Ilman sitä lippu on merkityksetön ympäristömuuttuja.

Vastapari: `pr-watch.sh` **ei** aseta lippua — merge-jälkeinen työ ajetaan mainissa, jossa
synkroninen hookketju ei ole toivottu.

## 12. Testien ajo

```bash
bash tests/run-all.sh        # paketin juuresta
bash tests/test-<nimi>.sh    # yksittäinen
```

- Plain bash, ei framework. `set -uo pipefail` — **ei `-e`**: testin pitää kerätä kaikki
  virheet, ei kaatua ensimmäiseen.
- Puuttuva esiehto (ei `jq`:ta, ei tietokantaa, väärä host) ⇒ `SKIP: <syy>` ja **exit 0**.
  Paketin on oltava testattavissa ilman ylläpitäjän ympäristöä.
- `run-all.sh` poimii globilla — uusi testi tulee ajoon nimeämällä.

Testipaketti ajaa ilman dotfiles-kontekstia ja on samalla rakenteen regressiosuoja: jokainen
testi resolvoi `$HERE/../lib/…`, joten hakemistosiirto rikkoisi ne välittömästi.

## 13. Tunnetut avoimet asiat

**Tietoiset ei-päätökset** (älä "korjaa" näitä ilman keskustelua):

- **PR-vahdin merge-strategia on kiinteä, ei konfiguroitava.** Ensin `--rebase`, sitten
  `--merge`. Torjunta on *pysyvä, ei ohimenevä*: GitHub kieltäytyy rebase-mergestä aina kun
  haaralla on merge-commit, eikä haaran muoto muutu itsestään — ilman varapolkua yksi
  rebase-kyvytön PR jumittaisi koko riippuvuusjonon. `PR_WATCH_MERGE_STRATEGY` rajattiin ulos
  cycle reviewssä ei-minimaalisena.
- **Ihmiseen viitataan roolilla — ei nimellä eikä `{{HUMAN}}`-muuttujalla.** #153 poisti
  kovakoodatun nimen 33 tiedostosta ja korvasi sen kontekstin mukaisella roolilla ("issuen
  kirjoittaja", "käyttäjä", "ylläpitäjä", "ihminen"). Parametrisointi jäi silti tekemättä:
  se kattaisi vain `prompts/`, koska `render_prompt` ei koske komentoihin eikä agentteihin —
  Claude Code lukee ne suoraan levyltä. Roolisana toimii kaikissa kolmessa ilman mekanismia,
  joten puoliksi parametrisoitu olisi yhä huonompi kuin kumpikaan puhdas vaihtoehto (#9).
  Toiminnallista vaikutusta ei ole: bot ja ihminen erotellaan markerin aikaleimalla, ei
  nimellä.

**Legacy-shimit** (poistettavissa vasta kun ehto täyttyy):

- `POLLER_HOSTS_LEGACY_DEFAULT` — sisäänrakennettu konenimilista. Tietoinen poikkeus §1:n
  lupaukseen: ilman sitä auto-run-kone pysähtyisi mergehetkellä, mikä oli epicin nimenomainen
  ei-tavoite. Poistuu kun kone asettaa `RUN_ISSUES_POLLER_HOSTS`:n `poller.env`iinsä.
  `tests/test-poller-config.sh` pinnaa listan, jotta muutos on päätös eikä vahinko.
- **Dotfiles-fallback watchlistille** — kulkee yhden nimetyn muuttujan (`LEGACY_DOTFILES_DIR`)
  kautta, jotta "riippuuko tämä yhä vanhasta rakenteesta?" on yhden rivin kysymys.

**Odottaa dotfiles-repon puolen työtä (#5):**

- `~/.claude/skills` on ylläpitäjän koneella hakemistosymlinkki ⇒ `install.sh` tulostaa
  conflict-rivin ja exit 4:n, ja `skills/claude-issue-runner` jää asentumatta. **Ei bugi vaan
  odotettu välitila** (agents/commands on jo jaettu per tiedosto).

**Aidot puutteet:**

- `install.sh --uninstall` puuttuu. Omistajuuspredikaatti riittäisi sellaisenaan toteutukseen.
- `commands/factory-run.md` viittaa puuttuvaan `templates/factory-init.sh`-skriptiin.
- **5/13 `docs/diagrams/*.mmd` ei parsiudu** mermaid-cli 11.16.0:lla, eikä syntaksilla ole
  vartijaa. #12 jätti sen tietoisesti tekemättä, koska sen premissi (diagrammit ovat valideja)
  osoittautui vääräksi. Rikkinäinen diagrammi renderöityy tyhjäksi.
- **`state.jsonl`-massan takautuva tiivistäminen.** Kasvun lähde on tukittu kahdesti (#65
  kirjoitukset, #130 haut) ja arkistointi (#128) siirtää massan pois kuumilta poluilta, mutta
  jo levyllä olevan 345 MB:n kutistaminen on oma päätöksensä.

**Skillin sisältöä vartioi kaksi testiä.** `tests/test-skill-labels.sh` johtaa labelisanaston
**koodista** ja vaatii skilliltä jokaisen — koodiin lisätty label ilman skill-riviä on punainen
testi. Fail-closed: jos johdettu joukko kutistuu alle kahdeksan alkion tai ankkuri `needs-human`
katoaa, testi kaatuu sen sijaan että läpäisisi tyhjästä. `tests/test-skill-surface.sh` tekee
saman komentopinnalle molempiin suuntiin.
