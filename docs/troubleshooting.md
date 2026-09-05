# Vianetsintä — skriptikohtainen hakuteos

Tämä tiedosto on **hakuteos**: sitä ei lueta alusta loppuun vaan hakusanalla — skriptin
nimellä tai exit-koodilla. Ensimmäisen tunnin lukijalle kuuluva aineisto — oirekartta, ajon
tilat (`run.json`), lokien sijainnit, siivous ja hätävarat — on [`README.md`](../README.md)
osiossa 9.

**Lähde on koodi, tämä on peilaus.** Jokaisen exit-koodin autoritatiivinen määritelmä asuu
kyseisen skriptin omassa `# Exit codes:` -otsikkokommentissa. `tests/test-readme.sh` johtaa
odotuksensa suoraan niistä ja vaatii jokaiselle koodille rivin tästä tiedostosta: uusi
exit-koodi ilman dokumentaatioriviä on punainen testi.

---

## Exit-koodit

Useita skriptejä, **kukin oma erillinen exit-koodiavaruutensa**. Sama numero ei tarkoita samaa
asiaa eri skripteissä — tarkista aina, kumpi prosessi exittasi.

### Orkestraattori (`orchestrate.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui — PR avattu, tai resume peruttiin siististi |
| 1 | Fataali — virheellinen käyttö tai puuttuva `run.json` resumessa. **Myös `poll`-argumentti** (issue #99): automaattinen poiminta on pollerin tehtävä, ei orkestraattorin. Koodi 2 (ei ehdokasta) poistui käytöstä |
| 3 | Lukko-/claim-kilpajuoksu hävitty |
| 4 | Katselmointi esti ajon (vain auto-tila) |
| 5 | Estynyt ennen implementeriä tai implementerissä — worktreen luonti (S4), db-clone, riippuvuusasennus (S7b), testiympäristön provisiointi (S7c) tai implementer palautti BLOCKED. Tarkan syyn ja sen korjauksen kertoo `run.json`-statuksen syykenttä, ks. [`usage-reference.md`](usage-reference.md#käyttötapaukset) käyttötapaus (e) |
| 6 | PR:n avaus epäonnistui |
| 7 | Implementer (S8) aikakatkaistiin — ajo on `--restart`-kelpoinen |
| 8 | **Puuttuva pakollinen riippuvuus** — S0-portti kieltäytyi käynnistämästä ajoa; mitään ei lukittu, claimattu eikä luotu. Virheilmoitus nimeää työkalun ja korjauskomennon |
| 9 | **Issue on estetty avoimella `blocked_by`-riippuvuudella** — S2b-portti kieltäytyi lukon ja claimin välissä ennen assignaatiota; ajo viimeisteltiin `blocked`-tilaan ja lukko vapautettiin. Portti lukee riippuvuusgraafin suoraan (hakuindeksin sijaan) ja on fail-closed. Issue **ei** saa `needs-human`-labelia: se on odotustila, joka jatkuu itsestään kun estäjä sulkeutuu. Nimetyn ajon voi pakottaa `--force`-lipulla |
| 10 | Odottaa ihmisen katselmointia — jatka komennolla `--resume` |
| 11 | Odottaa tarkennusta — vastaa issuelle, poller jatkaa `--continue`-ajolla |
| 12 | **Issue kantaa `epic`-labelia** — S2c-portti kieltäytyi lukon ja claimin välissä ennen assignaatiota (issue #81). Epic kokoaa ajettavat alaissueet mutta ei ole itse ajettava; ajo viimeisteltiin `blocked`-tilaan (`is_epic_not_runnable`, tai `epic_check_failed` jos labelit lukukelvottomat) ja lukko vapautettiin. Portti lukee labelin suoraan (hakuindeksin sijaan) ja on fail-closed. Issue **ei** saa `needs-human`-labelia (claimia edeltävä portti kuten S2b). Nimetyn ajon voi pakottaa `--force`-lipulla |

### Asennin (`install.sh`)

Oma avaruus. **Älä sekoita** orkestraattorin tai PR-vahdin koodeihin.

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui (tai `--dry-run` valmis) |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | **Kieltäydytty — mitään ei muutettu.** Kohdepolku on jonkun muun omistama, tai `ln -s` ei tuota tällä koneella aitoa symlinkkiä |
| 3 | Apply epäonnistui kesken (odottamaton tiedostojärjestelmävirhe); uusi ajo konvergoi |
| 4 | Valmis, mutta vieras tiedosto varjostaa paketin toimittamaa nimeä — mitään ei ylikirjoitettu |

Miksi exit 2 on haluttu turvakäyttäytyminen, mitä `~/.claude/commands`-hakemistosymlinkki
tarkoittaa ja miten symlink-koetus toimii Windowsissa: [`README.md`](../README.md) osio 3.

### PR-vahti (`pr-watch.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Merge + siivous OK, tai ei tekemistä |
| 1 | Käyttövirhe |
| 2 | Skannaus ei löytänyt ehdokasta |
| 3 | Lukkokilpailu hävitty (toinen vahti tai orkestraattori pitää issueta) |
| 4 | Ei vielä mergettävissä (turvallista yrittää seuraavalla kierroksella) |
| 5 | Merge epäonnistui |
| 6 | Konflikti vaatii ihmisen — AI ei ratkaissut tai CI punainen |
| 7 | Merge-jälkeinen migraatio epäonnistui |
| 8 | Punainen CI vaatii ihmisen — AI ei korjannut, CI jäi punaiseksi tai yrityskatto täyttyi (`needs-human`-label + kommentti) |

### Kokonaistila (`status.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Luenta onnistui |
| 1 | Käyttövirhe (tuntematon lippu tai kelvoton arvo) |
| 2 | Ei watchlistiä, ei yhtään levyllä olevaa repoa, tai `jq` puuttuu |
| 3 | Vajaa luenta — yksi tai useampi `run.json` oli lukukelvoton/virheellinen; dokumentti on silti validi ja täydellinen muun osan osalta (`degraded: true`), ja rikkinäiset polut on listattu `read_errors`-kentässä |

### Statussivun renderöinti (`status-render.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Renderöity — `index.html` ja `status.json` kirjoitettu atomisesti |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva arvo) |
| 2 | Syöte kelvoton — `status.sh` ei tuottanut validia JSONia tai `schema_version` on tuntematon; vanha sivu jää paikoilleen |
| 3 | Kirjoitus epäonnistui (levy täynnä / oikeudet); temp-tiedostot siivotaan, vanha sivu jää ehjäksi |

### Label-vetoinen siivous (`auto-clean.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Siivottu, issue suljettu, `auto-clean`-label poistettu |
| 1 | Käyttövirhe tai remotea ei voitu selvittää |
| 3 | Issuen lukko on toisella ajolla — turvallista yrittää seuraavalla tikillä |
| 4 | Issuen `completed`-ajolla on **avoin** (tai selvittämätön) PR — ei siivottu, `auto-clean-skipped` lisätty. Mergetyn/suljetun PR:n ajo siivotaan normaalisti |
| 5 | Tältä koneelta ei löydy ajoja tälle issuelle — `auto-clean-skipped` lisätty ja kommenttiin kirjattu konekohtainen ohje |
| 6 | Purku (`cleanup-run.sh`) epäonnistui |

Koodit 4 ja 5 eivät ole virheitä vaan **kieltäytymisiä**: siivous ei koske avoimen PR:n ajoon
eikä arvaile toisen koneen tilaa. `completed`-ajon PR-tila luetaan run.jsonin `pr_url`ista
(`gh pr view --json state`): vain aidosti `OPEN` — tai selvittämätön tila (fail-closed) —
kieltäytyy, `MERGED`/`CLOSED` siivotaan ja issue suljetaan. `auto-clean-skipped` on
silmukkasuoja — poista se käsin, kun olet hoitanut asian, jos haluat siivouksen yrittävän
uudelleen.

### Label-vetoinen nollaus (`auto-reset.sh`)

Oma avaruutensa, ei siivouksen jatke — numerot sattuvat osumaan yhteen, mutta niitä ei ole
yhtenäistetty eikä pidä yhtenäistää.

| Koodi | Merkitys |
|---|---|
| 0 | Purettu, **issue jätetty auki**, `auto-reset`-label poistettu — issue palaa poimintaan |
| 1 | Käyttövirhe tai remotea ei voitu selvittää |
| 3 | Issuen lukko on toisella ajolla — turvallista yrittää seuraavalla tikillä |
| 4 | Issuen `completed`-ajolla on **avoin** (tai selvittämätön) PR — ei purettu, `auto-reset-skipped` lisätty. Nollaus tuottaisi samalle issuelle toisen PR:n, joten sulje PR ensin |
| 5 | Tältä koneelta ei löydy ajoja tälle issuelle — `auto-reset-skipped` lisätty ja kommenttiin kirjattu konekohtainen ohje |
| 6 | Purku (`cleanup-run.sh`) epäonnistui |

Portit ovat kirjaimellisesti samat rivit kuin siivouksessa (`lib/teardown.sh`), joten myös
kieltäytymiset osuvat samoihin kohtiin. Ero on lopputuloksessa: **issueta ei suljeta eikä avata
uudelleen**, ja onnistuneen purun jälkeen issue täyttää poimintaehdot heti.

### Yksittäisen ajon pysäytys (`stop-run.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Pysäytetty (tai `--dry-run` tulosti suunnitelman) |
| 1 | Käyttövirhe (tuntematon lippu, puuttuva tai ristiriitainen kohde) |
| 2 | Kohdetta ei löytynyt (myös arkistoon osoittava `--run-dir`) |
| 3 | `--issue` osui useampaan ajoon — tarkenna `--run-dir`illä |
| 4 | Vieras host — ajo kuuluu toiselle koneelle; mihinkään ei koskettu |
| 5 | Terminaalitilassa oleva ajo — käytä `--force`ia; mihinkään ei koskettu |

`stop-run.sh` pysäyttää **yhden** elävän ajon hallitusti: tappaa tmux-session, viimeistelee ajon
`blocked/stopped_by_operator`-tilaan, lisää `needs-human`-labelin ja tilannekommentin. Se **ei
ole siivous** — worktree, haara ja run-dir jäävät koskematta (purku jää `cleanup-run.sh`ille tai
`auto-clean`-labelille). Ei `--all`-lippua eikä oletuskohdetta: massapysäytys on koko
orkestraattorin pysäyttäminen (`launchctl`), ei tämän skriptin asia.

### Epicin käynnistys ja keskeytys (`run-epic.sh`)

Koodit 1/2/3/5 ovat yhteisiä molemmille moodeille; 4 on vain käynnistys, 6 vain `--stop`.

| Koodi | Merkitys |
|---|---|
| 0 | Käynnistys: validoitu + propagoitu. `--stop`: epic kokonaan pysäytetty (kaikki elävät lapsiajot pysäytetty, ajolabelit poistettu). Tai `--dry-run` tulosti suunnitelman |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva tai epäkelpo epic-numero / `--stop` yhdessä `--start-now`n kanssa) |
| 2 | Epic-issueta ei löytynyt tai se ei ole avoin |
| 3 | Epic ilman alaissueita — ei propagoitavaa/pysäytettävää |
| 4 | Käynnistys: syklinen `blocked_by`-graafi alaissueiden välillä — sykli nimetään, mitään ei kirjoiteta |
| 5 | Lukuvirhe — lapsijoukkoa tai `blocked_by`-graafia ei saatu luettua (fail-closed) |
| 6 | `--stop`: osittainen — epic vapautettiin poiminnasta mutta ≥1 elävää lapsiajoa ei voitu pysäyttää (vieras kone / terminaalitila ilman `--force`ia / moniselitteinen / delegoitu `stop-run.sh` epäonnistui). Muu käsiteltiin; täysi pysäytys on 0 |

`run-epic.sh` validoi epicin rakenteen **ennen mitään kirjoitusta** (suunnittele–sovella kuten
`install.sh`) ja propagoi sitten ajolabelit alaissueille **samalla jaetulla funktiolla** kuin
pollerin epic-skannaus. `--dry-run` tulostaa raportin kirjoittamatta; `--start-now` käynnistää
ensimmäisen ajokelpoisen alaissueen heti. `--stop` **keskeyttää** epicin: se pysäyttää elävät
lapsiajot delegoimalla `stop-run.sh`:lle ja vapauttaa jonossa olevat poistamalla ajolabelit
**ensin epiciltä, sitten avoimilta lapsilta** (järjestys estää pollerin re-propagoinnin).

### Julkaisu julkiseen peiliin (`publish-release.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Julkaistu tai ajan tasalla, tai `--dry-run` tulosti suunnitelman, tai vahvistus peruttiin |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva `--target`) |
| 2 | Lähdepuu ei ole julkaistavissa: ei git-repo, likainen työpuu, puuttuva `origin/main`, `HEAD != origin/main` tai `LICENSE` puuttuu. Mitään ei kirjoitettu |
| 3 | Vuotoportti kieltäytyi: kielletty termi löytyi työpuusta (osumat `tiedosto:rivi`-muodossa), denylist oli tyhjä/lukukelvoton tai korvaus sisältää kielletyn termin. Mitään ei kirjoitettu |
| 4 | Historiaportti kieltäytyi: uudelleenkirjoitettu historia sisältää yhä kielletyn termin viestissä, polussa tai blobissa. Mitään ei kirjoitettu |
| 5 | Julkaisu epäonnistui: kohteeseen ei saatu yhteyttä, tai push ei ollut fast-forward eikä `--force` annettu. Paikallinen repo on silti muuttumaton |
| 6 | `git filter-repo` puuttuu tai uudelleenkirjoitus kaatui — työkaluvirhe, ei sisällön kieltäytyminen |

`publish-release.sh` julkaisee paketin julkiseen peiliin **historia uudelleenkirjoitettuna**
([`usage-reference.md`](usage-reference.md#julkaisu-julkiseen-peiliin-publish-releasesh)). Viisi fail-closed-porttia ajetaan ennen mitään
kirjoitusta; kaksi niistä on vuotoportteja, joista toinen tarkistaa työpuun ja toinen
uudelleenkirjoitetun historian jokaisen viestin, polun ja blobin.

### Self-update (`self-update.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Tikki valmis, tai siististi ohitettu (idle-portti / kill-switch / pull-vartio). Pull on aina fail-soft: verkkovirhe tai jäljessä oleva `main` on NOTE, ei virhe — seuraava tikki yrittää uudelleen |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | Asennusvaihe epäonnistui odottamatta (asentajan exit ei ∈ {0,2,4}); lokitettu, seuraava tikki yrittää uudelleen. Asentajan oma refuse (2) / conflict (4) on NOTE eikä yllä tänne |

`self-update.sh` pitää asennetun paketin ajan tasalla ([`README.md`](../README.md) §7.10): kehittäjäkoneella vartioitu
`git pull --ff-only` + `install.sh`, ylläpitäjän submodule-koneella vain `install.sh` (pull
ohitetaan aina). Idle-portti ohittaa koko tikin, jos koneella on elävä ajo. Kill-switch:
`RUN_ISSUES_SELF_UPDATE=0`.

### Ohjaamon toimintopalvelu (`action-server.sh`)

Kääre omistaa elinkaaren ja delegoi socketin `lib/action-service.py`:lle `exec`illä, joten
**Pythonin exit-koodi on prosessin exit-koodi** — siksi koodit jakautuvat siihen, mitä kääre
päättää ennen `exec`iä (1/2) ja mitä palvelu päättää (0/3/4).

| Koodi | Merkitys |
|---|---|
| 0 | Puhdas exit — host-portti no-op, `--check` OK, tai palvelu pysähtyi SIGTERMiin |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | Puuttuva pakollinen riippuvuus (`python3` / `jq` / Tailscale-CLI) — ennen `exec`iä |
| 3 | Bind epäonnistui — ei Tailscale-osoitetta johon sitoa (ei koskaan wildcard), tai portti varattu. launchd `KeepAlive` yrittää uudelleen — tämä on boot-ennen-tailnetiä-toipuminen |
| 4 | Konfiguraatio kieltäytyy — ei sallittua identiteettiä, tokenia eikä originia (fail-closed) |

### Ohjaamon toiminnon delegointi (`action-dispatch.sh`)

Ohut kuori: jokainen neljästä toiminnosta delegoi olemassa olevalle skriptille tai labelille
eikä toteuta purku-, merge- tai restart-logiikkaa itse.

| Koodi | Merkitys |
|---|---|
| 0 | Delegoitu komento onnistui |
| 1 | Käyttövirhe (tuntematon toiminto / puuttuva tai virheellinen selektori) |
| 2 | Delegoitu komento **epäonnistui** — sen tuloste on stdout/stderrissä sellaisenaan (turvamalli [`README.md`](../README.md) §7.9: näytä virhe, älä yritä itse) |
| 3 | Delegoitava puuttuu (skripti ei suoritettavissa, tmux puuttuu restartista) |

### Kooste (`status-digest.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Lähetetty, tai ei lähetystarvetta (muuttumaton tilanne ilman `--force`) |
| 1 | Käyttö- tai syötevirhe |
| 2 | Tuntematon `schema_version` — ei lähetystä |
| 3 | Lähetys epäonnistui; runko on silti stdoutissa |
