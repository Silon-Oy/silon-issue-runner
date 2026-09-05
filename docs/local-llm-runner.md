# Ajokone paikallisella mallilla — ToshLLM + Claude Code Intel-Macilla

> **Tila:** todennettu osittain 3.9.2026. Pystytys, savutesti ja S6 (cycle review) on ajettu
> oikeaa kohderepoa vasten Intel-MacBookilla, jossa Qwen3-8B pyörii ToshLLM:ssä. **S8:aa
> (implementer) ei ole vielä viety läpi:** kolmesta yrityksestä yksi pysähtyi review-porttiin
> suunnitellusti, yksi kaatui koneen mukana ja yksi päättyi GPU:n `Compute error`-tilaan.
> Kaikki tämän dokumentin luvut on mitattu, ei arvioitu.

Ajatus on sama kuin [Spritessä](sprite-runner.md): erillinen ajokone, jolla on oma
runner-asennus, oma `gh`-tunnistautuminen ja oma poimintalabel. Ero on mallissa: Claude Code
-CLI puhuu `ANTHROPIC_BASE_URL`in kautta paikalliselle palvelimelle, eikä yhtäkään mallikutsua
lähde koneen ulkopuolelle. Runnerin koodiin ei tarvita muutoksia — sen ainoa mallisauma on
`RUN_ISSUES_CLAUDE_CMD`, ja kaikki paikallisen mallin tarvitsema tulee kääreskriptistä.

## Miksi ToshLLM eikä Ollama

Intel-Macilla Ollama laskee pelkällä CPU:lla: Metal-kiihdytys on siinä vain Apple Siliconille.
ToshLLM on llama.cpp AMD-korjauksilla ja ajaa mallin Metalilla Radeon-näytönohjaimella. Se
tarjoaa suoraan sen, mitä Claude Code päätepisteeltä tarvitsee:

| Claude Code tarvitsee | ToshLLM (llama.cpp b10665) |
|---|---|
| `POST /v1/messages` + streaming | on |
| `/v1/messages/count_tokens` | on (Ollamalta puuttuu) |
| Työkalukutsut | on, kun mallin chat-template tukee (Qwen3 tukee) |
| Mallin löytäminen | `GET /v1/models`; Claude Code ≥ 2.1.129 lukee aliakset itse |
| Prompt caching (Anthropic-muoto) | ei, mutta llama.cpp:n prefix-cache korvaa sen käytännössä |

Sama kytkentä toimii LM Studiolla ja paljaalla `llama-server`illä, mutta ne eivät tuo
AMD-Metal-polkua Intel-koneelle. Apple Silicon -koneella valinta olisi eri.

## Mitattu

Kone: MacBook Pro 16" (Intel, 64 GB RAM), Radeon Pro 5500M 8 GB. Malli Qwen3-8B Q4_K_M
(5,0 GB), ikkuna 32 768, KV-cache q8_0, flash attention päällä, pohdinta pois.

| Mittari | Arvo |
|---|---|
| Generointi | 23 tok/s |
| Prefill | 190 tok/s |
| Työkalukutsu (20 tokenia) | 2,9 s |
| Claude Coden aloituskehote, täysi työkalulista + skillit | 19 695 tokenia (puhdas config), 39 506 (ylläpitäjän config) |
| Sama rajatulla työkalulistalla ja `--disable-slash-commands` | **4 383 tokenia** |
| Savutesti (listaa tiedostot + yksi lause), kylmä / lämmin | 227 s / 68 s |
| S0–S5 | 23 s |
| S6 cycle review | 2 min 57 s, päätös PROCEED |

Näytönohjaimen muisti on kova raja, ja sen ylitys ei kaadu vaan **hidastuu 40-kertaisesti**
(mitattu 0,6 tok/s), koska Metal alkaa sivuttaa:

| Ikkuna | Painot Q4 | KV-cache f16 | KV-cache q8_0 | Mahtuu 8 GB:iin |
|---|---|---|---|---|
| 16k | 5,0 GB | 2,4 GB | 1,2 GB | kyllä |
| 32k | 5,0 GB | 4,7 GB | 2,4 GB | vain q8-cachella |
| 40k (mallin maksimi) | 5,0 GB | 5,9 GB | 3,0 GB | niukasti q8-cachella |

## Pystytys

### 1. Työkalut

