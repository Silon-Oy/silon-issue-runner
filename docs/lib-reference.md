# `lib/`-moduulit — täysi referenssi

Tämä on paketin **täysi** `lib/`-moduuliluettelo, yksi rivi per moduuli. Se irrotettiin
`CLAUDE.md`:stä, koska se on hakuteos eikä joka session kontekstia: taulukkoa luetaan
tiedostonimellä silloin kun sellainen vastaan tulee, ei alusta loppuun.

**Lähde on koodi, tämä on peilaus.** Jos tarvitset funktiotason yksityiskohtia, lue itse
tiedosto. `CLAUDE.md` §7 pitää sen osan, joka ei ole hakuteosta: **jaetut primitiivit, joita
ei saa monistaa**. Alla olevat `§`-viittaukset osoittavat [`CLAUDE.md`](../CLAUDE.md):n
lukuihin.

| Tiedosto | Vastuu |
|---|---|
| `action-service.py` | **Ainoa Python-tiedosto.** Ohjaamon HTTP + auth -ydin: fail-closed `tailscale whois`, kolmikerroksinen CSRF, audit-loki, `execve` dispatcheriin — ei koskaan koske gh:hun itse |
| `action-token.sh` | Ohjaamon jaettu CSRF-token. Bearer-salaisuus: ei koskaan `status.json`iin, lokiin eikä kommenttiin |
| `archive.sh` | Terminaalitilaisten run-dirien siirto `run-issues-archive/`iin. PR-suoja on paikallinen, ei gh-kutsu |
| `claude-call.sh` | Yksittäisen orkestroidun askeleen claude-CLI-kutsu (timeout, lokitus, finalisointi) ja aina päällä olevan järjestelmäkehotteen toimitus: toimintasopimus + koodausstandardi yhdistettynä — myös PR-vahti kutsuu tästä `load_repo_principles_file`ia |
| `env-bootstrap.sh` | Pakettimanagerin tunnistus S7b:n fail-fast-asennusporttiin |
| `epic.sh` | Epic-tason automaatio: ajolabelien propagointi, `needs-human`-eskalaatio, valmiuskommentti. Best-effort (aina rc 0) |
| `git-remote.sh` | Multi-remote-apurit: yksi klooni voi pollata useaa GitHub-orgia |
| `github-app-auth.sh` | Opt-in GitHub App -identiteetti. Kattaa kirjoitukset **ja** raskaimmat luvut |
| `gitignore.sh` | Pitää **kohderepon** `.gitignore`n ignoroimassa ajoaikaiset artefaktit |
| `host.sh` | `runner_host`: koneen lyhyt konenimi yhdestä paikasta, nelivaiheisella varapolulla (`hostname -s` → `hostname` ensimmäiseen pisteeseen → `$COMPUTERNAME` → `unknown`). **Ei koskaan palauta tyhjää** — §5.6:n fail-closed-portit lukisivat tyhjän hostin vieraaksi koneeksi |
| `host-gate-notice.sh` | Host-portin "muuttuja puuttuu" -rivin toimitus: stderr **ja** skriptin oma loki, kerran. Erillään `poller-config.sh`:sta, jotta sen puhtausväite säilyy — tämä kirjoittaa levylle |
| `hook-runner.sh` | Synkroninen commit, joka ajaa post-commit-hookit loppuun ennen paluuta |
| `issue-images.sh` | Issuen kuvien poiminta ja lataus, jotta agentit näkevät ne |
| `issue.sh` | GitHub-issue-operaatiot. Sisältää paketin **ainoan** poimintakyselyn (`pick_oldest_candidate`) ja lapsijoukon **ainoan** resolvoinnin (`list_epic_children`) |
| `jq-binary.sh` | `jq --binary` Windowsissa (§5.8). Paketin ainoa exportattava funktio; entry pointit sourcettavat sen |
| `labels.sh` | Label-hallinta REST-API:n kautta (ei `gh issue edit --add-label`) |
| `locking.sh` | Issue-kohtainen lukkohakemisto, atominen `mkdir(2)`:lla |
| `log-rotate.sh` | Kokoon perustuva lokirotaatio. Erillään `poller-config.sh`:sta, jotta sen puhtausväite säilyy — tämä kirjoittaa levylle |
| `machine-env.sh` | Koneen env-tiedoston sourceaus **kutsujan etuoikeudella** (§5.5). Jaettu `orchestrate.sh`:n ja `pr-watch.sh`:n kesken, jotta sääntö on yhdessä paikassa |
| `paths.sh` | Lukkojuuren ja lokihakemiston **alustakohtaiset oletukset** (`uname -s`: Darwin ⇒ macOS-polut, kaikki muu ⇒ XDG state). Haara on tarkoituksella ei-valkolista, jotta `MINGW64_NT-*` osuu XDG-haaraan |
| `poller-config.sh` | Host-portti, watchlistin resolvointi ja repon poimintalabelit. Erillinen, koska poller itse exittaa source-hetkellä vieraalla koneella eikä olisi testattavissa. Kirjoittaa levylle ei koskaan; ainoa ulkoinen komento on watchlistin `jq`-luku |
| `pr-watch-lib.sh` | PR:n luokittelu ja merge-päätös irrotettuna testattavaksi |
| `preflight.sh` | Jaettu riippuvuustarkistus. Korjauskomennot yhdestä lähteestä (`preflight_install_hint`) |
| `rate-limit.sh` | Rate-limitin **tekstuaalinen** tunnistus ja jaettu perääntyminen (§5.1) |
| `run-terminate.sh` | Elävän ajon turvallinen lopetus **kutsuttavana funktiona**. Irrotettu pollerista, joka `exit 0`si source-hetkellä; `stop-run.sh` ja `run-epic.sh --stop` käyttävät samaa polkua monistamatta turvalogiikkaa |
| `state.sh` | Ajon durable-tila `<run-dir>`-hakemistossa |
| `status-github.sh` | `status.sh --github`-rikastus. Ei omaa CI-rollupia eikä merge-päätöstä — kutsuu `pr-watch-lib.sh`:n omia |
| `status-read.sh` | `status.sh`:n puhtaat luku- ja luokittelufunktiot. `_iso_to_epoch` asuu täällä, jotta poller ja näkymä laskevat iän identtisesti |
| `teardown.sh` | Label-vetoisen purun turvaportit **kutsuttavana funktiona**: lukko, run-dir-inventaario, `completed`-ajon PR-portti, `cleanup-run.sh`-delegaatti. `auto-clean.sh` ja `auto-reset.sh` ovat sen ohuita lopputuloskerroksia |
| `version.sh` | Ajossa olevan version ja submodule-pinnin näkyväksi teko. Fail-soft: puuttuva `.git` ⇒ `?` |
| `worktree.sh` | Ajokohtaiset git-worktreet kohderepossa |
| `issue.test.sh`, `render-prompt.test.sh` | Yksikkötestit (`verify_claim`, `render_prompt`) |
