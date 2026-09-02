---
name: container-build
description: Use before the first container build in a project — you are adding a Dockerfile, wiring up a deploy target that builds an image, or an existing image build is slow, never hits the layer cache, or may be shipping files that were never meant to leave the machine. Covers writing .dockerignore before the first build and what the build context picks up without it.
when_to_use: A project is getting its first Dockerfile or its first container build, or an image build is slow, cache-missing, or suspected of carrying secrets and local artefacts into the image.
version: 1.0.0
---

# Konttibuild

## Kirjoita `.dockerignore` ennen ensimmäistä buildia

Ei ensimmäisen jälkeen. Buildaus lähettää **koko build-kontekstin** daemonille ennen kuin
yhtäkään `Dockerfile`n riviä on suoritettu, joten konteksti on jo koossa siinä vaiheessa kun
ensimmäisestä buildista voisi oppia mitään.

Ilman `.dockerignore`ä konteksti imaisee mukaansa ainakin:

| Mikä | Seuraus |
|---|---|
| `node_modules/` ja vastaavat riippuvuushakemistot | Konteksti kasvaa satoihin megatavuihin; buildi hidastuu joka kerta |
| `.git/` | Koko historia siirtyy — usein kontekstin suurin yksittäinen osa |
| `.env`, `.env.*` | **Salaisuudet päätyvät imageen.** Image on jaettava artefakti; poistaminen myöhemmästä kerroksesta ei poista niitä aiemmasta |
| Build-artefaktit (`dist/`, `build/`, `.next/`, coverage-raportit) | Paikallinen tuloste ylikirjoittaa kontissa tuotetun tai sotkee sen |

Kaksi seurausta, joista toinen on hiljainen:

- **Layer-cache rikkoutuu.** `COPY . .` invalidoituu joka kerta kun *mikä tahansa* kontekstin
  tiedosto muuttuu — myös lokitiedosto, editorin tilatiedosto tai testiajon tuloste. Buildi
  näyttää toimivan, se vain ei koskaan osu cacheen.
- **Salaisuudet vuotavat imageen.** Tämä ei näy mistään buildin tulosteesta eikä ajossa. Se
  löytyy vasta kun image on jo jaettu.

Sama koskee **hallinnoituja alustoja, jotka buildaavat imagen puolestasi** etäkoneella: ne
lukevat `.dockerignore`n samalla tavalla, ja ilman sitä kontekstin lataus verkon yli on
lisäksi se hitain osa deploytä.

## Mitä listaan minimissään

Ota lähtökohdaksi projektin `.gitignore`n sisältö — mutta **älä oleta niitä samoiksi**:
`.dockerignore` ei peri `.gitignore`ä, ja niiden oikea sisältö eroaa molempiin suuntiin.
`.git/` kuuluu `.dockerignore`en muttei `.gitignore`en; versionhallittu `Dockerfile`
puolestaan voi kuulua `.dockerignore`en, koska sitä ei tarvita kontekstin sisällä.

Riippuvuushakemistot, VCS-hakemisto, ympäristötiedostot, build-artefaktit, testien tulosteet
ja editorin/käyttöjärjestelmän roskatiedostot.
