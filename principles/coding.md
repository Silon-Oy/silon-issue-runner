# Koodauskäytännöt

Kanoninen, aina päällä oleva koodausstandardi. Tämä on **yksi teksti**: muut kanavat
viittaavat tähän eivätkä tiivistä tai kopioi sitä.

**Omistajuuspredikaatti — lue tämä ennen kuin lisäät tähän rivin:**

> Nimeääkö teksti yhtäkään henkilöä, konetta, organisaatiota, asiakasta, credentialia tai
> paketin ulkopuolista polkua? Jos kyllä, se on **konfiguraatiota** eikä kuulu tänne.

Tänne kuuluu vain se, joka pätee kaikkeen koodiin ja jonka voi lukea tuntematta yhtään
henkilöä, konetta tai organisaatiota. Predikaattia vartioi `tests/test-principles-neutrality.sh`.

## Ulkoiset riippuvuudet

Kun ehdotat tai otat käyttöön ulkoisen paketin (npm, Composer, pip, …), **varmista sen
luotettavuus ennen suositusta**. Tarkista:

- ylläpitoaktiivisuus: viimeaikaiset commitit, julkaisut, vastaukset issueihin
- riittävä contributor-pohja — vältä yhden ylläpitäjän projekteja ei-triviaaleissa riippuvuuksissa
- selkeä dokumentaatio ja käyttöesimerkit
- ei tunnettuja haavoittuvuuksia (`npm audit`, vastaava ekosysteemin työkalu)

**Epäselvässä tapauksessa vakiintunut voittaa uudemman**, vaikka uudemmassa olisi hieman
paremmat ominaisuudet. Nosta huolet esiin ennen kuin etenet.

## Koodin kahdentuminen

Jos jaettu moduuli, uudelleenkäytettävä workflow tai abstraktio pettää, **selvitä miksi** —
älä inlinetä kopiota "korjauksena".

## Uudelleenkäytettävät abstraktiot

Erota geneerinen mekanismi ominaisuuskohtaisesta sisällöstä **jo ensimmäisessä
toteutuksessa** — älä odota toista käyttötapausta tai eksplisiittistä pyyntöä. Erota, kun

- koodi renderöi tai käsittelee yleistä rakennetta (lomakekentät, taulukkorivit,
  sähköpostit, admin-sarakkeet, API-payloadit), jota ohjaa ominaisuuskohtainen data,
- sisarominaisuus voisi uskottavasti tarvita samaa mekanismia, ja
- geneerisen osan voi irrottaa ilman spekulatiivista joustavuutta — irrota vain se, mitä
  nykyinen ominaisuus tosiasiassa käyttää.

Valitse yksinkertaisin mekanismi, joka mallintaa suhteen: jaettu funktio tai apuväline →
trait → abstrakti kantaluokka. Ei rekistereitä, plugin-järjestelmiä tai konfiguraatiokerroksia
hypoteettisia tarpeita varten — puhdas sauma, ei kehystä.

Kerro yhteenvedossa lyhyesti, mikä tehtiin uudelleenkäytettäväksi ja miten tuleva ominaisuus
käyttäisi sitä.

## Ympäristömuuttujat

Kun lisäät tai poistat ympäristömuuttujia koodista, päivitä aina `.env.example`, jos
projektissa sellainen on.

## Testit

Kirjoita yksikkötestejä suhteessa projektin kokoon ja kehityshistoriaan. Painopiste on
kriittisessä liiketoimintalogiikassa, ja testien on noudatettava projektin olemassa olevia
testauskäytäntöjä.

## Debuggaus

Jos voit tarkistaa virhelokit itse, tee se itse äläkä pyydä ihmistä tarkistamaan puolestasi.

## JavaScript

Älä käytä jQueryä, ellei sitä eksplisiittisesti pyydetä. Suosi vanilla-JavaScriptiä tai
moderneja frameworkeja.

## Älä kysy sitä, minkä voit itse selvittää

Älä kysy asioita, jotka voit luotettavasti selvittää itse — lukemalla tiedostoja,
tarkistamalla konfiguraation tai ajamalla komennon.

## Suunnitelmissa ei ole aikatauluarvioita

Älä kirjoita suunnitelmiin aikatauluarvioita (esim. "½ päivää", "1–2 päivää", "sprint 1").
Aikaestimointi perustuu ihmisen tekemään työhön eikä päde agenttisen koodauksen aikakaudella.
Jäsennä suunnitelmat vaiheina tai prioriteetteina, ei kestona.

## Koodin kieli

Koodi, koodikommentit ja commit-viestit kirjoitetaan **englanniksi**; commit-viesteissä
käytetään conventional commits -muotoa silloin kun se sopii projektiin.

## Kehityspalvelimen portti worktreessä

Kun työskentelet git-worktreessä, kehityspalvelimen oletusportti voi olla jo varattu.
Tarkista se ja valitse vapaa portti ennen palvelimen käynnistämistä.