Runnerin S0-portti vaatii `git`, `gh` ja `jq`; PHP-kohderepo lisäksi `php` ja `composer`;
tmux nimetyn ajon taustalle. **Homebrew ei enää tue Intel-macOS:ää (syyskuu 2026):**
pullotetut paketit asentuvat (gh, git, jq, tmux todettu), lähteestä käännettävät kaatuvat
vanhentuneisiin Command Line Toolsiin. `coreutils` (`gtimeout`) on jälkimmäistä lajia.

```bash
brew install git gh jq tmux        # pullot löytyvät
brew install coreutils             # kaatuu ilman Xcode 26.3:n Command Line Toolsia
```

Ilman `gtimeout`ia runner ajaa **ilman aikarajaa** (preflight pitää sitä valinnaisena, ja
`lib/claude-call.sh` varoittaa). Jumiutunut mallikutsu ei silloin katkea 3600 s:ssa. Väliaikainen
ratkaisu on bash-kääre, joka toteuttaa runnerin käyttämän osajoukon GNU `timeout(1)`:stä
(`--kill-after`, kesto, exit 124, koko prosessiryhmän tappo). Sijoita se polkuun
`/usr/local/bin/gtimeout` ja korvaa oikealla coreutilsilla heti kun työkaluketju sallii:

```bash
#!/usr/bin/env bash
# gtimeout — minimal stand-in for GNU timeout(1). Supports the subset claude-issue-runner
# uses: gtimeout [-k N | --kill-after=N] [-s SIG] DURATION COMMAND [ARG]...
# Exit 124 on timeout, otherwise the command's own status. The command runs in its own
# process group and the whole group is signalled, like GNU timeout does.
set -u
kill_after=""; sig=TERM
while [ $# -gt 0 ]; do
  case "$1" in
    --kill-after=*) kill_after="${1#*=}"; shift ;;
    -k)             kill_after="$2"; shift 2 ;;
    --signal=*)     sig="${1#*=}"; shift ;;
    -s)             sig="$2"; shift 2 ;;
    --foreground|--preserve-status|-v|--verbose) shift ;;
    --version)      echo "gtimeout (bash shim for claude-issue-runner) 0.2"; exit 0 ;;
    --)             shift; break ;;
    -*)             echo "gtimeout: unsupported option: $1" >&2; exit 125 ;;
    *)              break ;;
  esac
done
[ $# -ge 2 ] || { echo "usage: gtimeout [-k N] [-s SIG] DURATION COMMAND [ARG]..." >&2; exit 125; }
dur="$1"; shift
case "$dur" in *d) dur=$(( ${dur%d} * 86400 ));; *h) dur=$(( ${dur%h} * 3600 ));; *m) dur=$(( ${dur%m} * 60 ));; *s) dur="${dur%s}";; esac
case "$kill_after" in *s) kill_after="${kill_after%s}";; esac
tmp=$(mktemp -d -t gtimeout.XXXXXX) || exit 125
flag="$tmp/timed-out"; done_marker="$tmp/done"
set -m; "$@" & child=$!; set +m
( sleep "$dur"; [ -e "$done_marker" ] && exit 0; : > "$flag"; kill -"$sig" -- -"$child" 2>/dev/null
  if [ -n "$kill_after" ]; then sleep "$kill_after"; [ -e "$done_marker" ] && exit 0; kill -KILL -- -"$child" 2>/dev/null; fi
) 2>/dev/null & watchdog=$!
forward() { kill -TERM -- -"$child" 2>/dev/null; }
trap forward TERM INT HUP
wait "$child" 2>/dev/null; rc=$?
trap - TERM INT HUP
: > "$done_marker"; pkill -P "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
if [ -e "$flag" ]; then rm -rf "$tmp"; exit 124; fi
rm -rf "$tmp"; exit "$rc"
```

Todennettu: normaali paluuarvo säilyy, aikakatkaisu antaa 124, TERM-signaalin ohittava
prosessi tapetaan ryhmineen, jäänteitä ei jää, ja `gtimeout 20 claude --version` kulkee läpi
S0-preflightin proben tavoin.

### 2. Claude Code

Natiiviasennus tunnistaa Intel-koneen ja hakee `darwin-x64`-binäärin (julkaisumanifestissa
`darwin-arm64`:n rinnalla; vaatimus macOS 13+). Anthropic-tiliä ei kuluteta: kun
`ANTHROPIC_BASE_URL` ja `ANTHROPIC_AUTH_TOKEN` on asetettu, CLI ei tee OAuth-kirjautumista eikä
lähetä yhtäkään mallikutsua Anthropicille.

