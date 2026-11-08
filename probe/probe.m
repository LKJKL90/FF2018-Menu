// probe.m — dylib temoin. Ne fait rien d'autre que signer son chargement.
// Sert a distinguer "le chargement d'un dylib fait planter le jeu" de
// "le code du tweak fait planter le jeu".

#import <Foundation/Foundation.h>
#include <stdio.h>

__attribute__((constructor))
static void ff_probe_ctor(void) {
    fprintf(stderr, "[PROBE] FFProbe.dylib chargé\n");
    NSLog(@"[PROBE] FFProbe.dylib chargé");
}
