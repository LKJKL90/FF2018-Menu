#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>

#import "xz_strings.h"

// ============================================================
// OFFSETS (dump Free Fire 2018)
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
// ÉTAT
// ============================================================
static uintptr_t g_il2cppBase = 0;
static BOOL g_menuVisible = NO;
static BOOL g_espEnabled = NO;
static BOOL g_aimbotEnabled = NO;
static BOOL g_flyEnabled = NO;
static BOOL g_testMode = NO;
static BOOL g_hookInstalled = NO;
static BOOL g_injected = NO;

static void InstallLateUpdateHook(void);

static UIWindow *g_menuWindow = nil;
static UIViewController *g_hostVC = nil;
static UIViewController *g_menuVC = nil;

#define MAX_PLAYERS 64
static uintptr_t g_players[MAX_PLAYERS];
static int g_playerCount = 0;

// ============================================================
// MÉMOIRE
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
// BASE
// ============================================================
static uintptr_t GetIl2CppBase() {
    if (g_il2cppBase) return g_il2cppBase;
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
// OVERLAY
// ============================================================
@interface CanvasLayer : UIView @end
@implementation CanvasLayer
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

    CGSize screen = self.bounds.size;
    for (int i = 0; i < g_playerCount; i++) {
        uintptr_t p = g_players[i];
        if (ReadBool(p + OFF_PLAYER_IS_CLIENT_BOT)) continue;
        float mx = ReadFloat(p + OFF_PLAYER_TEAM_MAP_MARK);
        float my = ReadFloat(p + OFF_PLAYER_TEAM_MAP_MARK + 4);
        CGPoint s = CGPointMake(screen.width/2 + mx*10, screen.height/2 - my*10);
        CGRect box = CGRectMake(s.x - 20, s.y - 40, 40, 80);
        CGContextSetStrokeColorWithColor(ctx, [UIColor redColor].CGColor);
        CGContextStrokeRect(ctx, box);
    }
}
@end

// ============================================================
// HOST
// ============================================================
// Vue racine transparente : seule la zone du panneau capte les touches.
// Sans ça la fenêtre overlay avale tous les taps du jeu (bouton
// "actualiser" de l'écran de démarrage, etc.).
@interface HostView : UIView @end
@implementation HostView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