```bash
curl -fsSL https://claude.ai/install.sh | bash
~/.local/bin/claude --version          # 2.1.259 (Claude Code) tai uudempi
```

### 3. GitHub-tunnistautuminen — token tiedostoon, ei avainnippuun

macOS:llä `gh auth login` tallentaa tokenin oletuksena Avainnippuun. Pääsy siihen on
prosessikohtainen: kun ssh-istunnon, tmuxin tai LaunchAgentin käynnistämä `gh` lukee kohteen
ensimmäistä kertaa, macOS näyttää lupakyselyn koneen **näytöllä**, ja odottava `gh auth status`
jumittuu 30 sekunniksi ja raportoi lopulta `token is invalid`. Spritessä (Linux) sama
kirjautuminen toimi suoraan, koska avainnippua ei ole ja token menee tiedostoon.

```bash
gh auth login -h github.com --insecure-storage      # token -> ~/.config/gh/hosts.yml (0600)
gh auth status                                       # ✓ Logged in ... (hosts.yml)
```

### 4. Runner ja kohderepo

```bash
gh repo clone <runner-repo> ~/projektit/claude-issue-runner
bash ~/projektit/claude-issue-runner/install.sh     # ilman --with-launchagents, ks. avoimet kysymykset
gh repo clone <kohde> ~/projektit/<kohde>
```

Asennin raportoi puuttuvat riippuvuudet neuvoa-antavasti; S0-portti tekee saman fataalina.

### 5. ToshLLM:n asetukset

Neljä lippua palvelimen lisäargumentteihin, ja jokainen niistä on mitattu välttämättömäksi:

| Lippu | Miksi |
|---|---|
| `--reasoning off` | Qwen3 käytti yksisanaisessa kysymyksessä koko vastausbudjetin pohdintaan. `--reasoning-format` **ei** riitä: se muuttaa vain esitystapaa |
| `-ctk q8_0 -ctv q8_0` | 32k-ikkunan f16-KV-cache ei mahdu 8 GB:iin; ilman tätä generointi putosi 23 → 0,6 tok/s |
| `-fa on` | kvantisoitu V-cache vaatii flash attentionin |
| konteksti 32 768 | 16k ei riitä: Claude Coden rajattukin aloituskehote + kohderepon CLAUDE.md + koodauskehote on 16–24k |

llama.cpp:n argumenttijäsennin ei tunne `--lippu=arvo`-muotoa: `--reasoning=off` on sille
tuntematon lippu ja palvelin kaatuu käynnistyksessä. Lippu ja arvo erotetaan välilyönnillä.

Tarkistus, jonka pitää tuottaa `text`-lohko "OK" ja `output_tokens` selvästi alle 64:

```bash
curl -s http://127.0.0.1:8080/v1/messages \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"<GET /v1/models -id>","max_tokens":64,"messages":[{"role":"user","content":"Vastaa tasan yhdellä sanalla: OK"}]}' \
  | jq '{stop_reason, usage, content}'
```

Mallin id on ToshLLM:ssä gguf-tiedoston polku (esim. `/Users/<user>/models/Qwen3-8B-Q4_K_M.gguf`),
ja `GET /v1/models` kertoo `meta.n_ctx`-kentässä voimassa olevan ikkunan.

### 6. Kääre ja env-tiedosto

Runner kutsuu ajuria muodossa `<cmd> --model X --append-system-prompt-file F
--dangerously-skip-permissions -p <prompt>`. Kääre `~/.local/bin/claude-toshllm` lisää eteen
sen, minkä paikallinen malli tarvitsee, ja kieltäytyy sekunnissa jos palvelin ei vastaa —
ToshLLM on GUI-sovellus, eikä S0-preflight probea päätepistettä:

```bash
#!/usr/bin/env bash
# claude-toshllm — RUN_ISSUES_CLAUDE_CMD wrapper: Claude Code CLI against ToshLLM's local model.
set -euo pipefail
TOSHLLM_URL="${TOSHLLM_URL:-http://127.0.0.1:8080}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
if ! models_json=$(curl -sf -m 5 "$TOSHLLM_URL/v1/models"); then
  echo "claude-toshllm: ToshLLM does not answer at $TOSHLLM_URL (start the app and its server)" >&2
  exit 127
fi
model="${TOSHLLM_MODEL:-$(printf '%s' "$models_json" | jq -r '.data[0].id')}"
n_ctx=$(printf '%s' "$models_json" | jq -r --arg m "$model" '.data[] | select(.id==$m) | .meta.n_ctx // empty')
[ -n "$model" ] || { echo "claude-toshllm: /v1/models lists no model" >&2; exit 127; }
export ANTHROPIC_BASE_URL="$TOSHLLM_URL"
export ANTHROPIC_AUTH_TOKEN="${TOSHLLM_API_KEY:-toshllm}"   # any value when API protection is off
export ANTHROPIC_API_KEY=""
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${n_ctx:-32768}"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-4096}"
export DISABLE_AUTOUPDATER=1
# The runner's own --model (RUN_ISSUES_CLAUDE_MODEL) wins when given.
for a in "$@"; do [ "$a" = "--model" ] && { model=""; break; }; done
exec "$CLAUDE_BIN" ${model:+--model "$model"} \
  --tools Bash,Read,Edit,Write,Glob,Grep --disable-slash-commands "$@"
```

Kolme riviä ovat ne, joita ilman ajo ei toimi, ja jokainen on mitattu epäonnistumisena:

- **`--tools … --disable-slash-commands`** pudottaa aloituskehotteen 19 695 → 4 383 tokeniin.
  Ilman rajausta 8B-malli vastasi kysymykseen "sano OK" käynnistämällä aliagentin, joka kutsui
  `/init`-skilliä ja alkoi kirjoittaa CLAUDE.md:tä, kunnes konteksti täyttyi. Pieni malli ei
  osaa jättää tarjolla olevaa työkalua käyttämättä. Hinta: S6:n aliagentit ja skillit jäävät
  pois; `prompts/01-cycle-review.md` sanoo tämän olevan sallittua.
- **`CLAUDE_CODE_MAX_CONTEXT_TOKENS=<n_ctx>`** kertoo CLI:lle oikean ikkunan; muuten se
  olettaa 200k eikä tiivistä ajoissa, ja palvelin hylkää pyynnön 400:lla.
- **`CLAUDE_CODE_MAX_OUTPUT_TOKENS=4096`**: CLI:n oletusvaraus ulostulolle on niin suuri, että
  32k-ikkunalla se hylkää toisen kierroksen **itse** ("Prompt is too long", 11 ms tuloksen
  jälkeen, mitään ei lähetetty) vaikka syöte oli 22k. Vaihtoehto
  `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` toimii myös, mutta jättää ylivuodon
  palvelimen 400-virheen varaan, jolloin siitä toipuva tiivistys kaatuu samaan rajaan.

Env-tiedosto `~/.config/run-issues/env`:

```bash
export RUN_ISSUES_CLAUDE_CMD="$HOME/.local/bin/claude-toshllm"
export RUN_ISSUES_CLAUDE_MODEL=""      # malli valitaan kääreessä /v1/models-listasta
export TOSHLLM_URL="http://127.0.0.1:8080"
```

Tämä riittää #200:n jälkeen. **Vanhemmalla runnerilla** `RUN_ISSUES_CLAUDE_CMD` on annettava
lisäksi prosessin ympäristössä, ks. sudenkuoppa 3.

## Ajon käynnistys

Nimetty ajo tmuxiin, jotta ssh-katko ei tapa sitä. Ilman `RUN_ISSUES_AUTO=1` ajo pysähtyy
S6:n jälkeen review-porttiin (exit 10), mikä on mittauspiste ennen kalleinta vaihetta:

```bash
cat > ~/run-issue.sh <<'EOF'
#!/usr/bin/env bash
export PATH=/usr/local/bin:$HOME/.local/bin:$PATH
export RUN_ISSUES_CLAUDE_CMD="$HOME/.local/bin/claude-toshllm"   # vanhemmalla runnerilla pakollinen, ks. sudenkuoppa 3
export TOSHLLM_URL="http://127.0.0.1:8080"
"$HOME/.claude/scripts/run-issues/orchestrate.sh" "$HOME/projektit/<kohde>" "$1" 2>&1 | tee -a "$HOME/run-issue-$1.log"
echo "EXIT=${PIPESTATUS[0]}" | tee -a "$HOME/run-issue-$1.log"
sleep 7200
EOF
tmux new -d -s issue-63 "bash ~/run-issue.sh 63"
tail -f ~/run-issue-63.log
```

Jatko portin jälkeen. Env-tiedosto pätee myös `--resume`-polulla, joten ajuria ei tarvitse
toistaa; vanhemmalla runnerilla (sudenkuoppa 3) se on annettava:

```bash
~/.claude/scripts/run-issues/orchestrate.sh --resume <run-dir> --decision PROCEED
```

Run-dir on kohderepon `.claude/run-issues/<run-id>`; `01-cycle-review.out` ja `state.jsonl`
kertovat S6:n tuloksen ja keston. `run.json.host` on koneen lyhyt konenimi (`runner_host`),
ja `cleanup-run.sh` kieltäytyy vieraasta hostista — siivous tehdään samalla koneella.

## Verifiointi

```bash
# 1. Palvelin ja ikkuna
curl -s http://127.0.0.1:8080/v1/models | jq -r '.data[0] | "\(.id) n_ctx=\(.meta.n_ctx)"'

# 2. Generointinopeus — alle 5 tok/s tarkoittaa VRAM-ylivuotoa tai vikatilaista GPU:ta (sudenkuoppa 7)
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"<id>","max_tokens":60,"messages":[{"role":"user","content":"Kirjoita kolme lausetta ketusta."}]}' \
  | jq '{gen_tps: .timings.predicted_per_second, prompt_tps: .timings.prompt_per_second}'

# 3. Kääre S0-proben tavoin
gtimeout 20 ~/.local/bin/claude-toshllm --version

# 4. Savutesti runnerin lipuilla, kahdesti: toisen pitää olla selvästi nopeampi (prefix-cache)
cd ~/projektit/<kohde> && ~/.local/bin/claude-toshllm --append-system-prompt-file \
  ~/projektit/claude-issue-runner/principles/coding.md --dangerously-skip-permissions \
  --output-format json -p 'Listaa tämän hakemiston tiedostot ja kerro yhdellä lauseella mitä repo tekee.' \
  | jq '{turns: .num_turns, input: .usage.input_tokens, cache_read: .usage.cache_read_input_tokens, result}'
```

Odotusarvot mitatulla kokoonpanolla: 2 kierrosta, syöte 20–25k tokenia, kylmä ajo alle 4 min,
lämmin alle 1,5 min.

## Sudenkuopat

1. **Homebrew ja Intel.** Ks. pystytys 1. `brew install` voi myös ehdottaa Command Line
   Toolsin päivitystä, jota Software Update ei tarjoa — se haetaan käsin Applen
   kehittäjäsivulta. Tämän dokumentin kääre kiertää coreutilsin puutteen, ei muita.

2. **Avainnippu ja ssh.** Ks. pystytys 3. Sama koskee LaunchAgent-polleria: ilman
   `--insecure-storage` poller jumittuisi hiljaa samaan lupakyselyyn.

