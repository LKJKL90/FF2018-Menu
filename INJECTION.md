# Injection dans l'IPA + sideload

## Pourquoi le tweak ne marchait pas tel quel

`FF2018Menu_LIBRARIES = substrate` linkait le dylib contre
`/usr/lib/libsubstrate.dylib`. Ce fichier n'existe que sur un appareil
jailbreaké. Dans un IPA sideloadé, `_MSHookFunction` reste non résolu et
dyld tue le process au premier appel — soit ~2 s après le lancement,
quand `InstallLateUpdateHook()` s'exécute.

`substrate_shim.c` fournit une implémentation arm64 autonome :

1. vol des 4 premières instructions de la cible (16 octets)
2. trampoline : `[prologue volé][ldr x16,#8][br x16][cible+16]`
3. patch de la cible : `[ldr x16,#8][br x16][<replacement>]`
4. le trampoline est renvoyé à l'appelant, qui rejoue le prologue puis
   repart dans la fonction d'origine

L'écriture dans `__TEXT` passe par `vm_protect(VM_PROT_COPY)` : la page
est copiée en COW, modifiée, puis remise en `R-X`. Aucune allocation
exécutable, donc aucun besoin de l'entitlement `dynamic-codesigning`.

Le prologue de `Player.LateUpdate` (RVA `0x9093E4`) est :

```
e9 23 bd 6d   stp  d9, d8, [sp, #-48]!
f4 4f 01 a9   stp  x20, x19, [sp, #16]
fd 7b 02 a9   stp  x29, x30, [sp, #32]
fd 83 00 91   add  x29, sp, #32
```

Aucune instruction PC-relative : la relocalisation dans le trampoline est
sûre. `0x9093E4` est aussi un *function start* exact dans la table
`LC_FUNCTION_STARTS` (237 124 entrées) du binaire de l'IPA.

## Injection

```
python tools/inject_ipa.py <source.ipa> <FF2018Menu.dylib> <out.ipa>
```

Ce que fait le script :

- localise `Payload/<X>.app/<X>` (X = CFBundleExecutable)
- ajoute `LC_LOAD_DYLIB @executable_path/FF2018Menu.dylib` dans le padding
  du header Mach-O (21 752 octets libres ici, aucun déplacement de données)
- copie le dylib dans `Payload/freefireth.app/`
- réécrit l'archive

La signature de l'app devient invalide : c'est normal. iLoader/zsign
re-signe l'ensemble après import.

## Résultat vérifié

```
source       FreeFire(IOS).ipa                  508 023 282 o
sortie       FreeFire2018-FFMenu.ipa            599 800 337 o
binaire      thin arm64, cryptid 0 (déchiffré)
ncmds        61 -> 62
sizeofcmds   6856 -> 6920
1re section  0x6fe0 (inchangée)
sha256       0b2395bf62fa332f6afc6035b2fd2f32b27553bbab94c668c28bb04a7ed0118a
```

## Installation

1. iLoader -> *Import any IPA* -> `FreeFire2018-FFMenu.ipa`
2. connexion Apple ID, signature, installation
3. premier lancement : vérifier dans les logs `[FF2018] dylib chargé` puis
   `[FF2018] Hook installé`

Si l'app se ferme au bout de 2 s, le hook a échoué : le `RVA` ne correspond
plus à `Player.LateUpdate` dans ce binaire. Le switch *Test Health* du menu
affiche les valeurs lues aux offsets HP et permet de valider les offsets
sans passer par le hook.

## Limite du client

`CFBundleShortVersionString = 1.28.0`, `CFBundleVersion = 2019031514`.
Le menu et l'ESP fonctionnent sur les données locales ; le backend de jeu
de cette version n'existe plus côté serveurs.
