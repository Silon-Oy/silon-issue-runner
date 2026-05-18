---
argument-hint: [#N]
description: Aja /run-issues-orkestraattori joko nimetylle issuelle (`#N`) tai vanhimmalle omistamattomalle (ei argumenttia).
---

# /run-issues

Geneerinen issue-pohjainen kehitysworkflow. Käynnistää orkestraattorin, joka:

1. Poimii issuen (`$1` = `#N` tai poll-tila jos tyhjä).
2. Lukitsee + clamamerkitsee issuen GitHubissa.
3. Luo per-issue worktreen kohderepoon.
4. Tekee opt-in DB-kloonin jos `.claude/db-clone.json` löytyy.
5. Ajaa Strategist (cycle-review) → Implementer → Evolution -ketjun.
6. Avaa PR:n samalle haaralle (post-commit-hookien automaattisuomennokset menevät samaan PR:ään).

## Ajo

Aja orkestraattori Bash-työkalulla. Käytä **nykyistä työhakemistoa kohdereposijaintina**
(`pwd`), jotta tämä komento toimii sieltä mistä maintainer sen käynnistää.

```bash
REPO_ROOT=$(pwd)
ISSUE_ARG="${1:-poll}"
# Strip leading '#' from the user input (e.g. "#42" → "42") for the orchestrator.
ISSUE_ARG="${ISSUE_ARG#\#}"

RUN_ISSUES_AUTO=0 \
RUN_ISSUES_REVIEW_GATE=interactive \
  "$HOME/.claude/scripts/run-issues/orchestrate.sh" "$REPO_ROOT" "$ISSUE_ARG"
```

- **Interaktiivinen oletus.** Cycle-reviewn jälkeen pysähdytään ja kysytään lupa
  jatkaa. Studion poller asettaa `RUN_ISSUES_AUTO=1` ja `RUN_ISSUES_REVIEW_GATE=auto`,
  joten siellä ei pysähdytä.
- **Poll-tila** (`/run-issues` ilman argumenttia) etsii vanhimman omistamattoman
  issuen, jossa ei ole labelia `blocked`/`waiting`/`wip`.
- **`#N`-tila** kohdistaa nimetylle issuelle.

## Lopputulos

Orkestraattori tulostaa lokia stderriin ja palauttaa exit-koodilla 0–6.
PR-URL kirjataan `<repo>/.claude/run-issues/<run-id>/run.json` -tiedostoon ja
state.jsonl-tapahtumaan `pr_opened`.

Jos jokin pysähtyy (cycle review BLOCKER, implementer BLOCKED), issuelle lisätään
kommentti johon viittaa run-kansioon — maintainer näkee mistä jatkaa.
