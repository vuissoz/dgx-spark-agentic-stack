# ADR-0156 — Identité Git Forgejo gérée dans les préférences OpenHands

## Contexte

OpenHands V1 charge `/.openhands/settings.json` à chaque création de
conversation et applique `git_user_name` et `git_user_email` au runtime. La
seule configuration de `/.openhands/home/.gitconfig` par le bootstrap Forgejo
était donc réécrite par la valeur amont `openhands@all-hands.dev` conservée dans
les préférences persistantes.

## Décision

Le bootstrap Forgejo converge aussi les deux champs Git de `settings.json`
lorsqu'il traite le compte OpenHands existant. Les valeurs par défaut
`OH_GIT_USER_NAME` et `OH_GIT_USER_EMAIL` du service OpenHands sont alignées
sur cette même identité afin que les nouveaux états soient corrects dès leur
création.

## Conséquences

L'identité des commits OpenHands reste traçable dans le Forgejo local, après un
redémarrage comme après l'ouverture d'une nouvelle conversation. Les autres
préférences OpenHands et les identités des autres outils ne sont pas modifiées.
