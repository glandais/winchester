# Notes pour la revue App Store (version 1.0.0)

Copie canonique du champ App Review Information → Notes. `asc metadata` ne gère
pas les détails de revue : ce fichier est la source, et il se pousse à la main.

```bash
asc review details-for-version --version-id "<VERSION_ID>"   # lire, et relever l'id du détail
asc review details-update --id "<DETAIL_ID>" --notes "$(sed -n '/^---$/,$p' metadata/review-notes.md | tail -n +2)"
```

Le garder vrai : une personne le lit avec l'app ouverte.

---

Winchester is an offline simulator of the mechanical hard disks of 1993 to 2012. It computes the motion of the head over a simulated volume and renders the sound that motion would make. Nothing is recorded, sampled or downloaded, and the app never sends anything anywhere: there is no account, no server, no analytics and no network access at all. The one outbound link is "Support Winchester" in the Settings tab, which opens the developer's Ko-fi page in Safari: a voluntary tip that unlocks nothing — the app has no paid content or feature.

WHY THE AUDIO BACKGROUND MODE
A defragmentation pass on a period volume runs for tens of minutes, sometimes several hours — that duration is the point of the app, not a side effect. The audio has to keep playing with the screen locked, exactly as a music player would, so the app declares the `audio` background mode. It plays only while a pass is running and stops with it.

HOW TO TRY IT QUICKLY
Open the app and go through the three welcome screens; the last button, "Listen to a disk", opens the Disks tab. Tap Start on any of the short demos at the top of that tab: the sound begins within a few seconds, and the Pass tab shows the cluster map and the transport controls (Play / Pause). Headphones are strongly recommended: a built-in speaker erases the low end of the rotation and most of the arm's transients. The period disks further down run full defragmentation passes, which take much longer; for a shorter one, open a period disk, choose "Relive this disk" and then "Listen to day N".

NO USER DATA
The app asks for no permission. Disks the user builds are stored on the device and nowhere else.
