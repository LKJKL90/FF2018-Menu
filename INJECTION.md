# Injection dans l'IPA + sideload (v7)

## Identité du tweak

| élément | valeur |
|---|---|
| tweak / dylib | `FFF_XZ` |
| paquet | `com.coremedia.codec` |
| filtre | `com.privateproject.ff2018.v128` |
| install name | `@rpath/FFF_XZ.dylib` |
| emplacement | `Payload/freefireth.app/Frameworks/` |

Aucune chaîne `FF2018`, `XZPROJECT`, `momoZbadou`, `INJECT`, `ESP`,
`Aimbot` ni `MSHookFunction` n'est présente en clair dans le binaire :
les libellés de l'UI sont encodés XOR (`xz_strings.h`, généré par
`tools/gen_strings.py`) et les symboles locaux sont strippés
(`-Wl,-S,-x`). Les noms de classes/selecteurs sont neutres.

## Comportement

- Le dylib se charge avec le jeu mais **n'installe rien** au démarrage.
- Le menu et le bouton flottant apparaissent **50 s** après le lancement.
- `INJECT` n'installe le patch de `Player.LateUpdate` qu'au moment où on
  l'active. En cas d'échec (TXM, page non inscriptible), l'interrupteur
  revient à OFF — pas de crash.
- La fenêtre overlay est **transparente aux touches** hors panneau :
  l'écran de démarrage du jeu (bouton *actualiser*) reste cliquable.

## Hook inline

`patch_shim.c` fournit le patch arm64 sans substrate :

1. vol des 4 premières instructions de la cible (16 octets)
2. trampoline : `[prologue volé][ldr x16,#8][br x16][cible+16]`
3. patch de la cible : `[ldr x16,#8][br x16][<replacement>]`
4. le trampoline est renvoyé à l'appelant, qui rejoue le prologue puis
   repart dans la fonction d'origine

L'écriture dans `__TEXT` passe par `vm_protect(VM_PROT_COPY)` : la page
est copiée en COW, modifiée, puis remise en `R-X`.

Prologue de `Player.LateUpdate` (RVA `0x9093E4`) :

```
e9 23 bd 6d   stp  d9, d8, [sp, #-48]!
f4 4f 01 a9   stp  x20, x19, [sp, #16]
fd 7b 02 a9   stp  x29, x30, [sp, #32]
fd 83 00 91   add  x29, sp, #32
```

## Injection

```
python tools/inject_ipa.py <source.ipa> out7/FFF_XZ.dylib <out.ipa>
```

Le script :

- localise `Payload/<X>.app/<X>`
- ajoute `LC_LOAD_DYLIB @rpath/FFF_XZ.dylib` dans le padding du header
  Mach-O (21 752 octets libres, aucun déplacement de données)
- copie le dylib dans `Payload/freefireth.app/Frameworks/`
- réécrit l'archive

La signature de l'app devient invalide : iLoader/zsign re-signe
l'ensemble après import.

## Installation

1. iLoader -> *Import any IPA* -> `FreeFire2018-v7.ipa`
2. connexion Apple ID, signature, installation
3. premier lancement : attendre ~50 s, le bouton `momoZbadou` apparaît
4. ouvrir le panneau, activer `INJECT` pour patcher `Player.LateUpdate`

Si l'app se ferme quand `INJECT` est activé, le RVA ne correspond plus à
`Player.LateUpdate` dans ce binaire. Le switch *Test Health* affiche les
valeurs lues aux offsets HP et permet de valider les offsets sans hook.

## Limite du client

`CFBundleShortVersionString = 1.28.0`, `CFBundleVersion = 2019031514`.
Le menu et l'ESP fonctionnent sur les données locales ; le backend de jeu
de cette version n'existe plus côté serveurs.
