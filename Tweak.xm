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
static BOOL g_hookInstalled = NO;

static UIWindow *g_menuWindow = nil;
static UIViewController *g_hostVC = nil;
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
@interface MenuHostViewController : UIViewController @end
@implementation MenuHostViewController
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end

// Palette du menu terminal (reprise du preview XZPROJECT / momoZbadou)
#define FF_GREEN  [UIColor colorWithRed:0.00 green:1.00 blue:0.40 alpha:1.0]
#define FF_BAR    [UIColor colorWithWhite:0.031 alpha:1.0]
#define FF_PANEL  [UIColor colorWithWhite:0.039 alpha:1.0]
#define FF_LINE   [UIColor colorWithWhite:0.120 alpha:1.0]
#define FF_TEXT   [UIColor colorWithWhite:0.900 alpha:1.0]
#define FF_MUTED  [UIColor colorWithWhite:0.540 alpha:1.0]
#define FF_PANEL_W 300.0

static UIFont *FFMono(CGFloat size, UIFontWeight weight) {
    return [UIFont monospacedSystemFontOfSize:size weight:weight];
}

// Interrupteur carre, 32x16, pouce 10x10 qui glisse de 17 px.
@interface FFSwitch : UIControl
@property (nonatomic, assign) BOOL on;
@end

@implementation FFSwitch {
    UIView *_thumb;
}
- (instancetype)init {
    self = [super initWithFrame:CGRectMake(0, 0, 32, 16)];
    if (!self) return nil;
    self.layer.borderWidth = 1.0;
    self.layer.cornerRadius = 2.0;
    _thumb = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 10, 10)];
    _thumb.layer.cornerRadius = 1.0;
    [self addSubview:_thumb];
    [self addTarget:self action:@selector(ff_tap) forControlEvents:UIControlEventTouchUpInside];
    [self ff_refresh];
    return self;
}
- (void)ff_tap {
    self.on = !self.on;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)setOn:(BOOL)on {
    _on = on;
    [self ff_refresh];
}
- (void)ff_refresh {
    if (_on) {
        self.backgroundColor = [FF_GREEN colorWithAlphaComponent:0.15];
        self.layer.borderColor = FF_GREEN.CGColor;
        _thumb.backgroundColor = FF_GREEN;
        _thumb.layer.shadowColor = FF_GREEN.CGColor;
        _thumb.layer.shadowOpacity = 1.0;
        _thumb.layer.shadowRadius = 3.0;
        _thumb.layer.shadowOffset = CGSizeZero;
        _thumb.frame = CGRectMake(19, 2, 10, 10);
    } else {
        self.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
        self.layer.borderColor = FF_LINE.CGColor;
        _thumb.backgroundColor = [UIColor colorWithWhite:0.33 alpha:1.0];
        _thumb.layer.shadowOpacity = 0.0;
        _thumb.frame = CGRectMake(2, 2, 10, 10);
    }
}
@end

@interface MenuViewController : UIViewController @end
@implementation MenuViewController {
    UIScrollView *_scroll;
    UILabel *_stBase;
    UILabel *_stHook;
    UILabel *_stPlayers;
    UILabel *_stEsp;
    CGFloat  _contentY;
}

- (UILabel *)ff_label:(NSString *)text frame:(CGRect)f color:(UIColor *)c
                 size:(CGFloat)s weight:(UIFontWeight)w {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = text;
    l.textColor = c;
    l.font = FFMono(s, w);
    l.backgroundColor = [UIColor clearColor];
    return l;
}

- (void)ff_section:(NSString *)title {
    UIView *sec = [[UIView alloc] initWithFrame:CGRectMake(0, _contentY, FF_PANEL_W, 26)];
    UIView *top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, FF_PANEL_W, 0.5)];
    top.backgroundColor = FF_LINE;
    [sec addSubview:top];

    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:title];
    [as addAttribute:NSKernAttributeName value:@1.6
               range:NSMakeRange(0, title.length)];
    UILabel *l = [self ff_label:nil frame:CGRectMake(12, 7, FF_PANEL_W - 24, 16)
                          color:FF_GREEN size:10 weight:UIFontWeightBold];
    l.attributedText = as;
    [sec addSubview:l];

    [_scroll addSubview:sec];
    _contentY += 26.0;
}