3. **Env-tiedoston `RUN_ISSUES_CLAUDE_CMD` ei tullut voimaan — korjattu #200:ssa.**
   `lib/claude-call.sh` antoi `RUN_ISSUES_CLAUDE_CMD`:lle, `RUN_ISSUES_CLAUDE_MODEL`ille ja
   `RUN_ISSUES_CLAUDE_TIMEOUT`ille oletuksen jo source-hetkellä, ja `lib/machine-env.sh`:n
   snapshot (#144, kutsujan etuoikeus) piti tuota oletusta kutsujan valintana ja palautti sen
   env-tiedoston arvon päälle. Oire oli S0-preflightin rivi
   `MISSING (required): @anthropic-ai/claude-code` vaikka env-tiedosto nimesi ajurin.
   Tilannekuva otetaan nyt `machine_env_capture`illa ennen kirjastojen latausta, joten
   env-tiedosto riittää yksin. **Jos ajat vanhempaa runneria**, kierto on antaa muuttuja
   prosessin ympäristössä (`export` ennen `orchestrate.sh`-kutsua). Vian palaamisen huomaa
   yhdellä komennolla paketin juuressa:
   ```bash
   bash -c '. lib/preflight.sh; . lib/machine-env.sh; machine_env_capture
     . lib/claude-call.sh; log(){ :; }
     RUN_ISSUES_ENV_FILE=$(mktemp); echo "export RUN_ISSUES_CLAUDE_CMD=/from/file" > "$RUN_ISSUES_ENV_FILE"
     source_machine_env; echo "$RUN_ISSUES_CLAUDE_CMD"'      # odotus: /from/file
   ```
   Pollerimallissa vika ei näkynyt, koska poller exporttaa `poller.env`in muuttujat ympäristöön.

4. **"unrecognized_model"-varoitus on vaaraton.** CLI kirjoittaa
   `[claude-code:unrecognized_model]`-rivin stderriin jokaisesta kutsusta, koska gguf-polku ei
   ole sen mallikatalogissa. Se päätyy `*.out`-tiedostoihin, eikä tarkoita virhettä.

5. **Kaksi kohtaa täyttää ikkunan ilman että malli tekee mitään.** Kohderepon CLAUDE.md ja
   runnerin koodauskehote (`principles/coding.md` + `auto-run-contract.md`, 9 KB) tulevat
   jokaiseen vaiheeseen. 36 KB:n CLAUDE.md on yksin 9k tokenia 32k:sta. Kohderepon
   CLAUDE.md kannattaa pitää alle 8 KB:ssä, jos sitä ajetaan paikallisella mallilla.

6. **Vain yksi pyyntö kerrallaan.** ToshLLM käynnistää palvelimen `--parallel 1`:llä.
   Sovelluksen oma chat tai benchmark samaan aikaan jonottaa runnerin pyyntöjen kanssa, ja
   Claude Coden aliagentit (jos työkalurajaus poistetaan) jonottavat keskenään.

7. **GPU:n vikatila ei korjaannu prosessia vaihtamalla.** Kaatumisen (kone resetoitui kesken
   S6:n ilman paniikkiraporttia) jälkeen palvelin vastasi `500 Compute error` jokaiseen
   pyyntöön, ja uudelleen käynnistetty palvelin samoilla lipuilla laski 0,4 tok/s — GPU oli
   kiireinen mutta viisikymmentä kertaa hitaampi, ilman lämpökuristusta tai VRAM-ylivuotoa.
   Oire on AMD-ajurin resetoima laite. Runnerin puolella se näkyy S6:n tulosteena, jossa on
   vain varoitusrivi ja `API Error: 500`, ja orkestraattori exittaa 1:llä **ilman omaa
   lokiriviä**, jättäen ajon tilaan `initialized` (siivous: `cleanup-run.sh --issue N --yes
   --force`). Ainoa todettu korjaus on koneen uudelleenkäynnistys; verifioinnin kohta 2 ennen
   jokaista ajoa kertoo, onko GPU kunnossa.

8. **Ssh-katko ei tapa ajoa, mutta vahdin kyllä.** Ajo puhuu `localhost`iin ja jatkuu tmuxissa;
   verkkoa tarvitaan vasta S7b:n `composer install`issa ja pushissa. Katkeileva Wi-Fi on silti
   pollerikoneelle ongelma, ja koneen on oltava nukkumatta (`pmset -c sleep 0`).

9. **Mallin laatu S6:ssa.** Qwen3-8B noudatti reviewn rakennetta ja tuotti oikean
   päätösrivin, mutta ei lukenut repoa ja teki yhden asiavirheen (nimesi työkalun, jota repossa
   ei ole). Porttina kelvollinen, sisältönä ohut. Suomenkielinen tuloste on 8B-mallille
   työlästä, ja runnerin promptit ovat suomeksi.

## Avoimet kysymykset

- **S8 implementer on todentamatta.** Monen tiedoston muutos, `composer install`, testiajo ja
  PR 32k:n ikkunalla ja 23 tok/s:lla on tämän kokoonpanon varsinainen koe. Todennäköisimmät
  lopputulokset ovat aikakatkaisu, kontekstin ylivuoto kesken työn tai epätäydellinen PR.
- **Malli.** Qwen3-8B:n kova katto on 40 960 tokenia. 64 GB:n RAM antaa tilaa
  Qwen3-Coder-30B-A3B:lle (256k natiivi konteksti, 3B aktiivista) CPU-offloadilla, mutta
  8 GB:n VRAM pitää suurimman osan asiantuntijoista CPU:lla, eikä sen nopeutta ole mitattu.
- **Pollerimalli.** LaunchAgentteja ei ole asennettu. Ennen sitä: `RUN_ISSUES_POLLER_HOSTS`
  `poller.env`iin, oma poimintalabel (labelit ANDataan, ks. Sprite-dokumentti), ja
  sudenkuopan 3 kierto `poller.env`in `export`-rivinä. Ajokone ei saa kilpailla samoista
  issueista muiden koneiden kanssa.
- **Palvelimen elinkaari.** ToshLLM on GUI-sovellus, joka ei käynnistä palvelinta uudelleen
  jos prosessi kuolee. Ajokone, jonka mallipalvelin vaatii ihmisen klikkauksen, ei ole
  valvomaton; kääre tekee puutteen näkyväksi (exit 127 sekunnissa), ei korjaa sitä.
