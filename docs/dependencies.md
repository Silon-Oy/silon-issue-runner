# Riippuvuudet — yhteinen taulukko kaikille ajokonemalleille

Tämä on paketin **ainoa** riippuvuustaulukko. Jokainen ajokoneohje viittaa tähän:
[README §2](../README.md#2-riippuvuudet) (macOS-kone pollereilla),
[`sprite-runner.md`](sprite-runner.md) (Fly.io Sprite, Ubuntu) ja
[`local-llm-runner.md`](local-llm-runner.md) (paikallisen mallin kone).

Taulukko **generoidaan** luettelosta [`lib/deps.tsv`](../lib/deps.tsv), josta myös
orkestraattorin S0-portti (`lib/preflight.sh`) ja asentajan raportti (`install.sh`) lukevat
listansa. Uusi riippuvuus on siis yksi rivi luetteloon — ei muokkausta porttiin, asentajaan
eikä yksittäisiin ohjeisiin. `tests/test-dependencies.sh` on punainen, jos alla oleva taulukko
ei vastaa luetteloa tai jos jokin ajokoneohje ei viittaa tähän sivuun.

Generoi taulukko uudelleen luettelon muutoksen jälkeen paketin juuresta:

```bash
bash -c '. lib/deps.sh; deps_markdown_table'
```

ja korvaa sillä merkkien `deps-table:begin` ja `deps-table:end` välinen osa.

## Tasot ja näkyvyys

- **required** — S0-portti on fataali (exit 8) ennen kuin mitään lukitaan tai claimataan.
- **optional** — puuttuminen ei estä ajoa. Asentaja (`install.sh`) raportoi jokaisen rivin.
  S0-portti varoittaa ajon lokissa puuttuvasta `timeout`ista ja jokaisesta
  `security`-laajuuden skannerista: ilman niitä merge-portti ja auditointi ajavat
  deterministiset skannauksensa hiljaisina no-opeina, joten kone kertoo sen itse eikä
  ohjeen ajantasaisuus ole ainoa suoja.

Paketti **ei asenna mitään** — se kertoo, mitä puuttuu. Asennussarake valitaan koneelle:
Linuxilla, jolla on `apt-get`, vihjeet tulevat Ubuntu-sarakkeesta, muualla
Homebrew-sarakkeesta.

`Kuka tarvitsee` -arvot: `core` = jokainen ajo, `security` = merge-portin ja
tietoturva-auditoinnin skannerit, `poller` = pollerit, `action` = Ohjaamon toimintopalvelu,
`reviewer` = vaihtoehtoinen merge-portin katselmoija, `driver` = vaihtoehtoinen
claude-kutsutapa, `maintenance` = ylläpitäjän julkaisutyökalu.

<!-- deps-table:begin -->
| Riippuvuus | Taso | Kuka tarvitsee | macOS (Homebrew) | Ubuntu / Sprite (apt tai julkaisubinääri) | Lisenssi | Käyttötarkoitus |
|---|---|---|---|---|---|---|
| `git` | required | core | brew install git | sudo apt-get install git | GPL-2.0 | needed to update the package (submodule pin) and by every run |
| `gh` | required | core | brew install gh | sudo apt-get install gh (older releases: GitHub's own apt repository, cli.github.com) | MIT | GitHub CLI — orchestrate.sh and pr-watch.sh depend on it |
| `jq` | required | core | brew install jq | sudo apt-get install jq | MIT | JSON handling in orchestrate.sh, poller.sh and pr-watch.sh |
| `claude` | required | core | install Claude Code natively so `claude` is on PATH (npm-package alternative: npm i -g @anthropic-ai/claude-code and set RUN_ISSUES_CLAUDE_CMD to the npx invocation) | install Claude Code natively so `claude` is on PATH (npm-package alternative: npm i -g @anthropic-ai/claude-code and set RUN_ISSUES_CLAUDE_CMD to the npx invocation) | proprietary | the default RUN_ISSUES_CLAUDE_CMD invokes the native `claude` command |
| `timeout` | optional | core | brew install coreutils (Git Bash on Windows: scoop install coreutils) | sudo apt-get install coreutils (preinstalled on Ubuntu) | GPL-3.0 | bounds every claude call (timeout or gtimeout); without it calls run unbounded |
| `gitleaks` | optional | security | brew install gitleaks | download the linux_x64 tarball (8.19 or newer) from https://github.com/gitleaks/gitleaks/releases and put gitleaks on PATH; Ubuntu's apt package may be older than 8.19 | MIT | deterministic secret scan in the merge gate and the security audit; without it the scan is a logged no-op |
| `osv-scanner` | optional | security | brew install osv-scanner | download osv-scanner_linux_amd64 from https://github.com/google/osv-scanner/releases, rename it to osv-scanner and put it on PATH | Apache-2.0 | deterministic dependency-vulnerability scan in the merge gate and the security audit; without it the scan is a logged no-op |
| `tmux` | optional | poller | brew install tmux | sudo apt-get install tmux | ISC | only the pollers need it (they exit 0 without it, so a missing tmux looks like an idle poller) |
| `python3` | optional | action | xcode-select --install | sudo apt-get install python3 | PSF-2.0 | only the Ohjaamo action service needs it (action-server.sh) |
| `codex` | optional | reviewer | Codex CLI is optional and never installed by this package: install it yourself so `codex` is on PATH, or set PR_WATCH_SECURITY_REVIEWER=claude | Codex CLI is optional and never installed by this package: install it yourself so `codex` is on PATH, or set PR_WATCH_SECURITY_REVIEWER=claude | Apache-2.0 | only when PR_WATCH_SECURITY_REVIEWER selects Codex as the merge gate's reviewer |
| `npx` | optional | driver | brew install node (or nvm install --lts) | sudo apt-get install nodejs npm (or nvm install --lts) | MIT | only when RUN_ISSUES_CLAUDE_CMD is the npm-package (npx) invocation |
| `git-filter-repo` | optional | maintenance | brew install git-filter-repo | sudo apt-get install git-filter-repo | MIT | only publish-release.sh (maintainer's mirror publishing) |
<!-- deps-table:end -->
