# Ympäristömuuttujat — täysi referenssi

Tämä on paketin **täysi** ympäristömuuttujaluettelo. Se irrotettiin `CLAUDE.md`:stä, koska
se on hakuteos eikä joka session kontekstia.

**Lähdejärjestys, kun tämä ja koodi ovat eri mieltä:** skriptin otsikkokommentti (`# Env:`)
ja koodin `${VAR:-oletus}` ovat lähde, tämä tiedosto on peilaus. `README.md` §5 listaa
näistä asennus- ja konfigurointiaikaisen osajoukon ihmiselle.


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
| `RUN_ISSUES_PICK_BLOCKED_PROBES` | `20` | Montako poimintaehdokasta enintään koetetaan `count_open_blockers`illa ennen kuin tikki luovuttaa (#133). `-is:blocked`illa ei ole REST-vastinetta, joten esto tarkistetaan ehdokas kerrallaan vanhimmasta alkaen ja pysähdytään ensimmäiseen vapaaseen. Tavallinen hinta on **yksi** koetus (riippuvuusketjussa vanhin lapsi on se ajettava); katto estää kokonaan estetyn backlogin kävelemisen joka tikillä. Katon täyttyminen = "ei ehdokasta", seuraava tikki yrittää uudelleen |
| `RUN_ISSUES_RATE_LIMIT_BACKOFF` | `1` | `0` = poista perääntyminen käytöstä (#126). Hätävara samalla perusteella kuin `RUN_ISSUES_SKIP_PREFLIGHT`: uusi portti ei saa koskaan olla syy siihen, ettei ajo käynnisty toimivalla koneella. Luetaan kummassakin pollerissa, `pr-watch.sh`:ssa ja `status.sh`:ssa |
| `RUN_ISSUES_CLEAN_SCAN_LIMIT` | `200` | **Vain `poller.sh`:n `scan_clean`.** Montako riviä siivouslabelin repo-laajuinen listaus hakee (#124). Ylittyessään lista ei enää todista poissaoloa, joten kattamattomat paikalliset issuet luetaan yksitellen ja lokiin tulee WARNING. Nosto on halpa; oletus riittää kunnes labeloituja issueita on ≥200 |
| `RUN_ISSUES_FINISHED_SCAN_LIMIT` | `500` | **Vain `poller.sh`:n `scan_finished`.** Montako riviä avoimien issueiden ja avoimien PR:ien repo-laajuiset listaukset hakevat (#107). Sama katkaisusemantiikka kuin `RUN_ISSUES_CLEAN_SCAN_LIMIT`illa, mutta **päinvastaisesta syystä**: `scan_clean` kysyy harvinaista labelia, tämä kysyy *avoimien* joukkoa ja käyttää poissaoloa **sulkeutumisen todisteena** — katkaistu lista ei todista mitään, joten kattamattomat ehdokkaat luetaan yksitellen (`_rest_issue_path`/`_rest_pull_path`) ja lokiin tulee WARNING. Katkaisu saa maksaa **kutsuja, ei ohituksia** |
| `PR_WATCH_GLOBAL_MAX` | *(watchlistin `pr_watch_max_concurrent`, tai sen puuttuessa `global_max_concurrent`)* | **Vain `pr-watch-poller.sh`.** PR-vahdin oma rinnakkaisuuskatto (#47). PR-skannaus on sekuntien työ, joten se voi käydä selvästi korkeammalla katolla kuin kymmenien minuuttien orkestraattoriajot ilman että `poller.sh`:n rinnakkaisuus kasvaa. Ympäristömuuttuja voittaa watchlist-avaimen |

Watchlistin resolvointijärjestys ilman overridea: `$HOME/.config/run-issues/watchlist.json` →
`$HOME/dotfiles/machine-studio/run-issues-watchlist.json`. Jälkimmäinen on **vain fallback**
(ks. §12); ensisijainen polku ei koskaan ole dotfiles-puu.

**Siivousskannauksen kustannusinvariantti (#124).** `scan_clean` kysyy **labelia, ei issueita**:
yksi `gh issue list --label <clean> --state all` per repo × remote, ja leikkaus paikallisten
run-dirien issue-numeroihin tehdään muistissa. Aiemmin se luki yhden `gh issue view`n **per uniikki
paikallinen issue**, jolloin hinta oli `O(historialliset run-dirit)` eikä `O(työ)` — mitattuna 337
GraphQL-kutsua per tikki (~4000/h pelkästään tästä funktiosta), mikä täytti jaetun GitHub-kiintiön
2026-08-28 ja pysäytti kaikkien 18 repon ajon yli kymmeneksi tunniksi. Invariantti on **kutsumäärä,
ei valinta**: valintaportit voivat pysyä vihreinä samalla kun kustannus palaa lineaariseksi, joten
`tests/test-scan-clean.sh` assertoi kutsumäärän eksplisiittisesti (yksi listaus, nolla per-issue-lukua)
eikä päättele sitä tuloksesta. Kaksi asiaa kantaa korrektiuden: `--state all` (siivottava issue on
usein jo suljettu — mitattuna **jokainen** orgin `auto-clean`-issue oli suljettu) ja katkaisu-fallback
(`RUN_ISSUES_CLEAN_SCAN_LIMIT`), ilman jota katkennut lista lukisi "ei siivottavaa" juuri silloin kun
siivottavaa on. Label ei poistu onnistuneen siivouksen jälkeen, joten se kertyy suljetuille issueille
ja katto on aito eikä teoreettinen.

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

**Hakuyhteys on erikseen estettävissä — siksi listaukset ovat REST:iä (#133).** `gh issue list`
reitittää **`--label`-suodatetun** kyselyn GitHubin GraphQL-`search`-yhteyden kautta; pelkkä
`--state` ei. Tuo yhteys oli estettynä **27 tuntia** 2026-08-28/29 samalla kun REST ja
suodattamaton listaus vastasivat normaalisti, joten poiminta ei voinut ajaa lainkaan. Mittaus
yhdellä repolla, neljän sekunnin välein, **suodattamaton kontrolli lomitettuna**:

| Kutsumuoto | Tulos |
|---|---|
| `gh issue list --limit 1` (kontrolli) | OK ×3 |
| `gh issue list --label X --state all` | torjuttu |
| `gh issue list --search "…"` | torjuttu |
| `gh issue list --state open` | OK |
| `gh pr list --state open` | OK |
| `gh issue view <n>` | OK |
| `gh api repos/…/issues?labels=…` | OK |

**Kontrolli on koko koe.** Ilman sitä molemmat haarat kaatuvat ja johtopäätös olisi "tili on
estetty" — mikä johti aiemmin väärään diagnoosiin (purskeeksi, jota tahdistus muka korjaisi;
18 kutsua sekunnin välein kaatui silti).

Siirretyt kyselyt: `pick_oldest_candidate` (`lib/issue.sh`), `epic_list_open` (`lib/epic.sh`),
`scan_clean`in labelikysely (`poller.sh`) ja `status_github_fetch_epics` (`lib/status-github.sh`)
— moduulin kolme muuta kutsua eivät osu hakuyhteyteen eivätkä siirtyneet. Semantiikka säilyy:
REST **ANDaa** `labels=`-listan kuten erilliset `label:"x"`-termit (mitattu: `labels=auto-run,epic`
→ 0, `labels=auto-run` → 5), ja REST `/issues` palauttaa **myös PR:t**, joten `.pull_request`
suodatetaan aina pois.

Kaksi muutosta, jotka eivät ole käännöksiä:
1. **Negatiiviset labelisuodattimet paranivat.** `-label:x` epäonnistui **auki**: tuntematon
   negatiivinen kvalifikaattori ei virheile vaan täsmää kaikkeen, joten kirjoitusvirhe vuoti
   poissuljettuja issueita poimintaan. jq:n `index()`-jäsenyystesti epäonnistuu umpeen.
2. **`-is:blocked` katosi.** Sillä ei ole REST-vastinetta, ja pelkkä poisto **linkoaisi**: S2b
   torjuu estetyn issuen ennen claimia, joten sama issue poimittaisiin joka tikki ikuisesti.
   Tilalla ehdokkaiden koettaminen `count_open_blockers`illa — sama autoritatiivinen luku jota
   S2b käyttää, REST:n yli, fail-closed — vanhimmasta alkaen ensimmäiseen vapaaseen asti.

**Rate-limit-perääntyminen (#126).** Kumpikin poller tarkistaa tikin **alussa, ennen ensimmäistäkään
gh-kutsua**, jaetun takarajan (`lib/rate-limit.sh`, §6) ja exittaa siististi 0 yhdellä lokirivillä jos se
ei ole ohi. Havainto tehdään **gh:n virhetekstistä**, ei kiintiömittarista, ja tästä on mittaus: 2026-08-29
luettiin `gh api rate_limit`, tehtiin kolme kutsua (`gh issue list --search`, `gh issue view`,
`gh issue list --label`) ja luettiin uudelleen — `search`-, `graphql`- ja `core`-laskurit **eivät liikkuneet
lainkaan**, ja estotilan aikana sama endpoint raportoi `graphql 5000/5000, used 0` samalla kun jokainen
kutsu kaatui. Estävä raja on sekundäärinen eikä ole näkyvissä. **Sitova seuraus: kutsua ei saa koskaan
portittaa kiintiölukemalla.**

Ensimmäisestä havainnosta `poller.sh` keskeyttää koko tikin (`break 2`) sen sijaan että toistaisi saman
kutsun lopuille repoille; `pr-watch.sh` tunnistaa saman `gh_route`ssa — sen ainoassa gh-kuristuskohdassa —
ja pysäyttää skannauksensa. Jo tmuxiin käynnistettyihin ajoihin ei kosketa: ne ovat pitkäkestoisia ja
etenevät ilman listauskutsuja. Vaiennettu stderr saadaan talteen `RUN_ISSUES_GH_ERR`-muuttujalla, jonka
kirjastopolut (`epic_list_open`, siivouslabelin haku, `fetch_issue_json`) kirjoittavat sen sijaan että
heittäisivät virheen `/dev/null`iin; asettamattomana se **on** `/dev/null`, joten muiden kutsujien käytös
ei muutu. Puhtaasti läpi mennyt tikki nollaa portaan. `status.sh --github` keskeyttää sweepin samasta
havainnosta muttei **koskaan kirjoita** takarajaa — se on lukeva näkymä, eikä sivun päivityksen kuulu
voida hidastaa pollereita.

Lokikohina vaimennetaan tarkoituksella: yksi rivi per ohitettu tikki, ei per kutsu. Se on #65:n oppi
sovellettuna — alkuperäinen häiriö kirjoitti 1754 identtistä riviä eikä yksikään niistä ollut signaali.

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
`lib/log-rotate.sh`). **Asennuksen jälkeen ajaa arkistointivaiheen (#128):** iteroi watchlistin
repot ja kutsuu `archive_sweep_repo`n (`lib/archive.sh`) kullekin — terminaalitilaisten,
ikääntyneiden ja PR:ttä vailla olevien run-dirien siirto `run-issues-archive/`iin
(`RUN_ISSUES_ARCHIVE_AFTER_DAYS`). Vaihe on idle-portin **takana** (elävä ajo ⇒ koko tikki
ohitetaan, joten tiedostosiirrot eivät kilpaile ajavan orkestraattorin kanssa) ja best-effort
(repon virhe lokitetaan, ei kaada tikkiä). Poller ei aja tätä — kiintiö- ja aikakriittinen polku
(#128 päätös 5).

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_SELF_UPDATE` | `1` | `0` = ohita tikki (kill-switch). Luetaan `poller.env`istä |
| `RUN_ISSUES_ARCHIVE_AFTER_DAYS` | `30` | Ikäraja (vrk), jonka ylittävä terminaalitilainen + PR:tön run-dir siirretään `.claude/run-issues-archive/`iin arkistointivaiheessa (#128, `lib/archive.sh`). `0` tai alle poistaa arkistoinnin käytöstä (kill-switch samalla perusteella kuin muut portit — uusi vaihe ei saa olla syy siihen, ettei tikki toimi). Luetaan `poller.env`istä |
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
| `RUN_ISSUES_STATUS_CACHE_TTL` | `300` | **Vain `--github`.** Cachen tuoreusikkuna sekunteina. `--cache-ttl <s>` ohittaa, `--no-cache` pakottaa haun. Vertailu on **eksklusiivinen** (`age < ttl`, #147): `0` poistaa owner-cachen käytöstä samalla semantiikalla kuin `DETAIL_TTL=0` poistaa carry-forwardin (kaksi TTL-vertailua ovat samaa mieltä rajatapauksesta). Sivuseuraus: 300 s:n TTL on tuore välillä 0…299 s aiemman 0…300 s sijaan — käytännön merkitys olematon, mutta ilman eksklusiivisuutta `--cache-ttl 0` tarjoili saman sekunnin sisällä kirjoitetun merkinnän cachesta, mikä teki `tests/test-status-github.sh`:sta ei-deterministisen |
| `RUN_ISSUES_STATUS_DETAIL_TTL` | `86400` | **Vain `--github` (#125).** Per-merkintä-TTL suljettujen issueiden detail-luvuille (`status_github_issue_detail`: tila, sulkusyy, otsikko, labelit). Toisin kuin owner-laajuinen `CACHE_TTL`, joka koskee PR/issue/epic-listoja, detail on **terminaalitilan** tieto ⇒ se **kannetaan cache-missin yli** ja luetaan uudelleen vasta kun merkinnän `fetched_epoch` on tätä vanhempi. Vakaassa tilassa poistaa ~318 turhaa `gh issue view` -kutsua per päivitys (mitattu Studiolla). `0` poistaa carry-forwardin (detail luetaan joka missillä). Aikaleimaton legacy-merkintä käsitellään vanhentuneena (kertaluontoinen luku deployn jälkeen). `--no-cache` ohittaa carry-forwardin kokonaan |
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

### Julkaisu asiakasrepoon (`publish-release.sh`, #155)

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_PUBLISH_DENYLIST_FILE` | *(skriptin sisäänrakennettu lista)* | **Testien injektiopiste** vuotoportin kiellettyjen merkkijonojen listalle (yksi termi per rivi, `#` = kommentti). Ei käyttäjäkonfiguraatio: tuotannossa lista on skriptin oma vakio, koska asiakasnimiä sisältävä konfiguraatiotiedosto olisi itsessään vuotopinta. Osoitettu mutta puuttuva tiedosto ⇒ exit 3 (fail-closed), samoin tyhjä lista |

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

