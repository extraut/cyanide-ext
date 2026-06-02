//
//  OverlayCardView.m
//
//  Self-contained settings card for one Picture Overlay entry.
//

#import "OverlayCardView.h"

// ─── colours (dark-UI palette matching the screenshot) ────────────────────
#define kColorCard          [UIColor colorWithWhite:0.12 alpha:1]
#define kColorSection       [UIColor colorWithWhite:0.18 alpha:1]
#define kColorLabel         [UIColor colorWithWhite:0.90 alpha:1]
#define kColorValue         [UIColor colorWithWhite:0.55 alpha:1]
#define kColorTint          [UIColor colorWithRed:0.00 green:0.82 blue:0.82 alpha:1]  // cyan
#define kColorDanger        [UIColor colorWithRed:1.00 green:0.27 blue:0.27 alpha:1]
#define kColorPreviewBG     [UIColor blackColor]
#define kColorSeparator     [UIColor colorWithWhite:0.25 alpha:1]

// ─── dimensions ───────────────────────────────────────────────────────────
static const CGFloat kPad         = 16;
static const CGFloat kRowH        = 44;
static const CGFloat kPreviewH    = 210;   // ← FIX: explicit height so layout counts it
static const CGFloat kBtnH        = 44;
static const CGFloat kCorner      = 12;
static const CGFloat kSliderThumb = 20;

// Z-index limits
static const NSInteger kZMin     = 1;
static const NSInteger kZMax     = 9999;
static const NSInteger kZDefault = 1050;

// ──────────────────────────────────────────────────────────────────────────
@interface OverlayCardView () <UITextFieldDelegate>

// state
@property (nonatomic) NSUInteger overlayId;
@property (nonatomic, copy) NSString *_imagePath;
@property (nonatomic) BOOL _enabled;
@property (nonatomic) NSInteger _scalePct;
@property (nonatomic) NSInteger _alphaPct;
@property (nonatomic) NSInteger _zIndex;
@property (nonatomic) NSInteger _offsetX;
@property (nonatomic) NSInteger _offsetY;

// header
@property (nonatomic, strong) UILabel  *uuidLabel;
@property (nonatomic, strong) UISwitch *enableSwitch;

// preview
@property (nonatomic, strong) UIView      *previewContainer;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UILabel     *previewHUD;        // "X:.. Y:.. S:.. A:.."

// sliders
@property (nonatomic, strong) UISlider *sizeSlider;
@property (nonatomic, strong) UILabel  *sizeLabel;

@property (nonatomic, strong) UISlider *alphaSlider;
@property (nonatomic, strong) UILabel  *alphaLabel;

// z-index
@property (nonatomic, strong) UITextField *zIndexField;
@property (nonatomic, strong) UIStepper   *zIndexStepper;

// offsets
@property (nonatomic, strong) UISlider *offsetXSlider;
@property (nonatomic, strong) UILabel  *offsetXLabel;

@property (nonatomic, strong) UISlider *offsetYSlider;
@property (nonatomic, strong) UILabel  *offsetYLabel;

@end

// ──────────────────────────────────────────────────────────────────────────
@implementation OverlayCardView

// ── public accessors ──────────────────────────────────────────────────────

- (NSString *)imagePath { return self._imagePath; }
- (BOOL)enabled         { return self._enabled;   }
- (NSInteger)scalePct   { return self._scalePct;  }
- (NSInteger)alphaPct   { return self._alphaPct;  }
- (NSInteger)zIndex     { return self._zIndex;    }
- (NSInteger)offsetX    { return self._offsetX;   }
- (NSInteger)offsetY    { return self._offsetY;   }

// ── designated init ───────────────────────────────────────────────────────

- (instancetype)initWithOverlayId:(NSUInteger)overlayId
                             uuid:(NSString *)uuid
                        imagePath:(nullable NSString *)imagePath
                          enabled:(BOOL)enabled
                          scalePct:(NSInteger)scalePct
                          alphaPct:(NSInteger)alphaPct
                           zIndex:(NSInteger)zIndex
                          offsetX:(NSInteger)offsetX
                          offsetY:(NSInteger)offsetY
{
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.overlayId  = overlayId;
    self._imagePath = imagePath ?: @"";
    self._enabled   = enabled;
    self._scalePct  = scalePct  ?: 100;
    self._alphaPct  = alphaPct  ?: 100;
    self._zIndex    = (zIndex >= kZMin && zIndex <= kZMax) ? zIndex : kZDefault;
    self._offsetX   = offsetX;
    self._offsetY   = offsetY;

    self.backgroundColor = kColorCard;
    self.layer.cornerRadius = kCorner;
    self.layer.masksToBounds = YES;

    [self buildUI:uuid];
    return self;
}

