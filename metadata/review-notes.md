# Notes pour la revue App Store (version 1.0.0)

Copie canonique du champ App Review Information → Notes. `asc metadata` ne gère
pas les détails de revue : ce fichier est la source, et il se pousse à la main.

```bash
asc review details-for-version --version-id "<VERSION_ID>"   # lire, et relever l'id du détail
asc review details-update --id "<DETAIL_ID>" --notes "$(sed -n '/^---$/,$p' metadata/review-notes.md | tail -n +2)"
```

Le garder vrai : une personne le lit avec l'app ouverte.

---

Winchester is an offline simulator of a 1990s mechanical hard disk. It computes the motion of the head over a simulated volume and renders the sound that motion would make. Nothing is recorded, sampled or downloaded, and the app never sends anything anywhere: there is no account, no server, no analytics and no network access at all.

WHY THE AUDIO BACKGROUND MODE
A defragmentation pass on a period volume runs for tens of minutes, sometimes several hours — that duration is the point of the app, not a side effect. The audio has to keep playing with the screen locked, exactly as a music player would, so the app declares the `audio` background mode. It plays only while a pass is running and stops with it.

HOW TO TRY IT QUICKLY
Open the app, go through the three welcome screens, then pick any disk in the gallery and tap Listen. Headphones are strongly recommended: the iPhone speaker erases the low end of the rotation and most of the arm's transients. A pass can be paused, and a shorter one can be heard by picking a day of the disk's life rather than a full defragmentation.

NO USER DATA
The app asks for no permission. Disks the user builds are stored on the device and nowhere else.
