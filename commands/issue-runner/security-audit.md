---
argument-hint: [--dry-run] [--remote <name>]
description: Aja koko repon tietoturva-auditointi (security-audit.sh) nykyiselle repolle; löydöksistä syntyy security-labeloituja issueita, vakavimmista poimittavia.
---

# /issue-runner:security-audit

Ohut operaattoripinta skriptille `security-audit.sh`. Skripti auditoi repon oletushaaran
kokonaisuutena: valinnaiset skannerit (gitleaks, osv-scanner) ja yksi agentin
uhkamallikierros. Jokaisesta löydöksestä tulee yksi `security`-labeloitu issue, eikä sama
löydös tuota toista issueta. Löydökset, jotka ylittävät auto-run-rajan (oletus `high`),
saavat tämän koneen poimintalabelit, joten runner korjaa ne tavallisina ajoina. Auditointi ei
muuta koodia.

## 1. Aja

Käytä nykyistä työhakemistoa kohderepona. Välitä käyttäjän argumentit (`--dry-run`,
`--remote <name>`) sellaisinaan. **Jos käyttäjä ei pyytänyt kirjoittamista, ehdota ensin
`--dry-run`ia**: varsinainen ajo luo issueita GitHubiin.

```bash
set +e
"$HOME/.claude/scripts/run-issues/security-audit.sh" "$(pwd)" $ARGS
RC=$?
set -e
echo "SECURITY_AUDIT_EXIT=$RC"
```

Agenttikutsu kestää pitkään (aikakatto `RUN_ISSUES_SECURITY_AUDIT_TIMEOUT`, oletus 3600 s).

## 2. Tulkitse

Stdoutissa on rivi per löydös: toiminto, vakavuus, sijainti ja kuvaus. Toiminto on
`created #N`, `exists #N` (avoin issue on jo olemassa), `reopened #N` (korjattu löydös toistui),
`dismissed #N` (ihminen sulki issuen tilaan *not planned*, eikä sitä avata uudelleen) tai
`duplicate` (sama löydös toistui tässä auditoinnissa). `--dry-run` näyttää suunnitellun
toiminnon ja labelit.

| Exit | Merkitys | Mitä kerrot käyttäjälle |
|---|---|---|
| 0 | Valmis, tai `--dry-run` valmis | Luodut ja uudelleenavatut issuet numeroineen |
| 1 | Käyttövirhe | Väärä lippu |
| 2 | Repo, remote tai sen oletushaara ei resolvoidu, tai `git`/`jq`/`gh` puuttuu | Stderrin syy. Puuttuva `<remote>/HEAD` korjataan komennolla `git remote set-head <remote> -a` |
| 3 | Auditointia ei tapahtunut: agentti ei käynnistynyt, tulos oli tyhjä tai jäsentymätön, tai agentti muutti worktreetä | Mitään ei kirjoitettu. Tämä **ei** ole "ei löydöksiä" |
| 4 | GitHub-luku tai -kirjoitus epäonnistui | Issueita voi olla luotu osittain; aja uudelleen, dedup estää duplikaatit |
| 5 | Valmis, mutta vähintään yksi skanneri epäonnistui | Skannerin luokka jäi tarkistamatta deterministisesti |

Auto-run-raja: kohderepon `.claude/run-issues.json` `.security.audit_auto_run_min_severity`
(oletushaarasta) voittaa koneen `RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY`:n. Arvo
`none` estää poimintalabelit kokonaan.

Ajastus: poller ajaa saman auditoinnin itse, kun repolle on asetettu väli
(`.security.audit_interval_days` tai koneen `RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS`).
Tämä komento on käsiajo, eikä se siirrä ajastettua auditointia.