// ── build UI ──────────────────────────────────────────────────────────────

- (void)buildUI:(NSString *)uuid
{
    // ── header row ────────────────────────────────────────────────────────
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    self.uuidLabel = [self makeLabel:[self truncatedUUID:uuid] size:13 color:kColorLabel];
    self.uuidLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];

    self.enableSwitch = [[UISwitch alloc] init];
    self.enableSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.enableSwitch.onTintColor = kColorTint;
    self.enableSwitch.on = self._enabled;
    [self.enableSwitch addTarget:self
                         action:@selector(switchToggled:)
               forControlEvents:UIControlEventValueChanged];

    [header addSubview:self.uuidLabel];
    [header addSubview:self.enableSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [self.uuidLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:kPad],
        [self.uuidLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.uuidLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.enableSwitch.leadingAnchor constant:-8],
        [self.enableSwitch.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-kPad],
        [self.enableSwitch.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [header.heightAnchor constraintEqualToConstant:kRowH],
    ]];

    // ── preview container  (FIXED kPreviewH height) ───────────────────────
    // This is the critical fix: without an explicit heightAnchor the
    // container collapses to 0 in a UIStackView / auto-layout host.
    self.previewContainer = [[UIView alloc] init];
    self.previewContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewContainer.backgroundColor = kColorPreviewBG;

    self.previewImageView = [[UIImageView alloc] init];
    self.previewImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.previewImageView.clipsToBounds = YES;

    self.previewHUD = [self makeLabel:@"" size:11 color:[UIColor colorWithWhite:1 alpha:0.7]];
    self.previewHUD.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewHUD.textAlignment = NSTextAlignmentCenter;

    [self.previewContainer addSubview:self.previewImageView];
    [self.previewContainer addSubview:self.previewHUD];

    [NSLayoutConstraint activateConstraints:@[
        // image fills preview minus small inset
        [self.previewImageView.topAnchor constraintEqualToAnchor:self.previewContainer.topAnchor constant:8],
        [self.previewImageView.leadingAnchor constraintEqualToAnchor:self.previewContainer.leadingAnchor constant:8],
        [self.previewImageView.trailingAnchor constraintEqualToAnchor:self.previewContainer.trailingAnchor constant:-8],
        [self.previewImageView.bottomAnchor constraintEqualToAnchor:self.previewHUD.topAnchor constant:-4],
        // HUD pinned to bottom
        [self.previewHUD.leadingAnchor constraintEqualToAnchor:self.previewContainer.leadingAnchor],
        [self.previewHUD.trailingAnchor constraintEqualToAnchor:self.previewContainer.trailingAnchor],
        [self.previewHUD.bottomAnchor constraintEqualToAnchor:self.previewContainer.bottomAnchor constant:-6],
        [self.previewHUD.heightAnchor constraintEqualToConstant:16],
        // ► THE KEY FIX: explicit height on the container
        [self.previewContainer.heightAnchor constraintEqualToConstant:kPreviewH],
    ]];

    if (self._imagePath.length) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *img = [UIImage imageWithContentsOfFile:self._imagePath];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewImageView.image = img;
                [self updatePreviewHUD];
            });
        });
    }

    // ── slider rows ───────────────────────────────────────────────────────
    UIView *sizeRow   = [self makeSliderRow:@"Size"
                                      value:self._scalePct  min:10  max:300
                                      slider:&_sizeSlider  label:&_sizeLabel
                                      action:@selector(sizeChanged:)
                                      suffix:@"%"];

    UIView *alphaRow  = [self makeSliderRow:@"Opacity"
                                      value:self._alphaPct  min:0   max:100
                                      slider:&_alphaSlider label:&_alphaLabel
                                      action:@selector(alphaChanged:)
                                      suffix:@"%"];

    // ── z-index row ───────────────────────────────────────────────────────
    UIView *zRow = [self buildZIndexRow];

    UIView *offXRow   = [self makeSliderRow:@"Horizontal Offset"
                                      value:self._offsetX   min:-500 max:500
                                      slider:&_offsetXSlider label:&_offsetXLabel
                                      action:@selector(offsetXChanged:)
                                      suffix:@"pt"];

    UIView *offYRow   = [self makeSliderRow:@"Vertical Offset"
                                      value:self._offsetY   min:-500 max:500
                                      slider:&_offsetYSlider label:&_offsetYLabel
                                      action:@selector(offsetYChanged:)
                                      suffix:@"pt"];

    // ── buttons ───────────────────────────────────────────────────────────
    UIButton *changeBtn = [self makeButton:@"Change Image…" color:kColorTint   action:@selector(changeImageTapped)];
    UIButton *deleteBtn = [self makeButton:@"Delete Overlay" color:kColorDanger action:@selector(deleteOverlayTapped)];

    // ── assemble via UIStackView ───────────────────────────────────────────
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        header,
        [self separator],
        self.previewContainer,
        [self separator],
        sizeRow,
        [self separator],
        alphaRow,
        [self separator],
        zRow,
        [self separator],
        offXRow,
        [self separator],
        offYRow,
        [self separator],
        changeBtn,
        [self separator],
        deleteBtn,
    ]];
    stack.axis      = UILayoutConstraintAxisVertical;
    stack.spacing   = 0;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

