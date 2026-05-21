---
argument-hint: [#PR | scan]
description: Aja /run-issues PR-valvoja yhdelle PR:lle (`#PR`) tai skannaa kaikki tämän koneen valmiit ajot (ei argumenttia / `scan`).
---

# /pr-watch

Phase 2 PR-valvoja. Tarkistaa orkestraattorin avaamat PR:t ja, jos PR on
`auto-merge`-labeloitu, CI-vihreä ja mergettävissä (kaikki kolme vaadittu),
rebase-mergeaa sen, ajaa valinnaisen post-merge-migraation ja siivoaa
ajojäänteet (host-portti: vain saman koneen ajot siivotaan paikallisesti).

Valvoja on **idempotentti pollaus** — ei resume-tilaa. Jokainen ajo johtaa
maailman uudelleen `gh`:sta ja `run.json`:sta.

## 1. Aja valvoja

Käytä **nykyistä työhakemistoa kohdereposijaintina** (`pwd`). Jos käyttäjä antoi
argumentin `#PR`, käytä siitä numero-osa; muuten käytä `scan`.

```bash
REPO_ROOT=$(pwd)
# TARGET: korvaa "<n>" käyttäjän antamalla PR-numerolla, tai pidä "scan".
TARGET="scan"            # tai esim. "21" jos käyttäjä antoi #21

set +e
"$HOME/.claude/scripts/run-issues/pr-watch.sh" "$REPO_ROOT" "$TARGET"
RC=$?
set -e
echo "PR_WATCH_EXIT=$RC"
```

## 2. Toimi exit-koodin mukaan

| RC | Mitä tarkoittaa | Mitä tee |
|---|---|---|
| 0 | Merge + siivous OK, tai ei tehtävää | Tulosta lopputulos. |
| 2 | Scan ei löytänyt kandidaatti-PR:ää | Tulosta "Ei valmiita PR:iä tällä koneella" ja lopeta. |
| 3 | Lock race hävitty | Joku toinen ajo omistaa issuen. Lopeta hiljaa. |
| 4 | Ei vielä mergettävissä (label puuttuu, CI kesken/punainen, dirty res OFF) | Raportoiva — kerro miksi (lue `state.jsonl` viimeinen `pr_classified`/`pr_watch_skipped`). |
| 5 | Merge epäonnistui | Tulosta `gh pr merge`-virhe. |
| 6 | Konflikti — ihminen tarvitaan | PR:ään on jätetty kommentti; rebase on abortattu. Ohjaa maintainer ratkaisemaan. |
| 7 | Post-merge-migraatio epäonnistui | PR on jo mergetty mainiin; migraatio kaatui. Tutki `.claude/post-merge-migrate.sh`-loki. |
| 1 | Käyttövirhe | Tulosta usage. |

## Huomioita

- **Conflict-resolution on OFF oletuksena** (`PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0`).
  Päällä (`=1`) valvoja yrittää konfliktittoman rebasen feature-worktreessä +
  pakollisen CI-revalidoinnin. Mikä tahansa konflikti → abort + PR-kommentti + RC 6.
- **Merge-label** on `auto-merge` oletuksena (`PR_WATCH_MERGE_LABEL`).
- **Cross-machine:** valvoja siivoaa vain sen koneen ajot, jolla ajo alkoi
  (`run.json.host`). Toisen koneen PR mergetään, mutta siivous jätetään tekemättä
  ja tulostetaan `ssh`-ohje.
- **Auto-tila (Studion poller)** ajaa `pr-watch.sh ... scan` 5 min välein
  `com.maintainer.pr-watch-poller` -LaunchAgentista. Slash-komentoa ei silloin tarvita.