@interface PanelHost : UIViewController @end
@implementation PanelHost
- (void)loadView {
    HostView *v = [[HostView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end

#define XZ_GREEN  [UIColor colorWithRed:0.00 green:1.00 blue:0.40 alpha:1.0]
#define XZ_BAR    [UIColor colorWithWhite:0.031 alpha:1.0]
#define XZ_PANEL  [UIColor colorWithWhite:0.039 alpha:1.0]
#define XZ_LINE   [UIColor colorWithWhite:0.120 alpha:1.0]
#define XZ_TEXT   [UIColor colorWithWhite:0.900 alpha:1.0]
#define XZ_MUTED  [UIColor colorWithWhite:0.540 alpha:1.0]
#define XZ_PANEL_W 300.0

static UIFont *XZMono(CGFloat size, UIFontWeight weight) {
    return [UIFont monospacedSystemFontOfSize:size weight:weight];
}

// ============================================================
// TOGGLE
// ============================================================
@interface MiniToggle : UIControl
@property (nonatomic, assign) BOOL on;
@end

@implementation MiniToggle {
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
    [self addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [self refresh];
    return self;
}
- (void)tap {
    self.on = !self.on;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)setOn:(BOOL)on {
    _on = on;
    [self refresh];
}
- (void)refresh {
    if (_on) {
        self.backgroundColor = [XZ_GREEN colorWithAlphaComponent:0.15];
        self.layer.borderColor = XZ_GREEN.CGColor;
        _thumb.backgroundColor = XZ_GREEN;
        _thumb.layer.shadowColor = XZ_GREEN.CGColor;
        _thumb.layer.shadowOpacity = 1.0;
        _thumb.layer.shadowRadius = 3.0;
        _thumb.layer.shadowOffset = CGSizeZero;
        _thumb.frame = CGRectMake(19, 2, 10, 10);
    } else {
        self.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
        self.layer.borderColor = XZ_LINE.CGColor;
        _thumb.backgroundColor = [UIColor colorWithWhite:0.33 alpha:1.0];
        _thumb.layer.shadowOpacity = 0.0;
        _thumb.frame = CGRectMake(2, 2, 10, 10);
    }
}
@end

// ============================================================
// PANEL
// ============================================================
@interface PanelController : UIViewController @end
@implementation PanelController {
    UIScrollView *_scroll;
    UILabel *_stBase;
    UILabel *_stHook;
    UILabel *_stPlayers;
    UILabel *_stEsp;
    UILabel *_stInj;
    MiniToggle *_injSwitch;
    CGFloat  _contentY;
}

- (UILabel *)lbl:(NSString *)text frame:(CGRect)f color:(UIColor *)c
           size:(CGFloat)s weight:(UIFontWeight)w {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = text;
    l.textColor = c;
    l.font = XZMono(s, w);
    l.backgroundColor = [UIColor clearColor];
    return l;
}

- (void)sec:(NSString *)title {
    UIView *sec = [[UIView alloc] initWithFrame:CGRectMake(0, _contentY, XZ_PANEL_W, 26)];
    UIView *top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, XZ_PANEL_W, 0.5)];
    top.backgroundColor = XZ_LINE;
    [sec addSubview:top];

    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:title];
    [as addAttribute:NSKernAttributeName value:@1.6
               range:NSMakeRange(0, title.length)];
    UILabel *l = [self lbl:nil frame:CGRectMake(12, 7, XZ_PANEL_W - 24, 16)
                     color:XZ_GREEN size:10 weight:UIFontWeightBold];
    l.attributedText = as;
    [sec addSubview:l];

    [_scroll addSubview:sec];
    _contentY += 26.0;
}

- (MiniToggle *)row:(NSString *)title action:(SEL)action on:(BOOL)on {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, _contentY, XZ_PANEL_W, 30)];
    UILabel *l = [self lbl:title frame:CGRectMake(12, 0, XZ_PANEL_W - 60, 30)
                     color:XZ_TEXT size:11 weight:UIFontWeightRegular];
    [row addSubview:l];

    MiniToggle *sw = [[MiniToggle alloc] init];
    sw.frame = CGRectMake(XZ_PANEL_W - 44, 7, 32, 16);
    sw.on = on;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 29.5, XZ_PANEL_W, 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    [row addSubview:line];

    [_scroll addSubview:row];
    _contentY += 30.0;
    return sw;
}

