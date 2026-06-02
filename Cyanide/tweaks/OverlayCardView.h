//
//  OverlayCardView.h
//
//  Self-contained settings card for one Picture Overlay entry.
//  Drop into any UIScrollView / UIStackView.
//
//  Fixes:
//    • Preview container has an explicit 210 pt height so it never collapses.
//    • Z-Index row added between Opacity and Horizontal Offset.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class OverlayCardView;

@protocol OverlayCardViewDelegate <NSObject>
- (void)overlayCardView:(OverlayCardView *)card didRequestChangeImageForId:(NSUInteger)overlayId;
- (void)overlayCardView:(OverlayCardView *)card didRequestDeleteForId:(NSUInteger)overlayId;
/// Called whenever any value changes so the host can mark a pending change.
- (void)overlayCardViewDidChangeSettings:(OverlayCardView *)card;
@end

@interface OverlayCardView : UIView

/// Designated initialiser.
- (instancetype)initWithOverlayId:(NSUInteger)overlayId
                             uuid:(NSString *)uuid
                        imagePath:(nullable NSString *)imagePath
                          enabled:(BOOL)enabled
                          scalePct:(NSInteger)scalePct
                          alphaPct:(NSInteger)alphaPct
                           zIndex:(NSInteger)zIndex          // 1–9999
                          offsetX:(NSInteger)offsetX
                          offsetY:(NSInteger)offsetY;

@property (nonatomic, readonly) NSUInteger overlayId;

// Current values (read back before calling picture_overlay_apply_in_session)
@property (nonatomic, readonly) BOOL     enabled;
@property (nonatomic, readonly) NSString *imagePath;
@property (nonatomic, readonly) NSInteger scalePct;
@property (nonatomic, readonly) NSInteger alphaPct;
@property (nonatomic, readonly) NSInteger zIndex;     // 1–9999
@property (nonatomic, readonly) NSInteger offsetX;
@property (nonatomic, readonly) NSInteger offsetY;

/// Call after changing imagePath externally (e.g. from "Change Image" picker result).
- (void)reloadImageFromPath:(NSString *)path;

@property (nonatomic, weak, nullable) id<OverlayCardViewDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