// ── Z-Index row ───────────────────────────────────────────────────────────

- (UIView *)buildZIndexRow
{
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    // "Z-Index" label
    UILabel *titleLbl = [self makeLabel:@"Z-Index" size:15 color:kColorLabel];

    // hint label (shown below the title)
    UILabel *hintLbl = [self makeLabel:@"1–9999  •  1050 = above icons, 2000 = above alerts"
                                  size:10 color:kColorValue];

    // numeric text field
    self.zIndexField = [[UITextField alloc] init];
    self.zIndexField.translatesAutoresizingMaskIntoConstraints = NO;
    self.zIndexField.keyboardType = UIKeyboardTypeNumberPad;
    self.zIndexField.textAlignment = NSTextAlignmentRight;
    self.zIndexField.textColor = kColorTint;
    self.zIndexField.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold];
    self.zIndexField.text = [NSString stringWithFormat:@"%ld", (long)self._zIndex];
    self.zIndexField.borderStyle = UITextBorderStyleNone;
    self.zIndexField.backgroundColor = [UIColor clearColor];
    self.zIndexField.delegate = self;
    // dismiss keyboard on return
    [self.zIndexField addTarget:self
                         action:@selector(zIndexFieldEditingChanged:)
               forControlEvents:UIControlEventEditingChanged];

    // stepper  (−/+ buttons)
    self.zIndexStepper = [[UIStepper alloc] init];
    self.zIndexStepper.translatesAutoresizingMaskIntoConstraints = NO;
    self.zIndexStepper.minimumValue = kZMin;
    self.zIndexStepper.maximumValue = kZMax;
    self.zIndexStepper.stepValue    = 1;
    self.zIndexStepper.value        = self._zIndex;
    self.zIndexStepper.tintColor    = kColorTint;
    [self.zIndexStepper addTarget:self
                           action:@selector(zIndexStepperChanged:)
                 forControlEvents:UIControlEventValueChanged];

    // layout within row
    [row addSubview:titleLbl];
    [row addSubview:hintLbl];
    [row addSubview:self.zIndexField];
    [row addSubview:self.zIndexStepper];

    [NSLayoutConstraint activateConstraints:@[
        // title – top-left
        [titleLbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kPad],
        [titleLbl.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],

        // hint – below title
        [hintLbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kPad],
        [hintLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:2],
        [hintLbl.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],

        // stepper – right edge
        [self.zIndexStepper.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kPad],
        [self.zIndexStepper.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        // text field – left of stepper
        [self.zIndexField.trailingAnchor constraintEqualToAnchor:self.zIndexStepper.leadingAnchor constant:-10],
        [self.zIndexField.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [self.zIndexField.widthAnchor constraintEqualToConstant:56],
    ]];

    return row;
}

// ── slider row factory ────────────────────────────────────────────────────

- (UIView *)makeSliderRow:(NSString *)title
                    value:(NSInteger)value
                      min:(float)minV max:(float)maxV
                   slider:(UISlider *__strong *)outSlider
                    label:(UILabel *__strong *)outLabel
                   action:(SEL)action
                   suffix:(NSString *)suffix
{
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLbl = [self makeLabel:title size:15 color:kColorLabel];
    UILabel *valueLbl = [self makeLabel:[NSString stringWithFormat:@"%ld%@", (long)value, suffix]
                                   size:13 color:kColorValue];
    valueLbl.textAlignment = NSTextAlignmentRight;

    UISlider *slider = [[UISlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minimumValue = minV;
    slider.maximumValue = maxV;
    slider.value        = (float)value;
    slider.minimumTrackTintColor = kColorTint;
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];

    [row addSubview:titleLbl];
    [row addSubview:valueLbl];
    [row addSubview:slider];

    [NSLayoutConstraint activateConstraints:@[
        [titleLbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kPad],
        [titleLbl.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],

        [valueLbl.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kPad],
        [valueLbl.centerYAnchor constraintEqualToAnchor:titleLbl.centerYAnchor],
        [valueLbl.widthAnchor constraintEqualToConstant:70],

        [slider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kPad],
        [slider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kPad],
        [slider.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:6],
        [slider.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
    ]];

    *outSlider = slider;
    *outLabel  = valueLbl;
    return row;
}

// ── helpers ───────────────────────────────────────────────────────────────

- (UILabel *)makeLabel:(NSString *)text size:(CGFloat)size color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text      = text;
    l.font      = [UIFont systemFontOfSize:size];
    l.textColor = color;
    return l;
}

- (UIButton *)makeButton:(NSString *)title color:(UIColor *)color action:(SEL)sel
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:color forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:16];
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [btn.heightAnchor constraintEqualToConstant:kBtnH].active = YES;
    return btn;
}