- (UILabel *)stat:(NSString *)key value:(NSString *)value dotOn:(BOOL)dotOn {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, _contentY, XZ_PANEL_W, 22)];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(12, 8, 6, 6)];
    dot.backgroundColor = dotOn ? XZ_GREEN : [UIColor colorWithWhite:0.20 alpha:1.0];
    dot.layer.cornerRadius = 3.0;
    if (dotOn) {
        dot.layer.shadowColor = XZ_GREEN.CGColor;
        dot.layer.shadowOpacity = 1.0;
        dot.layer.shadowRadius = 3.0;
        dot.layer.shadowOffset = CGSizeZero;
    }
    [row addSubview:dot];

    UILabel *k = [self lbl:key frame:CGRectMake(26, 0, 86, 22)
                     color:XZ_MUTED size:9 weight:UIFontWeightRegular];
    [row addSubview:k];

    UILabel *v = [self lbl:value frame:CGRectMake(112, 0, XZ_PANEL_W - 124, 22)
                     color:XZ_TEXT size:9 weight:UIFontWeightRegular];
    v.textAlignment = NSTextAlignmentRight;
    [row addSubview:v];

    [_scroll addSubview:row];
    _contentY += 22.0;
    return v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = XZ_PANEL;
    self.view.layer.borderWidth = 1.0;
    self.view.layer.borderColor = XZ_GREEN.CGColor;
    self.view.layer.cornerRadius = 2.0;

    // ---- barre de titre ----
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, XZ_PANEL_W, 36)];
    bar.backgroundColor = XZ_BAR;
    UIView *barLine = [[UIView alloc] initWithFrame:CGRectMake(0, 35.5, XZ_PANEL_W, 0.5)];
    barLine.backgroundColor = XZ_LINE;
    [bar addSubview:barLine];

    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:XZS(0)];
    [t addAttribute:NSKernAttributeName value:@2.0 range:NSMakeRange(0, 9)];
    UILabel *title = [self lbl:nil frame:CGRectMake(12, 0, 130, 36)
                         color:XZ_GREEN size:13 weight:UIFontWeightBold];
    title.attributedText = t;
    [bar addSubview:title];

    UILabel *ver = [self lbl:XZS(1) frame:CGRectMake(118, 0, 44, 36)
                       color:XZ_MUTED size:9 weight:UIFontWeightRegular];
    [bar addSubview:ver];

    UIView *adot = [[UIView alloc] initWithFrame:CGRectMake(XZ_PANEL_W - 96, 15, 7, 7)];
    adot.backgroundColor = XZ_GREEN;
    adot.layer.cornerRadius = 3.5;
    adot.layer.shadowColor = XZ_GREEN.CGColor;
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

    UILabel *active = [self lbl:XZS(2) frame:CGRectMake(XZ_PANEL_W - 85, 0, 46, 36)
                          color:XZ_GREEN size:9 weight:UIFontWeightBold];
    [bar addSubview:active];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(XZ_PANEL_W - 36, 7, 22, 22);
    close.layer.borderWidth = 1.0;
    close.layer.borderColor = XZ_LINE.CGColor;
    [close setTitle:XZS(22) forState:UIControlStateNormal];
    [close setTitleColor:XZ_MUTED forState:UIControlStateNormal];
    close.titleLabel.font = XZMono(13, UIFontWeightRegular);
    [close addTarget:self action:@selector(cx:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                     action:@selector(drag:)]];
    [self.view addSubview:bar];

    // ---- contenu ----
    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 36, XZ_PANEL_W, 1)];
    _scroll.backgroundColor = [UIColor clearColor];
    _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _contentY = 0;
    [self sec:XZS(3)];
    _injSwitch = [self row:XZS(4) action:@selector(sw0:) on:g_injected];

    [self sec:XZS(5)];
    [self row:XZS(6) action:@selector(sw1:) on:g_espEnabled];
    [self row:XZS(7) action:@selector(sw2:) on:g_testMode];

    [self sec:XZS(8)];
    [self row:XZS(9) action:@selector(sw3:) on:g_aimbotEnabled];

    [self sec:XZS(10)];
    [self row:XZS(11) action:@selector(sw4:) on:g_flyEnabled];

    [self sec:XZS(12)];
    _stBase    = [self stat:XZS(13) value:@"0x0" dotOn:YES];
    _stHook    = [self stat:XZS(14) value:XZS(17) dotOn:NO];
    _stPlayers = [self stat:XZS(15) value:@"0"   dotOn:NO];
    _stEsp     = [self stat:XZS(6)  value:XZS(17) dotOn:NO];
    _stInj     = [self stat:XZS(4)  value:XZS(17) dotOn:NO];

    UIView *foot = [[UIView alloc] initWithFrame:CGRectMake(0, _contentY, XZ_PANEL_W, 22)];
    UIView *footLine = [[UIView alloc] initWithFrame:CGRectMake(0, 0, XZ_PANEL_W, 0.5)];
    footLine.backgroundColor = XZ_LINE;
    [foot addSubview:footLine];
    [foot addSubview:[self lbl:XZS(19) frame:CGRectMake(12, 0, 180, 22)
                          color:XZ_MUTED size:9 weight:UIFontWeightRegular]];
    UILabel *fr = [self lbl:XZS(20) frame:CGRectMake(XZ_PANEL_W - 72, 0, 60, 22)
                      color:XZ_MUTED size:9 weight:UIFontWeightRegular];
    fr.textAlignment = NSTextAlignmentRight;
    [foot addSubview:fr];
    [_scroll addSubview:foot];
    _contentY += 22.0;

    _scroll.contentSize = CGSizeMake(XZ_PANEL_W, _contentY);

    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                   selector:@selector(tick) userInfo:nil repeats:YES];
    [self tick];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _scroll.frame = CGRectMake(0, 36, b.size.width, b.size.height - 36);
}

- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint p = [g translationInView:self.view.superview];
    self.view.center = CGPointMake(self.view.center.x + p.x, self.view.center.y + p.y);
    [g setTranslation:CGPointZero inView:self.view.superview];
}

