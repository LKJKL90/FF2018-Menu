#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>
#import <substrate.h>

// ============================================================
// OFFSETS VÉRIFIÉS (dump.cs Free Fire 2018)
// ============================================================
#define OFF_GAME_ENGINE_INSTANCE     0x0
#define OFF_M_CURRENT_GAME           0x18
#define OFF_S_ALL_ENTITIES           0x8
#define OFF_ENTITY_CACHED_TRANSFORM  0x20
#define OFF_PLAYER_IS_CLIENT_BOT     0xA0
#define OFF_PLAYER_TEAM_MAP_MARK     0xCC
#define OFF_CAMERA_MGR_INSTANCE      0x0
#define OFF_CAMERA_ACTIVE            0x18

#define RVA_PLAYER_LATEUPDATE        0x9093E4

static int g_healthOffsets[] = {0x498, 0x49C, 0x4D4, 0x4D8, 0x4DC, 0x538, 0x540, 0x544, 0x588};
#define HEALTH_COUNT 9

// ============================================================
// ÉTAT GLOBAL
// ============================================================
static uintptr_t g_il2cppBase = 0;
static BOOL g_menuVisible = NO;
static BOOL g_espEnabled = NO;
static BOOL g_aimbotEnabled = NO;
static BOOL g_flyEnabled = NO;
static BOOL g_testMode = NO;

static UIWindow *g_menuWindow = nil;
static UIViewController *g_menuVC = nil;

#define MAX_PLAYERS 64
static uintptr_t g_players[MAX_PLAYERS];
static int g_playerCount = 0;

// ============================================================
// MÉMOIRE (API vm_* compatible SDK iOS 26)
// ============================================================
static uintptr_t ReadPtr(uintptr_t addr) {
    if (!addr) return 0;
    uintptr_t val = 0; vm_size_t r = 0;
    vm_read_overwrite(mach_task_self(), addr, sizeof(uintptr_t), (vm_address_t)&val, &r);
    return val;
}
static float ReadFloat(uintptr_t addr) {
    if (!addr) return 0.f;
    float val = 0.f; vm_size_t r = 0;
    vm_read_overwrite(mach_task_self(), addr, sizeof(float), (vm_address_t)&val, &r);
    return val;
}
static int ReadInt(uintptr_t addr) {
    if (!addr) return 0;
    int val = 0; vm_size_t r = 0;
    vm_read_overwrite(mach_task_self(), addr, sizeof(int), (vm_address_t)&val, &r);
    return val;
}
static BOOL ReadBool(uintptr_t addr) {
    if (!addr) return NO;
    uint8_t val = 0; vm_size_t r = 0;
    vm_read_overwrite(mach_task_self(), addr, sizeof(uint8_t), (vm_address_t)&val, &r);
    return val != 0;
}
static void WriteFloat(uintptr_t addr, float val) {
    if (!addr) return;
    vm_write(mach_task_self(), addr, (vm_address_t)&val, sizeof(float));
}

// ============================================================
// BASE IL2CPP
// ============================================================
static uintptr_t GetIl2CppBase() {
    if (g_il2cppBase) return g_il2cppBase;
    // Le code il2cpp est linké dans l'exécutable principal. dladdr() sur une
    // fonction de ce fichier renverrait la base de notre propre dylib, donc on
    // prend directement l'image 0 (le binaire du jeu).
    const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (hdr) g_il2cppBase = (uintptr_t)hdr;
    return g_il2cppBase;
}

static uintptr_t GetBaseGame() {
    uintptr_t base = GetIl2CppBase();
    uintptr_t engine = ReadPtr(base + OFF_GAME_ENGINE_INSTANCE);
    if (!engine) return 0;
    return ReadPtr(engine + OFF_M_CURRENT_GAME);
}

static void CachePlayer(uintptr_t player) {
    if (!player) return;
    for (int i = 0; i < g_playerCount; i++) if (g_players[i] == player) return;
    if (g_playerCount < MAX_PLAYERS) g_players[g_playerCount++] = player;
}

// ============================================================
// ESP OVERLAY
// ============================================================
@interface ESPOverlayView : UIView @end
@implementation ESPOverlayView
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    if (g_testMode) {
        CGFloat y = 80;
        for (int i = 0; i < g_playerCount; i++) {
            uintptr_t p = g_players[i];
            if (ReadBool(p + OFF_PLAYER_IS_CLIENT_BOT)) continue;
            for (int j = 0; j < HEALTH_COUNT; j++) {
                float h = ReadFloat(p + g_healthOffsets[j]);
                NSString *txt = [NSString stringWithFormat:@"+0x%X: %.2f", g_healthOffsets[j], h];
                [txt drawAtPoint:CGPointMake(10, y) withAttributes:@{
                    NSFontAttributeName: [UIFont systemFontOfSize:12],
                    NSForegroundColorAttributeName: [UIColor yellowColor]
                }];
                y += 16;
            }
            break;
        }
        return;
    }

    if (!g_espEnabled) return;

    CGRect screen = [[UIScreen mainScreen] bounds];
    for (int i = 0; i < g_playerCount; i++) {
        uintptr_t p = g_players[i];
        if (ReadBool(p + OFF_PLAYER_IS_CLIENT_BOT)) continue;
        float mx = ReadFloat(p + OFF_PLAYER_TEAM_MAP_MARK);
        float my = ReadFloat(p + OFF_PLAYER_TEAM_MAP_MARK + 4);
        CGPoint s = CGPointMake(screen.size.width/2 + mx*10, screen.size.height/2 - my*10);
        CGRect box = CGRectMake(s.x - 20, s.y - 40, 40, 80);
        CGContextSetStrokeColorWithColor(ctx, [UIColor redColor].CGColor);
        CGContextStrokeRect(ctx, box);
    }
}
@end

