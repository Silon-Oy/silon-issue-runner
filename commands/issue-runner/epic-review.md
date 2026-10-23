---
argument-hint: [#N] [--dry-run]
description: Katselmoi epic hyväksyntäkriteereitään vasten — täyttävätkö alaissueiden muutokset yhdessä sen, mitä epic pyysi — ja kirjaa tuloksen epicille kerran.
---

# /issue-runner:epic-review

Katselmoi **epic-issuen**: kokoaa epicin hyväksyntäkriteerit, alaissueet, niiden PR:t ja
yhteisen muutospinnan, ajaa katselmusagentin ja kirjaa tuloksen epicille. `epic-complete`
kertoo vain, että lapset ovat kiinni; tämä kertoo, täyttyivätkö kriteerit. Rakenne:
[`docs/epic-orchestration.md`](../../docs/epic-orchestration.md) §4.4.

## 1. Aja komento

Käytä **nykyistä työhakemistoa kohdereposijaintina** (`pwd`). Poimi käyttäjän antama
epic-numero argumentista `#N`.

```bash
REPO_ROOT=$(pwd)
EPIC="<n>"        # käyttäjän antama epic-issuen numero, esim. 101

set +e
"$HOME/.claude/scripts/run-issues/epic-review.sh" "$EPIC" --repo "$REPO_ROOT"
RC=$?
set -e
echo "EPIC_REVIEW_EXIT=$RC"
```

Liput:

- `--dry-run` — ajaa katselmuksen ja tulostaa saman raportin **kirjoittamatta mitään**
  (ei kommenttia, ei labelia).
- `--remote <nimi>` — monirepotapaus (oletus `origin`).

Katselmus ajaa agentin, joten se kestää minuutteja.

## 2. Toimi exit-koodin mukaan

| RC | Mitä tarkoittaa | Mitä tee |
|---|---|---|
| 0 | Kriteerit täyttyvät (kirjattu kommenttina ilman labelia), tai katselmus oli jo kirjattu | Tulosta raportti. Muistuta, että **sulkupäätös on käyttäjän** — komento ei sulje epiciä. |
| 1 | Käyttövirhe | Tulosta virheviesti. |
| 2 | Epiciä ei löydy, se ei ole avoin tai siltä puuttuu `epic`-label | Kerro käyttäjälle — tarkista numero, tila ja label. |
| 3 | Epic ilman alaissueita | Kerro, ettei katselmoitavaa ole. |
| 4 | Lukuvirhe (fail-closed) | GitHub-lukuvirhe — yritä uudelleen tai tarkista `gh`-yhteys. |
| 5 | Ei tuomiota (agentti ei käynnistynyt, aikakatkesi tai tulos ei jäsentynyt) | Mitään ei kirjoitettu; yritä uudelleen. |
| 6 | Löydöksiä — kommentti ja `epic-attention` kirjattu (tai kirjattaisiin `--dry-run`illa) | Tulosta löydökset **sellaisinaan** kriteereittäin. Ehdota jatkoksi korjaavaa alaissuetta (`/issue-runner:new-issue`); älä korjaa itse. |
| 7 | Tuomio saatiin, mutta GitHub-kirjoitus epäonnistui | Tulosta virheviesti; tarkista epicistä, puuttuuko kommentti vai label. |

## Huomioita

- **Kertaluontoinen:** tulos kirjataan epicille piilomarkerilla, ja uusi ajo vaikenee niin kauan
  kuin kommentti on olemassa. Uusi katselmus vaatii vanhan kommentin poistamisen.
- Ei sulje epiciä, ei koske alaissueihin, ei mergeä eikä muuta koodia.
- Poller ei käynnistä katselmusta — se on aina ihmisen päätös.