- (void)tick {
    _stBase.text = [NSString stringWithFormat:@"0x%llx",
                    (unsigned long long)GetIl2CppBase()];
    _stHook.text = g_hookInstalled ? XZS(18) : XZS(17);
    _stHook.textColor = g_hookInstalled ? XZ_GREEN : XZ_MUTED;
    _stPlayers.text = [NSString stringWithFormat:@"%d", g_playerCount];
    _stEsp.text = g_espEnabled ? XZS(16) : XZS(17);
    _stEsp.textColor = g_espEnabled ? XZ_GREEN : XZ_MUTED;
    _stInj.text = g_injected ? XZS(16) : XZS(17);
    _stInj.textColor = g_injected ? XZ_GREEN : XZ_MUTED;
    if (g_injected && !_injSwitch.on) _injSwitch.on = YES;
}

- (void)sw1:(MiniToggle*)s { g_espEnabled = s.on; }
- (void)sw3:(MiniToggle*)s { g_aimbotEnabled = s.on; }
- (void)sw4:(MiniToggle*)s { g_flyEnabled = s.on; }
- (void)sw2:(MiniToggle*)s { g_testMode = s.on; }

- (void)sw0:(MiniToggle*)s {
    if (s.on && !g_hookInstalled) InstallLateUpdateHook();
    g_injected = (s.on && g_hookInstalled);
    if (!g_injected) s.on = NO;
}

- (void)cx:(UIButton*)b { [PanelController hide]; }

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

    g_hostVC = [[PanelHost alloc] init];
    g_hostVC.view.backgroundColor = [UIColor clearColor];
    g_menuWindow.rootViewController = g_hostVC;
    g_menuWindow.hidden = NO;
    return g_menuWindow;
}

+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [PanelController menuWindow];
        if (!g_menuVC) g_menuVC = [[PanelController alloc] init];
        if (!g_menuVC.view.superview) [g_hostVC.view addSubview:g_menuVC.view];

        CGRect b = w.bounds;
        CGFloat h = b.size.height - 24;
        if (h > 470) h = 470;
        if (h < 240) h = 240;
        g_menuVC.view.frame = CGRectMake(40, 12, XZ_PANEL_W, h);
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
@interface DragPill : UIButton @end
@implementation DragPill
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

static DragPill *g_fab = nil;
static void ShowFab() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_fab) return;
        UIWindow *w = [PanelController menuWindow];
        CGRect b = w.bounds;

        g_fab = [DragPill buttonWithType:UIButtonTypeCustom];
        g_fab.frame = CGRectMake(b.size.width - 140, b.size.height - 52, 116, 28);
        [g_fab setTitle:XZS(21) forState:UIControlStateNormal];
        [g_fab setTitleColor:XZ_GREEN forState:UIControlStateNormal];
        g_fab.titleLabel.font = XZMono(10, UIFontWeightBold);
        g_fab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
        g_fab.layer.borderWidth = 1.0;
        g_fab.layer.borderColor = XZ_GREEN.CGColor;
        g_fab.layer.cornerRadius = 2.0;
        [g_fab addTarget:[PanelController class] action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:g_fab];
    });
}

// ============================================================
// HOOK PLAYER.LATEUPDATE (activé par INJECT uniquement)
// ============================================================
extern void xz_patch_fn(void *symbol, void *replace, void **result);

static void (*orig_PlayerLateUpdate)(void *self);
static void hooked_PlayerLateUpdate(void *self) {
    if (orig_PlayerLateUpdate) orig_PlayerLateUpdate(self);
    CachePlayer((uintptr_t)self);
}
static void InstallLateUpdateHook() {
    if (g_hookInstalled) return;
    uintptr_t base = GetIl2CppBase();
    if (!base) return;
    uintptr_t target = base + RVA_PLAYER_LATEUPDATE;
    xz_patch_fn((void*)target, (void*)hooked_PlayerLateUpdate, (void**)&orig_PlayerLateUpdate);
    g_hookInstalled = (orig_PlayerLateUpdate != NULL);
}

// ============================================================
// INIT
// ============================================================
__attribute__((constructor))
static void initMenu() {
    // Laisse le jeu démarrer (auth/update) avant d'afficher quoi que ce soit.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
#ifndef FF_NO_UI
        ShowFab();
        [PanelController show];
#endif
    });
}