- (FFSwitch *)ff_row:(NSString *)title action:(SEL)action on:(BOOL)on {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, _contentY, FF_PANEL_W, 30)];
    UILabel *l = [self ff_label:title frame:CGRectMake(12, 0, FF_PANEL_W - 60, 30)
                          color:FF_TEXT size:11 weight:UIFontWeightRegular];
    [row addSubview:l];

    FFSwitch *sw = [[FFSwitch alloc] init];
    sw.frame = CGRectMake(FF_PANEL_W - 44, 7, 32, 16);
    sw.on = on;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 29.5, FF_PANEL_W, 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    [row addSubview:line];

    [_scroll addSubview:row];
    _contentY += 30.0;
    return sw;
}

- (UILabel *)ff_status:(NSString *)key value:(NSString *)value dotOn:(BOOL)dotOn {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, _contentY, FF_PANEL_W, 22)];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(12, 8, 6, 6)];
    dot.backgroundColor = dotOn ? FF_GREEN : [UIColor colorWithWhite:0.20 alpha:1.0];
    dot.layer.cornerRadius = 3.0;
    if (dotOn) {
        dot.layer.shadowColor = FF_GREEN.CGColor;
        dot.layer.shadowOpacity = 1.0;
        dot.layer.shadowRadius = 3.0;
        dot.layer.shadowOffset = CGSizeZero;
    }
    [row addSubview:dot];

    UILabel *k = [self ff_label:key frame:CGRectMake(26, 0, 86, 22)
                          color:FF_MUTED size:9 weight:UIFontWeightRegular];
    [row addSubview:k];

    UILabel *v = [self ff_label:value frame:CGRectMake(112, 0, FF_PANEL_W - 124, 22)
                          color:FF_TEXT size:9 weight:UIFontWeightRegular];
    v.textAlignment = NSTextAlignmentRight;
    [row addSubview:v];

    [_scroll addSubview:row];
    _contentY += 22.0;
    return v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = FF_PANEL;
    self.view.layer.borderWidth = 1.0;
    self.view.layer.borderColor = FF_GREEN.CGColor;
    self.view.layer.cornerRadius = 2.0;

    // ---- barre de titre ----
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, FF_PANEL_W, 36)];
    bar.backgroundColor = FF_BAR;
    UIView *barLine = [[UIView alloc] initWithFrame:CGRectMake(0, 35.5, FF_PANEL_W, 0.5)];
    barLine.backgroundColor = FF_LINE;
    [bar addSubview:barLine];

    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:@"XZPROJECT"];
    [t addAttribute:NSKernAttributeName value:@2.0 range:NSMakeRange(0, 9)];
    UILabel *title = [self ff_label:nil frame:CGRectMake(12, 0, 130, 36)
                             color:FF_GREEN size:13 weight:UIFontWeightBold];
    title.attributedText = t;
    [bar addSubview:title];

    UILabel *ver = [self ff_label:@"v1.0.0" frame:CGRectMake(118, 0, 44, 36)
                           color:FF_MUTED size:9 weight:UIFontWeightRegular];
    [bar addSubview:ver];

    UIView *adot = [[UIView alloc] initWithFrame:CGRectMake(FF_PANEL_W - 96, 15, 7, 7)];
    adot.backgroundColor = FF_GREEN;
    adot.layer.cornerRadius = 3.5;
    adot.layer.shadowColor = FF_GREEN.CGColor;
    adot.layer.shadowOpacity = 1.0;
    adot.layer.shadowRadius = 3.0;
    adot.layer.shadowOffset = CGSizeZero;
    CABasicAnimation *blink = [CABasicAnimation animationWithKeyPath:@"opacity"];
    blink.fromValue = @1.0;
    blink.toValue = @0.25;
    blink.duration = 0.7;
    blink.autoreverses = YES;
    blink.repeatCount = 1e9f;
    [adot.layer addAnimation:blink forKey:@"blink"];
    [bar addSubview:adot];

    UILabel *active = [self ff_label:@"ACTIVE" frame:CGRectMake(FF_PANEL_W - 85, 0, 46, 36)
                              color:FF_GREEN size:9 weight:UIFontWeightBold];
    [bar addSubview:active];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(FF_PANEL_W - 36, 7, 22, 22);
    close.layer.borderWidth = 1.0;
    close.layer.borderColor = FF_LINE.CGColor;
    [close setTitle:@"x" forState:UIControlStateNormal];
    [close setTitleColor:FF_MUTED forState:UIControlStateNormal];
    close.titleLabel.font = FFMono(13, UIFontWeightRegular);
    [close addTarget:self action:@selector(closeMenu:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                    action:@selector(ff_drag:)]];
    [self.view addSubview:bar];

    // ---- contenu defilant ----
    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 36, FF_PANEL_W, 1)];
    _scroll.backgroundColor = [UIColor clearColor];
    _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _contentY = 0;
    [self ff_section:@"VISUALS"];
    [self ff_row:@"ESP" action:@selector(toggleESP:) on:g_espEnabled];
    [self ff_row:@"Test Health" action:@selector(toggleTest:) on:g_testMode];

    [self ff_section:@"COMBAT"];
    [self ff_row:@"Aimbot" action:@selector(toggleAimbot:) on:g_aimbotEnabled];

    [self ff_section:@"MOVEMENT"];
    [self ff_row:@"Fly" action:@selector(toggleFly:) on:g_flyEnabled];

    [self ff_section:@"STATUS"];
    _stBase    = [self ff_status:@"BASE"    value:@"0x0" dotOn:YES];
    _stHook    = [self ff_status:@"HOOK"    value:@"OFF" dotOn:NO];
    _stPlayers = [self ff_status:@"PLAYERS" value:@"0"   dotOn:NO];
    _stEsp     = [self ff_status:@"ESP"     value:@"OFF" dotOn:NO];

    UIView *foot = [[UIView alloc] initWithFrame:CGRectMake(0, _contentY, FF_PANEL_W, 22)];
    UIView *footLine = [[UIView alloc] initWithFrame:CGRectMake(0, 0, FF_PANEL_W, 0.5)];
    footLine.backgroundColor = FF_LINE;
    [foot addSubview:footLine];
    [foot addSubview:[self ff_label:@"XZPROJECT // ff2018" frame:CGRectMake(12, 0, 180, 22)
                            color:FF_MUTED size:9 weight:UIFontWeightRegular]];
    UILabel *fr = [self ff_label:@"iloader" frame:CGRectMake(FF_PANEL_W - 72, 0, 60, 22)
                          color:FF_MUTED size:9 weight:UIFontWeightRegular];
    fr.textAlignment = NSTextAlignmentRight;
    [foot addSubview:fr];
    [_scroll addSubview:foot];
    _contentY += 22.0;

    _scroll.contentSize = CGSizeMake(FF_PANEL_W, _contentY);

    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                   selector:@selector(ff_tick) userInfo:nil repeats:YES];
    [self ff_tick];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _scroll.frame = CGRectMake(0, 36, b.size.width, b.size.height - 36);
}