- (UIView *)separator
{
    UIView *sep = [[UIView alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.backgroundColor = kColorSeparator;
    [sep.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return sep;
}

- (NSString *)truncatedUUID:(NSString *)uuid
{
    if (uuid.length <= 30) return uuid;
    return [[uuid substringToIndex:30] stringByAppendingString:@"…"];
}

- (void)updatePreviewHUD
{
    self.previewHUD.text = [NSString stringWithFormat:
        @"X:%ld  Y:%ld  S:%ld%%  A:%ld%%  Z:%ld",
        (long)self._offsetX, (long)self._offsetY,
        (long)self._scalePct, (long)self._alphaPct,
        (long)self._zIndex];
}

// ── actions ───────────────────────────────────────────────────────────────

- (void)switchToggled:(UISwitch *)sw
{
    self._enabled = sw.isOn;
    [self.delegate overlayCardViewDidChangeSettings:self];
}

- (void)sizeChanged:(UISlider *)sl
{
    self._scalePct = (NSInteger)roundf(sl.value);
    self.sizeLabel.text = [NSString stringWithFormat:@"%ld%%", (long)self._scalePct];
    [self updatePreviewHUD];
    [self.delegate overlayCardViewDidChangeSettings:self];
}

- (void)alphaChanged:(UISlider *)sl
{
    self._alphaPct = (NSInteger)roundf(sl.value);
    self.alphaLabel.text = [NSString stringWithFormat:@"%ld%%", (long)self._alphaPct];
    [self updatePreviewHUD];
    [self.delegate overlayCardViewDidChangeSettings:self];
}

- (void)offsetXChanged:(UISlider *)sl
{
    self._offsetX = (NSInteger)roundf(sl.value);
    self.offsetXLabel.text = [NSString stringWithFormat:@"%ldpt", (long)self._offsetX];
    [self updatePreviewHUD];
    [self.delegate overlayCardViewDidChangeSettings:self];
}

- (void)offsetYChanged:(UISlider *)sl
{
    self._offsetY = (NSInteger)roundf(sl.value);
    self.offsetYLabel.text = [NSString stringWithFormat:@"%ldpt", (long)self._offsetY];
    [self updatePreviewHUD];
    [self.delegate overlayCardViewDidChangeSettings:self];
}

// Z-index — text field
- (void)zIndexFieldEditingChanged:(UITextField *)field
{
    NSInteger val = [field.text integerValue];
    if (val < kZMin) val = kZMin;
    if (val > kZMax) val = kZMax;
    self._zIndex = val;
    self.zIndexStepper.value = val;
    [self updatePreviewHUD];
    [self.delegate overlayCardViewDidChangeSettings:self];
}

// Z-index — stepper
- (void)zIndexStepperChanged:(UIStepper *)stepper
{
    self._zIndex = (NSInteger)stepper.value;
    self.zIndexField.text = [NSString stringWithFormat:@"%ld", (long)self._zIndex];
    [self updatePreviewHUD];
    [self.delegate overlayCardViewDidChangeSettings:self];
}

// UITextFieldDelegate: clamp on end-editing
- (void)textFieldDidEndEditing:(UITextField *)field
{
    NSInteger val = [field.text integerValue];
    if (val < kZMin || field.text.length == 0) val = kZMin;
    if (val > kZMax) val = kZMax;
    self._zIndex = val;
    self.zIndexStepper.value = val;
    field.text = [NSString stringWithFormat:@"%ld", (long)val];
    [self updatePreviewHUD];
}

// Prevent entering more than 4 digits
- (BOOL)textField:(UITextField *)textField
shouldChangeCharactersInRange:(NSRange)range
replacementString:(NSString *)string
{
    if (string.length == 0) return YES; // allow backspace
    NSString *result = [textField.text stringByReplacingCharactersInRange:range withString:string];
    return result.length <= 4;
}

- (void)changeImageTapped
{
    [self.delegate overlayCardView:self didRequestChangeImageForId:self.overlayId];
}

- (void)deleteOverlayTapped
{
    [self.delegate overlayCardView:self didRequestDeleteForId:self.overlayId];
}

// ── public ────────────────────────────────────────────────────────────────

- (void)reloadImageFromPath:(NSString *)path
{
    self._imagePath = path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.previewImageView.image = img;
        });
    });
}

@end
