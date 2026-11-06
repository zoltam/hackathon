# Valmet · Huoltoreitti videolle

Käynnistä repositorion juuresta:

```sh
python3 -m http.server 8787 --directory web/dist
```

Avaa http://localhost:8787. Kokeile synteettistä esimerkkiä tai avaa oma video.

1. Pysäytä video sopivaan kuvaan. Rajaa kulkualue ja jokainen este monikulmiolla.
2. Aseta lähtö ja vapaa huoltopaikka laitteen vieressä. A* etsii lyhimmän reitin merkityllä kuvaruudukolla. Esteisiin jätetään ruudukon verran marginaalia.
3. Ympyröi laite ja lisää sen hyväksytyn huolto-ohjeen vaiheet. Lisää uusi kuvakulma aina, kun kamera liikkuu merkittävästi tai video leikkaa.
4. Tallenna merkinnät JSON-tiedostoon tai vie video reitteineen. Videovienti kestää videon toistoajan, ja tiedostomuoto riippuu selaimesta.

Työkalu käsittelee videon paikallisesti selaimessa. Ruudukkoreitti ei mittaa fyysistä matkaa tai tarkista kuvan ulkopuolisia esteitä. Kameraa tai laitetta ei seurata automaattisesti. Videon päälle viedään viisi ensimmäistä työvaihetta. Sivulla näkyy koko ohje.