- (void)ff_drag:(UIPanGestureRecognizer *)g {
    CGPoint p = [g translationInView:self.view.superview];
    self.view.center = CGPointMake(self.view.center.x + p.x, self.view.center.y + p.y);
    [g setTranslation:CGPointZero inView:self.view.superview];
}

- (void)ff_tick {
    _stBase.text = [NSString stringWithFormat:@"0x%llx",
                    (unsigned long long)GetIl2CppBase()];
    _stHook.text = g_hookInstalled ? @"READY" : @"OFF";
    _stHook.textColor = g_hookInstalled ? FF_GREEN : FF_MUTED;
    _stPlayers.text = [NSString stringWithFormat:@"%d", g_playerCount];
    _stEsp.text = g_espEnabled ? @"ON" : @"OFF";
    _stEsp.textColor = g_espEnabled ? FF_GREEN : FF_MUTED;
}

- (void)toggleESP:(FFSwitch*)s { g_espEnabled = s.on; }
- (void)toggleAimbot:(FFSwitch*)s { g_aimbotEnabled = s.on; }
- (void)toggleFly:(FFSwitch*)s { g_flyEnabled = s.on; }
- (void)toggleTest:(FFSwitch*)s { g_testMode = s.on; }
- (void)closeMenu:(UIButton*)b { [MenuViewController hide]; }
+ (UIWindow *)menuWindow {
    if (g_menuWindow) return g_menuWindow;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            (s.activationState == UISceneActivationStateForegroundActive ||
             s.activationState == UISceneActivationStateForegroundInactive)) {
            scene = (UIWindowScene *)s;
            break;
        }
    }

    if (scene) {
        g_menuWindow = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        g_menuWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    g_menuWindow.windowLevel = UIWindowLevelAlert + 100;
    g_menuWindow.backgroundColor = [UIColor clearColor];

    g_hostVC = [[MenuHostViewController alloc] init];
    g_hostVC.view.backgroundColor = [UIColor clearColor];
    g_menuWindow.rootViewController = g_hostVC;
    g_menuWindow.hidden = NO;
    return g_menuWindow;
}

