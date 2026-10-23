---
argument-hint: [--dry-run] [--remote <name>]
description: Aja koherenssiauditointi (coherence-audit.sh) nykyiselle repolle; edellisen auditoinnin jälkeen mergetyistä runnerin PR:istä etsitään kaksoistoteutukset, varjostavat abstraktiot ja ristiriitaiset konventiot, ja löydöksistä syntyy coherence-labeloituja refaktorointi-issueita.
---

# /issue-runner:coherence-audit

Ohut operaattoripinta skriptille `coherence-audit.sh`. Runner ajaa issueita rinnakkain, ja
jokainen ajo näkee vain oman muutoksensa. Skripti katselmoi edellisen koherenssiauditoinnin
jälkeen oletushaaraan mergetyt runnerin PR:t (`auto-run/`-haarat) **yhdessä**, epicistä
riippumatta, ja etsii rinnakkaisuuden tuottamat antipatternit: kaksoistoteutukset, varjostavat
abstraktiot ja ristiriitaiset konventiot. Jokaisesta löydöksestä tulee yksi `coherence`-labeloitu
issue, eikä sama löydös tuota toista issueta. **Löydösissuet eivät saa poimintalabeleita:**
refaktorointi on käyttäjän valinta. Auditointi ei muuta koodia.

## 1. Aja

Käytä nykyistä työhakemistoa kohderepona. Välitä käyttäjän argumentit (`--dry-run`,
`--remote <name>`) sellaisinaan. **Jos käyttäjä ei pyytänyt kirjoittamista, ehdota ensin
`--dry-run`ia**: varsinainen ajo luo issueita GitHubiin ja siirtää kursoria.

```bash
set +e
"$HOME/.claude/scripts/run-issues/coherence-audit.sh" "$(pwd)" $ARGS
RC=$?
set -e
echo "COHERENCE_AUDIT_EXIT=$RC"
```

Agenttikutsu kestää pitkään (aikakatto `RUN_ISSUES_COHERENCE_AUDIT_TIMEOUT`, oletus 3600 s).
Jos uusia runnerin PR:iä ei ole, skripti päättyy heti ilman agenttikutsua.

## 2. Tulkitse

Stdoutissa on ensin katselmoitu PR-joukko ja sitten rivi per löydös: toiminto, vakavuus,
sijainti ja kuvaus. Toiminto on `created #N`, `exists #N` (avoin issue on jo olemassa),
`reopened #N` (korjattu löydös toistui), `dismissed #N` (issue on suljettu tilaan *not planned*,
eikä sitä avata uudelleen) tai `duplicate` (sama löydös toistui tässä auditoinnissa).
`--dry-run` näyttää suunnitellun toiminnon ja labelit.

| Exit | Merkitys | Mitä kerrot käyttäjälle |
|---|---|---|
| 0 | Valmis (myös: ei uusia PR:iä), tai `--dry-run` valmis | Katselmoitujen PR:ien määrä sekä luodut ja uudelleenavatut issuet numeroineen |
| 1 | Käyttövirhe | Väärä lippu |
| 2 | Repo, remote tai sen oletushaara ei resolvoidu, tai `git`/`jq`/`gh` puuttuu | Stderrin syy. Puuttuva `<remote>/HEAD` korjataan komennolla `git remote set-head <remote> -a` |
| 3 | Auditointia ei tapahtunut: agentti ei käynnistynyt, tulos oli tyhjä tai jäsentymätön, tai agentti muutti worktreetä | Mitään ei kirjoitettu eikä kursori siirtynyt. Tämä **ei** ole "ei löydöksiä" |
| 4 | GitHub-luku tai -kirjoitus epäonnistui (PR-joukko, muutospinta, issue-indeksi tai issuen kirjoitus) | Kursori ei siirtynyt; aja uudelleen, dedup estää duplikaatit |

Kursori (`$RUN_ISSUES_LOG_DIR/.audit-coherence-cursor-<repo-slug>`) on uusimman katselmoidun
PR:n merge-aika, ja se siirtyy vain onnistuneella ajolla. Ilman kursoria ikkuna on repon
`.coherence.audit_interval_days`, koneen `RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS` tai
7 päivää.

Ajastus: poller ajaa saman auditoinnin itse, kun repolle on asetettu väli
(`.coherence.audit_interval_days` tai koneen `RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS`).
Käsiajo siirtää samaa kursoria, mutta ei pollerin ajastusta.