// ============================================================
// MENU FLOTTANT
// ============================================================
@interface MenuViewController : UIViewController @end
@implementation MenuViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
    self.view.layer.cornerRadius = 12;
    self.view.layer.masksToBounds = YES;
    self.view.frame = CGRectMake(20, 120, 240, 300);

    CGFloat y = 10;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, y, 220, 24)];
    title.text = @"FF 2018 Menu"; title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.view addSubview:title]; y += 34;

    UISwitch *esp = [[UISwitch alloc] initWithFrame:CGRectMake(10, y, 50, 30)];
    esp.on = g_espEnabled; [esp addTarget:self action:@selector(toggleESP:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:esp];
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(70, y, 150, 30)]; l1.text = @"ESP"; l1.textColor = [UIColor whiteColor];
    [self.view addSubview:l1]; y += 40;

    UISwitch *aim = [[UISwitch alloc] initWithFrame:CGRectMake(10, y, 50, 30)];
    aim.on = g_aimbotEnabled; [aim addTarget:self action:@selector(toggleAimbot:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:aim];
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(70, y, 150, 30)]; l2.text = @"Aimbot"; l2.textColor = [UIColor whiteColor];
    [self.view addSubview:l2]; y += 40;

    UISwitch *fly = [[UISwitch alloc] initWithFrame:CGRectMake(10, y, 50, 30)];
    fly.on = g_flyEnabled; [fly addTarget:self action:@selector(toggleFly:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:fly];
    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(70, y, 150, 30)]; l3.text = @"Fly"; l3.textColor = [UIColor whiteColor];
    [self.view addSubview:l3]; y += 40;

    UISwitch *test = [[UISwitch alloc] initWithFrame:CGRectMake(10, y, 50, 30)];
    test.on = g_testMode; [test addTarget:self action:@selector(toggleTest:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:test];
    UILabel *l4 = [[UILabel alloc] initWithFrame:CGRectMake(70, y, 150, 30)]; l4.text = @"Test Health"; l4.textColor = [UIColor whiteColor];
    [self.view addSubview:l4]; y += 50;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(10, y, 220, 34);
    [close setTitle:@"Fermer" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeMenu:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
}
- (void)toggleESP:(UISwitch*)s { g_espEnabled = s.isOn; }
- (void)toggleAimbot:(UISwitch*)s { g_aimbotEnabled = s.isOn; }
- (void)toggleFly:(UISwitch*)s { g_flyEnabled = s.isOn; }
- (void)toggleTest:(UISwitch*)s { g_testMode = s.isOn; }
- (void)closeMenu:(UIButton*)b { [MenuViewController hide]; }
+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_menuVisible) return;
        if (!g_menuVC) g_menuVC = [[MenuViewController alloc] init];
        if (!g_menuWindow) {
            g_menuWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            g_menuWindow.windowLevel = UIWindowLevelAlert + 100;
            g_menuWindow.backgroundColor = [UIColor clearColor];
            g_menuWindow.rootViewController = g_menuVC;
        }
        [g_menuWindow makeKeyAndVisible];
        g_menuVisible = YES;
    });
}
+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{ [g_menuWindow setHidden:YES]; g_menuVisible = NO; });
}
@end

// ============================================================
// BOUTON FLOTTANT
// ============================================================
@interface FloatingButton : UIButton @end
@implementation FloatingButton
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];
}
- (void)handlePan:(UIPanGestureRecognizer*)g {
    CGPoint p = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + p.x, self.center.y + p.y);
    [g setTranslation:CGPointZero inView:self.superview];
}
@end

static FloatingButton *g_fab = nil;
static void ShowFab() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_fab) return;
        g_fab = [FloatingButton buttonWithType:UIButtonTypeCustom];
        g_fab.frame = CGRectMake(20, 200, 50, 50);
        [g_fab setTitle:@"FF" forState:UIControlStateNormal];
        [g_fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_fab.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.9];
        g_fab.layer.cornerRadius = 25;
        [g_fab addTarget:[MenuViewController class] action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
        [[UIApplication sharedApplication].keyWindow addSubview:g_fab];
    });
}

// ============================================================
// HOOK PLAYER.LATEUPDATE
// ============================================================
static void (*orig_PlayerLateUpdate)(void *self);
static void hooked_PlayerLateUpdate(void *self) {
    if (orig_PlayerLateUpdate) orig_PlayerLateUpdate(self);
    CachePlayer((uintptr_t)self);
}
static void InstallLateUpdateHook() {
    uintptr_t base = GetIl2CppBase();
    if (!base) { NSLog(@"[FF2018] base IL2CPP introuvable"); return; }
    uintptr_t target = base + RVA_PLAYER_LATEUPDATE;
    NSLog(@"[FF2018] Hook LateUpdate @ 0x%llx", (unsigned long long)target);
    MSHookFunction((void*)target, (void*)hooked_PlayerLateUpdate, (void**)&orig_PlayerLateUpdate);
    NSLog(@"[FF2018] Hook installé");
}

// ============================================================
// INIT
// ============================================================
__attribute__((constructor))
static void initMenu() {
    NSLog(@"[FF2018] dylib chargé. Base IL2CPP: 0x%llx", (unsigned long long)GetIl2CppBase());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        InstallLateUpdateHook();
        ShowFab();
        [MenuViewController show];
    });
}