+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [MenuViewController menuWindow];
        if (!g_menuVC) g_menuVC = [[MenuViewController alloc] init];
        if (!g_menuVC.view.superview) [g_hostVC.view addSubview:g_menuVC.view];

        // Le panneau est une sous-vue, pas la vue racine : sinon UIKit la
        // redimensionne aux bornes de la fenetre et le menu couvre tout l'ecran.
        CGRect b = w.bounds;
        CGFloat h = b.size.height - 24;
        if (h > 470) h = 470;
        if (h < 240) h = 240;
        g_menuVC.view.frame = CGRectMake(40, 12, FF_PANEL_W, h);
        g_menuVC.view.hidden = NO;
        g_menuVisible = YES;
    });
}
+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{ g_menuVC.view.hidden = YES; g_menuVisible = NO; });
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
        UIWindow *w = [MenuViewController menuWindow];
        CGRect b = w.bounds;

        g_fab = [FloatingButton buttonWithType:UIButtonTypeCustom];
        g_fab.frame = CGRectMake(b.size.width - 140, b.size.height - 52, 116, 28);
        [g_fab setTitle:@"momoZbadou" forState:UIControlStateNormal];
        [g_fab setTitleColor:FF_GREEN forState:UIControlStateNormal];
        g_fab.titleLabel.font = FFMono(10, UIFontWeightBold);
        g_fab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
        g_fab.layer.borderWidth = 1.0;
        g_fab.layer.borderColor = FF_GREEN.CGColor;
        g_fab.layer.cornerRadius = 2.0;
        [g_fab addTarget:[MenuViewController class] action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:g_fab];
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
    g_hookInstalled = (orig_PlayerLateUpdate != NULL);
    NSLog(@"[FF2018] Hook installé (orig=%p)", (void *)orig_PlayerLateUpdate);
}

// ============================================================
// INIT
// ============================================================
__attribute__((constructor))
static void initMenu() {
    NSLog(@"[FF2018] dylib chargé. Base IL2CPP: 0x%llx", (unsigned long long)GetIl2CppBase());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Variantes de diagnostic : -DFF_NO_HOOK / -DFF_NO_UI. Sans ces defines
        // le comportement est identique à l'original.
#ifndef FF_NO_HOOK
        InstallLateUpdateHook();
#endif
#ifndef FF_NO_UI
        ShowFab();
        [MenuViewController show];
#endif
    });
}
