---
argument-hint: [--dry-run] [--remote <name>]
description: Aja koko repon laatuauditointi (quality-audit.sh) nykyiselle repolle; seitsemästä laatuluokasta (datan eheys, sääntöjen johdonmukaisuus, oletuksena salliva rajaus, sietokyky, testien luotettavuus, ylläpidettävyys, saavutettavuus) syntyy quality-labeloituja issueita, oletuksena ilman poimintalabeleita.
---

# /issue-runner:quality-audit

Ohut operaattoripinta skriptille `quality-audit.sh`. Skripti auditoi repon oletushaaran
kokonaisuutena yhdellä agenttikierroksella seitsemässä laatuluokassa: `[data-integrity]`,
`[rule-consistency]`, `[default-allow]`, `[resilience]`, `[test-reliability]`,
`[maintainability]` ja `[accessibility]`. Jokaisesta löydöksestä tulee yksi `quality`-labeloitu
issue, eikä sama löydös tuota toista issueta. **Oletuksena löydösissuet eivät saa
poimintalabeleita:** laatukorjaus on käyttäjän valinta, ellei kone tai repo nosta auto-run-rajaa.
Auditointi ei muuta koodia.

## 1. Aja

Käytä nykyistä työhakemistoa kohderepona. Välitä käyttäjän argumentit (`--dry-run`,
`--remote <name>`) sellaisinaan. **Jos käyttäjä ei pyytänyt kirjoittamista, ehdota ensin
`--dry-run`ia**: varsinainen ajo luo issueita GitHubiin.

```bash
set +e
"$HOME/.claude/scripts/run-issues/quality-audit.sh" "$(pwd)" $ARGS
RC=$?
set -e
echo "QUALITY_AUDIT_EXIT=$RC"
```

Agenttikutsu kestää pitkään (aikakatto `RUN_ISSUES_QUALITY_AUDIT_TIMEOUT`, oletus 3600 s).

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

Auto-run-raja: kohderepon `.claude/run-issues.json` `.quality.audit_auto_run_min_severity`
(oletushaarasta) voittaa koneen `RUN_ISSUES_QUALITY_AUDIT_AUTO_RUN_MIN_SEVERITY`:n. Oletus on
`none`, eli yksikään löydös ei lähde ajoon itsestään.

Ajastus: poller ajaa saman auditoinnin itse, kun repolle on asetettu väli
(`.quality.audit_interval_days`, watchlistin `quality_audit_interval_days` tai koneen
`RUN_ISSUES_QUALITY_AUDIT_INTERVAL_DAYS`). Ilman väliä repoa ei auditoida. Tämä komento on
käsiajo, eikä se siirrä ajastettua auditointia.
