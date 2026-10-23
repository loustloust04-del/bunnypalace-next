#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
@end

@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(long long)orientation;
- (void)addPointerEventPath:(XCPointerEventPath *)path;
- (BOOL)synthesizeWithError:(NSError **)error;
@end

@protocol P2EventSynthesizing <NSObject>
- (void)synthesizeEvent:(XCSynthesizedEventRecord *)record completion:(void (^)(BOOL, NSError *))completion;
@end
@interface XCUIDevice (P2EventSynthesis)
- (id<P2EventSynthesizing>)eventSynthesizer;
@end

@interface Page2FolderTouchUITests : XCTestCase
@end

@implementation Page2FolderTouchUITests

- (XCUIElement *)visibleApp:(NSString *)identifier in:(XCUIApplication *)app {
    XCUIElement *result = nil;
    for (XCUIElement *element in [app.buttons matchingIdentifier:identifier].allElementsBoundByIndex) {
        CGRect frame = element.frame;
        if (element.hittable && frame.size.width > 40 && frame.origin.y < 700 &&
            (!result || frame.origin.y < result.frame.origin.y)) { result = element; }
    }
    return result;
}

- (XCUIApplication *)openHome { return [self openHomeWithOptions:@{}]; }
- (XCUIApplication *)openHomeWithOptions:(NSDictionary<NSString *, NSString *> *)options {
    self.continueAfterFailure = NO;
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-onboardingCompletedV1", @"YES", @"-page2HomePresentation_v1", @"free", @"-settings.proMode", @"YES", @"page2-ui-test"];
    NSMutableDictionary<NSString *, NSString *> *environment = [@{@"PAGE2_UI_LAYOUT_CASE": NSUUID.UUID.UUIDString, @"PAGE2_UI_RENDERING": @"standard", @"PAGE2_UI_TOUCH_TRACE": @"1"} mutableCopy];
    [environment addEntriesFromDictionary:options];
    app.launchEnvironment = environment;
    if ([app respondsToSelector:NSSelectorFromString(@"setIdleAnimationWaitEnabled:")]) [app setValue:@NO forKey:@"idleAnimationWaitEnabled"];
    [app terminate];
    [app launch];
    NSPredicate *bootReady = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [app.buttons matchingIdentifier:@"随便看看"].firstMatch.exists || [app.otherElements matchingIdentifier:@"page2.free-home"].firstMatch.exists;
    }];
    [XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:bootReady object:nil]] timeout:5];
    if ([app.buttons matchingIdentifier:@"随便看看"].firstMatch.exists) { [app terminate]; [app launch]; }
    [[app.buttons matchingIdentifier:@"page2.app.vocab"].firstMatch waitForExistenceWithTimeout:25];
    for (NSInteger attempt = 0; attempt < 3; attempt++) {
        if ([self visibleApp:@"page2.app.vocab" in:app]) { break; }
        XCUIElement *forward = [app.buttons matchingIdentifier:@"chevron.right"].firstMatch;
        if ([forward waitForExistenceWithTimeout:3] && forward.hittable) { [forward tap]; }
        else { [app swipeLeft]; }
    }
    XCTAssertNotNil([self visibleApp:@"page2.app.vocab" in:app], @"Home fixture did not open; no gesture was sent");
    return app;
}

- (void)testDragFrameCadence {
    XCUIApplication *app = [self openHomeWithOptions:@{@"PAGE2_UI_DRAG_METRICS": @"1", @"PAGE2_UI_TOUCH_TRACE": @"0", @"PAGE2_UI_RENDERING": @"clear"}];
    XCUIElement *source = [self visibleApp:@"page2.app.vocab" in:app];
    [source pressForDuration:3.4];
    XCTAssertTrue([[app.buttons matchingIdentifier:@"完成"].firstMatch waitForExistenceWithTimeout:3]);
    CGPoint start = [self centerOfIcon:[self visibleApp:@"page2.app.vocab" in:app]];
    CGFloat width = app.frame.size.width;
    Class pathClass=NSClassFromString(@"XCPointerEventPath"), recordClass=NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a=[[pathClass alloc] initForTouchAtPoint:start offset:0];
    [a moveToPoint:start atOffset:0.15];
    [a moveToPoint:CGPointMake(width*0.2,560) atOffset:0.5];
    [a moveToPoint:CGPointMake(width*0.8,560) atOffset:1.2];
    [a moveToPoint:CGPointMake(width*0.2,650) atOffset:2.0];
    [a moveToPoint:CGPointMake(width*0.8,650) atOffset:2.8];
    [a moveToPoint:CGPointMake(width*0.2,560) atOffset:3.6];
    [a moveToPoint:CGPointMake(width*0.8,560) atOffset:4.4];
    [a liftUpAtOffset:4.5];
    XCSynthesizedEventRecord *record=[[recordClass alloc] initWithName:@"Page2 drag frame cadence" interfaceOrientation:1];
    [record addPointerEventPath:a];
    [self deliver:record];
    XCTAssertNotNil([self visibleApp:@"page2.app.vocab" in:app]);
    [NSThread sleepForTimeInterval:0.5];
}
- (void)testWidgetHoverPreviewsCancelsAndCommits {
    self.continueAfterFailure = NO;
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-onboardingCompletedV1", @"YES", @"-page2HomePresentation_v1", @"free", @"-settings.proMode", @"YES", @"page2-ui-test"];
    app.launchEnvironment = @{@"PAGE2_UI_LAYOUT_CASE": NSUUID.UUID.UUIDString, @"PAGE2_UI_WIDGET_PAIR": @"small-small", @"PAGE2_UI_RENDERING": @"clear", @"PAGE2_UI_TOUCH_TRACE": @"1"};
    if ([app respondsToSelector:NSSelectorFromString(@"setIdleAnimationWaitEnabled:")]) [app setValue:@NO forKey:@"idleAnimationWaitEnabled"];
    [app terminate]; [app launch];
    if ([[app.buttons matchingIdentifier:@"随便看看"].firstMatch waitForExistenceWithTimeout:2]) { [app terminate]; [app launch]; }
    XCUIElement *source = [app.otherElements matchingIdentifier:@"page2.widget.todo"].firstMatch;
    XCUIElement *target = [app.otherElements matchingIdentifier:@"page2.widget.calendar"].firstMatch;
    XCTAssertTrue([source waitForExistenceWithTimeout:15]); XCTAssertTrue(target.exists);
    [[source coordinateWithNormalizedOffset:CGVectorMake(0.5,0.35)] pressForDuration:3.4];
    XCTAssertTrue([[app.buttons matchingIdentifier:@"完成"].firstMatch waitForExistenceWithTimeout:5]);
    XCUIElement *sourceHandle = [app.otherElements matchingIdentifier:@"page2.resize.todo"].firstMatch;
    XCUIElement *targetHandle = [app.otherElements matchingIdentifier:@"page2.resize.calendar"].firstMatch;
    XCTAssertTrue([sourceHandle waitForExistenceWithTimeout:3]); XCTAssertTrue(targetHandle.exists);
    CGFloat inset = target.frame.size.width / 2 - 9;
    CGPoint start = CGPointMake(CGRectGetMidX(sourceHandle.frame) - inset, CGRectGetMidY(sourceHandle.frame) - inset);
    CGPoint hover = CGPointMake(CGRectGetMidX(targetHandle.frame) - inset, CGRectGetMidY(targetHandle.frame) - inset);
    Class paths = NSClassFromString(@"XCPointerEventPath"), records = NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a = [[paths alloc] initForTouchAtPoint:start offset:0];
    [a moveToPoint:start atOffset:0.2]; [a moveToPoint:hover atOffset:0.8];
    [a moveToPoint:hover atOffset:3.5]; [a moveToPoint:start atOffset:4.1]; [a liftUpAtOffset:4.3];
    XCSynthesizedEventRecord *record = [[records alloc] initWithName:@"Widget stack preview then withdraw" interfaceOrientation:1];
    [record addPointerEventPath:a];
    XCTestExpectation *done = [[XCTestExpectation alloc] initWithDescription:@"Widget preview withdrawn"];
    __block BOOL success = NO; __block NSError *failure = nil;
    [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:record completion:^(BOOL result,NSError *error) { success=result;failure=error;[done fulfill]; }];
    XCUIElement *preview = [[app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"page2.stack-drop-preview"].firstMatch;
    XCTAssertTrue([preview waitForExistenceWithTimeout:3]);
    XCTAssertTrue([[app.buttons matchingIdentifier:@"从主屏移除日历"].firstMatch waitForNonExistenceWithTimeout:2]);
    XCTAttachment *shot = [XCTAttachment attachmentWithScreenshot:app.screenshot]; shot.name = @"widget-stack-held-preview"; shot.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:shot];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[done] timeout:8], XCTWaiterResultCompleted); XCTAssertTrue(success,@"%@",failure);
    XCTAssertTrue(source.exists); XCTAssertTrue(target.exists); XCTAssertFalse(preview.exists);
    [[self point:start app:app] pressForDuration:0.2
        thenDragToCoordinate:[self point:hover app:app] withVelocity:180 thenHoldForDuration:3];
    XCUIElement *stack = [[app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:[NSPredicate predicateWithFormat:@"identifier BEGINSWITH %@", @"page2.stack."]].firstMatch;
    XCTAssertTrue([stack waitForExistenceWithTimeout:5]);
    XCTAssertFalse([app.collectionViews matchingIdentifier:@"page2.stack-editor-cards"].firstMatch.exists);
    shot = [XCTAttachment attachmentWithScreenshot:app.screenshot]; shot.name = @"widget-stack-release-committed"; shot.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:shot];
    [app terminate]; [app launch]; XCTAssertTrue([stack waitForExistenceWithTimeout:15]);
}

- (void)testDockHoverStaysOpenDuringSlowEntry {
    XCUIApplication *app = [self openHome];
    [[self visibleApp:@"page2.app.calendar" in:app] pressForDuration:3.4];
    XCUIElement *dock = [app.scrollViews matchingIdentifier:@"page2.dock"].firstMatch;
    XCUIElement *source = [dock.buttons matchingIdentifier:@"page2.app.memory"].firstMatch;
    XCUIElement *target = [dock.buttons matchingIdentifier:@"page2.app.calendar"].firstMatch;
    XCTAssertTrue(source.exists); XCTAssertTrue(target.exists);
    CGPoint start = CGPointMake(CGRectGetMidX(source.frame), CGRectGetMidY(source.frame));
    CGPoint hover = CGPointMake((CGRectGetMidX(source.frame) + CGRectGetMidX(target.frame)) / 2, CGRectGetMidY(target.frame));
    CGPoint approach = CGPointMake(hover.x + 20, hover.y - 80);
    CGPoint inside = CGPointMake(app.frame.size.width * 0.5, app.frame.size.height * 0.45);
    Class paths = NSClassFromString(@"XCPointerEventPath"), records = NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a = [[paths alloc] initForTouchAtPoint:start offset:0];
    [a moveToPoint:start atOffset:0.2];
    [a moveToPoint:hover atOffset:0.7];
    [a moveToPoint:hover atOffset:3.0];
    [a moveToPoint:approach atOffset:3.8];
    [a moveToPoint:approach atOffset:7.0];
    [a moveToPoint:inside atOffset:8.0];
    [a liftUpAtOffset:8.8];
    XCSynthesizedEventRecord *record = [[records alloc] initWithName:@"Dock hover then slow approach outside panel and enter" interfaceOrientation:1];
    [record addPointerEventPath:a];
    XCTestExpectation *done = [[XCTestExpectation alloc] initWithDescription:@"Dock held icon released"];
    __block BOOL success = NO; __block NSError *failure = nil;
    [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:record completion:^(BOOL result,NSError *error) { success=result;failure=error;[done fulfill]; }];
    XCUIElement *title = [app.textFields matchingPredicate:[NSPredicate predicateWithFormat:@"placeholderValue == %@", @"文件夹"]].firstMatch;
    XCTAssertTrue([title waitForExistenceWithTimeout:3]);
    XCTestExpectation *approaching = [[XCTestExpectation alloc] initWithDescription:@"Held outside opened folder"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [approaching fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[approaching] timeout:4], XCTWaiterResultCompleted);
    XCTAssertTrue(title.exists, @"Folder closed before the held icon reached its panel");
    XCTAttachment *held = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    held.name = @"dock-folder-kept-open-on-approach"; held.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:held];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[done] timeout:12], XCTWaiterResultCompleted);
    XCTAssertTrue(success, @"%@", failure);
    XCTAssertTrue(title.exists);
    XCUIElement *pager = [self folderPager:app];
    XCTAssertTrue([[pager.buttons matchingIdentifier:@"page2.app.memory"].firstMatch waitForExistenceWithTimeout:5]);
    XCTAssertTrue([pager.buttons matchingIdentifier:@"page2.app.calendar"].firstMatch.exists);
    XCTAttachment *landed = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    landed.name = @"dock-folder-slow-entry-landed"; landed.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:landed];
}

- (void)testContinuousHoldFollowsInsideOpenFolder {
    XCUIApplication *app = [self openHome];
    XCUIElement *source = [self visibleApp:@"page2.app.vocab" in:app];
    XCUIElement *target = [self visibleApp:@"page2.app.reading" in:app];
    XCTAssertNotNil(source);
    XCTAssertNotNil(target);
    CGRect sourceFrame = source.frame;
    CGRect targetFrame = target.frame;
    CGPoint start = CGPointMake(CGRectGetMidX(sourceFrame), sourceFrame.origin.y + sourceFrame.size.width / 2);
    CGPoint hover = CGPointMake(CGRectGetMidX(targetFrame), targetFrame.origin.y + targetFrame.size.width / 2);
    CGPoint inside = CGPointMake(app.frame.size.width * 0.7, app.frame.size.height * 0.52);
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    XCTAssertNotNil(pathClass);
    XCTAssertNotNil(recordClass);
    XCPointerEventPath *path = [[pathClass alloc] initForTouchAtPoint:start offset:0];
    [path moveToPoint:start atOffset:0.5];
    [path moveToPoint:hover atOffset:0.95];
    [path moveToPoint:hover atOffset:3.0];
    [path moveToPoint:inside atOffset:3.5];
    [path liftUpAtOffset:4.0];
    XCSynthesizedEventRecord *record = [[recordClass alloc] initWithName:@"Page2 continuous folder hover and drop" interfaceOrientation:UIInterfaceOrientationPortrait];
    [record addPointerEventPath:path];
    NSLog(@"P2_FOLDER_TOUCH start=%@ hover=%@ inside=%@ offsets=0,0.5,0.95,3.0,3.5,4.0", NSStringFromCGPoint(start), NSStringFromCGPoint(hover), NSStringFromCGPoint(inside));
    NSError *error = nil;
    XCTAssertTrue([record synthesizeWithError:&error], @"%@", error);
    XCUIElement *title = [app.textFields matchingPredicate:[NSPredicate predicateWithFormat:@"placeholderValue == %@", @"文件夹"]].firstMatch;
    XCTAssertTrue([title waitForExistenceWithTimeout:5]);
    NSPredicate *settled = [NSPredicate predicateWithBlock:^BOOL(id value, NSDictionary *bindings) {
        XCUIElement *icon = [self visibleApp:@"page2.app.vocab" in:app];
        return icon && CGRectGetMidX(icon.frame) > 180 && CGRectGetMidX(icon.frame) < 250 && icon.frame.origin.y > 250 && icon.frame.origin.y < 400;
    }];
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:settled object:nil];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:5], XCTWaiterResultCompleted);
    XCTAttachment *shot = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    shot.name = @"folder-continuous-touch-landed";
    shot.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:shot];
}
- (void)verifyInterruptedAbsorption:(BOOL)finishEditing {
    XCUIApplication *app = [self openHome];
    [[self visibleApp:@"page2.app.vocab" in:app] pressForDuration:3.4];
    CGRect source = [self visibleApp:@"page2.app.vocab" in:app].frame;
    CGRect target = [self visibleApp:@"page2.app.reading" in:app].frame;
    CGRect control = finishEditing ? [app.buttons matchingIdentifier:@"完成"].firstMatch.frame
                                  : [self visibleApp:@"page2.app.health" in:app].frame;
    CGPoint start = CGPointMake(CGRectGetMidX(source), source.origin.y + source.size.width / 2);
    CGPoint hover = CGPointMake(CGRectGetMidX(target), target.origin.y + target.size.width / 2);
    CGPoint interrupt = finishEditing ? CGPointMake(CGRectGetMidX(control), CGRectGetMidY(control))
                                     : CGPointMake(control.origin.x + 3, control.origin.y + 3);
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    XCTAssertNotNil(pathClass);
    XCTAssertNotNil(recordClass);
    XCPointerEventPath *a = [[pathClass alloc] initForTouchAtPoint:start offset:0];
    [a moveToPoint:start atOffset:0.15];
    [a moveToPoint:hover atOffset:0.6];
    [a liftUpAtOffset:0.85];
    XCPointerEventPath *b = [[pathClass alloc] initForTouchAtPoint:interrupt offset:1.0];
    [b liftUpAtOffset:1.08];
    XCSynthesizedEventRecord *record = [[recordClass alloc] initWithName:@"Interrupt Page2 absorption" interfaceOrientation:UIInterfaceOrientationPortrait];
    [record addPointerEventPath:a];
    [record addPointerEventPath:b];
    NSError *error = nil;
    XCTAssertTrue([record synthesizeWithError:&error], @"%@", error);
    if (!finishEditing) {
        XCUIElement *alert = [app.alerts matchingIdentifier:@"主屏"].firstMatch;
        XCTAssertTrue([alert waitForExistenceWithTimeout:5]);
        XCUIElement *message = [alert.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS %@", @"取消"]].firstMatch;
        XCTAssertTrue(message.exists);
        [[alert.buttons matchingIdentifier:@"知道了"].firstMatch tap];
    }
    NSPredicate *settled = [NSPredicate predicateWithBlock:^BOOL(id value, NSDictionary *bindings) {
        XCUIElement *original = [self visibleApp:@"page2.app.vocab" in:app];
        return original && fabs(original.frame.origin.x - source.origin.x) < 3 && [self visibleApp:@"page2.app.reading" in:app] != nil;
    }];
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:settled object:nil];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:5], XCTWaiterResultCompleted);
    XCTAssertFalse([app.buttons matchingIdentifier:@"文件夹"].firstMatch.exists);
    if (finishEditing) { XCTAssertFalse([app.buttons matchingIdentifier:@"完成"].firstMatch.exists); }
    else { XCTAssertNil([self visibleApp:@"page2.app.health" in:app]); }
}

- (void)testDoneCancelsPendingAbsorption { [self verifyInterruptedAbsorption:YES]; }
- (void)testChangedLayoutRejectsPendingAbsorption { [self verifyInterruptedAbsorption:NO]; }

- (CGPoint)centerOfIcon:(XCUIElement *)icon {
    CGRect frame = icon.frame;
    return CGPointMake(CGRectGetMidX(frame), frame.origin.y + frame.size.width / 2);
}
- (XCUICoordinate *)point:(CGPoint)point app:(XCUIApplication *)app {
    return [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)] coordinateWithOffset:CGVectorMake(point.x, point.y)];
}
- (XCUIElement *)createClosedFolder:(XCUIApplication *)app {
    NSMutableSet<NSString *> *existing = [NSMutableSet set];
    for (XCUIElement *folder in [app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"identifier BEGINSWITH %@",@"page2.folder."]].allElementsBoundByIndex) [existing addObject:folder.identifier];
    CGPoint from = [self centerOfIcon:[self visibleApp:@"page2.app.vocab" in:app]];
    CGPoint to = [self centerOfIcon:[self visibleApp:@"page2.app.reading" in:app]];
    [[self point:from app:app] pressForDuration:0.5 thenDragToCoordinate:[self point:to app:app] withVelocity:100 thenHoldForDuration:0.2];
    __block NSString *created = nil;
    NSPredicate *ready = [NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {
        for (XCUIElement *folder in [app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"identifier BEGINSWITH %@",@"page2.folder."]].allElementsBoundByIndex) {
            if (![existing containsObject:folder.identifier]) { created=folder.identifier;return YES; }
        }
        return NO;
    }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:nil]] timeout:5],XCTWaiterResultCompleted);
    return [app.buttons matchingIdentifier:created ?: @"missing-created-folder"].firstMatch;
}
- (void)deliver:(XCSynthesizedEventRecord *)record {
    XCTestExpectation *done=[[XCTestExpectation alloc] initWithDescription:@"touches delivered"];
    __block BOOL succeeded=NO; __block NSError *failure=nil;
    [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:record completion:^(BOOL result,NSError *error) { succeeded=result;failure=error;[done fulfill]; }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[done] timeout:10],XCTWaiterResultCompleted);
    XCTAssertTrue(succeeded,@"%@",failure);
}
- (void)testShortMenuDoesNotEnterEditingAfterRelease {
    XCUIApplication *app = [self openHome];
    [[self visibleApp:@"page2.app.vocab" in:app] pressForDuration:0.65];
    XCUIElement *menu = [app.buttons matchingIdentifier:@"编辑主屏幕"].firstMatch;
    XCTAssertTrue([menu waitForExistenceWithTimeout:3]);
    XCTNSPredicateExpectation *unexpected = [[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithFormat:@"exists == YES"] object:[app.buttons matchingIdentifier:@"完成"].firstMatch];
    unexpected.inverted = YES;
    XCTAssertEqual([XCTWaiter waitForExpectations:@[unexpected] timeout:2.8], XCTWaiterResultCompleted);
    [[app coordinateWithNormalizedOffset:CGVectorMake(0.95,0.75)] tap];
    XCTAssertTrue([menu waitForNonExistenceWithTimeout:3]);
    [[self visibleApp:@"page2.app.vocab" in:app] pressForDuration:3.4];
    XCTAssertTrue([[app.buttons matchingIdentifier:@"完成"].firstMatch waitForExistenceWithTimeout:3]);
}
- (void)testSecondFingerOpensFolderAndReleaseInserts {
    XCUIApplication *app = [self openHome];
    XCUIElement *folder = [self createClosedFolder:app];
    CGRect folderFrame = folder.frame;
    CGPoint folderPoint = CGPointMake(CGRectGetMaxX(folderFrame) - 10, folderFrame.origin.y + folderFrame.size.width - 10);
    CGPoint start = [self centerOfIcon:[self visibleApp:@"page2.app.health" in:app]];
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a = [[pathClass alloc] initForTouchAtPoint:start offset:0];
    [a moveToPoint:start atOffset:0.15];
    [a moveToPoint:CGPointMake(220, 580) atOffset:0.65];
    [a moveToPoint:CGPointMake(220, 580) atOffset:1.6];
    [a moveToPoint:CGPointMake(123, 344) atOffset:2.1];
    [a liftUpAtOffset:2.4];
    XCPointerEventPath *b = [[pathClass alloc] initForTouchAtPoint:folderPoint offset:1];
    [b liftUpAtOffset:1.1];
    XCSynthesizedEventRecord *record = [[recordClass alloc] initWithName:@"A holds app, B opens folder, A inserts first" interfaceOrientation:1];
    [record addPointerEventPath:a]; [record addPointerEventPath:b];
    NSLog(@"B_OPEN start=%@ folder=%@", NSStringFromCGPoint(start), NSStringFromCGPoint(folderPoint));
    [self deliver:record];
    XCUIElement *title = [app.textFields matchingPredicate:[NSPredicate predicateWithFormat:@"placeholderValue == %@", @"文件夹"]].firstMatch;
    XCTAssertTrue([title waitForExistenceWithTimeout:5]);
    for (NSString *identifier in @[@"page2.app.health", @"page2.app.vocab", @"page2.app.reading"]) { XCTAssertNotNil([self visibleApp:identifier in:app]); }
    CGRect placed = [self visibleApp:@"page2.app.health" in:app].frame;
    XCTAssertLessThan(CGRectGetMidX(placed), 190);
    XCTAssertGreaterThan(placed.origin.y, 250);
    XCTAssertLessThan(placed.origin.y, 400);
}
- (void)secondFingerPages:(BOOL)folderSource {
    XCUIApplication *app = [self openHome];
    XCUIElement *source;
    if (folderSource) { source = [self createClosedFolder:app]; }
    else { source = [self visibleApp:@"page2.app.vocab" in:app]; [source pressForDuration:3.4]; }
    CGPoint start = [self centerOfIcon:source];
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a = [[pathClass alloc] initForTouchAtPoint:start offset:0];
    [a moveToPoint:start atOffset:0.15];
    [a moveToPoint:CGPointMake(210, 480) atOffset:0.65];
    [a liftUpAtOffset:2.8];
    XCPointerEventPath *b = [[pathClass alloc] initForTouchAtPoint:CGPointMake(380, 720) offset:1.1];
    [b moveToPoint:CGPointMake(40, 720) atOffset:1.5];
    [b liftUpAtOffset:1.6];
    XCSynthesizedEventRecord *record = [[recordClass alloc] initWithName:@"A carrier, B pages, A releases at held position" interfaceOrientation:1];
    [record addPointerEventPath:a]; [record addPointerEventPath:b];
    [self deliver:record];
    XCUIElement *pager = [app.scrollViews matchingIdentifier:@"page2.native-pager"].firstMatch;
    NSPredicate *page = [NSPredicate predicateWithFormat:@"value BEGINSWITH %@", @"第2页"];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:page object:pager]] timeout:5], XCTWaiterResultCompleted);
    XCUIElement *placed = folderSource ? [app.buttons matchingIdentifier:@"文件夹"].firstMatch : [self visibleApp:@"page2.app.vocab" in:app];
    XCTAssertNotNil(placed);
    XCTAssertEqualWithAccuracy(placed.frame.origin.y + 34, 480, 60);
    XCTAssertEqualWithAccuracy(CGRectGetMidX(placed.frame), 210, 55);
    XCTAttachment *shot = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    shot.name = @"held-item-lands-below-finger-after-paging";
    shot.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:shot];
}
- (void)testSecondFingerPagesWithApp { [self secondFingerPages:NO]; }
- (void)testSecondFingerPagesWithFolder { [self secondFingerPages:YES]; }
- (XCUIElement *)folderPager:(XCUIApplication *)app {
    for (XCUIElement *pager in [app.scrollViews matchingIdentifier:@"page2.native-pager"].allElementsBoundByIndex) {
        if (pager.hittable && pager.frame.size.width < 400) return pager;
    }
    return nil;
}
- (void)testInternalFolderPagesPersistAcrossLaunch {
    XCUIApplication *app=[self openHome];
    [[self createClosedFolder:app] tap];
    XCUIElement *source=[self visibleApp:@"page2.app.vocab" in:app];
    XCTAssertNotNil(source);
    Class pc=NSClassFromString(@"XCPointerEventPath"),rc=NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a=[[pc alloc] initForTouchAtPoint:[self centerOfIcon:source] offset:0];
    [a moveToPoint:[self centerOfIcon:source] atOffset:0.15];
    [a moveToPoint:CGPointMake(220,480) atOffset:0.65];
    [a liftUpAtOffset:2.6];
    XCPointerEventPath *b=[[pc alloc] initForTouchAtPoint:CGPointMake(340,560) offset:1.0];
    for (int step=1;step<=20;step++) { [b moveToPoint:CGPointMake(340-12*step,560) atOffset:1.0+0.02*step]; }
    [b liftUpAtOffset:1.5];
    XCSynthesizedEventRecord *record=[[rc alloc] initWithName:@"A inside folder, B pages, A releases" interfaceOrientation:1];
    [record addPointerEventPath:a];[record addPointerEventPath:b];[self deliver:record];
    XCUIElement *pager=[self folderPager:app];XCTAssertNotNil(pager);
    XCTAssertTrue([(NSString *)pager.value hasPrefix:@"第2页"]);
    XCTAssertNotNil([self visibleApp:@"page2.app.vocab" in:app]);
    XCTAssertNil([self visibleApp:@"page2.app.reading" in:app]);
    [[self point:CGPointMake(424,740) app:app] tap];
    [app terminate];[app launch];
    XCUIElement *folder=[app.buttons matchingIdentifier:@"文件夹"].firstMatch;
    XCTAssertTrue([folder waitForExistenceWithTimeout:25]);[folder tap];
    XCTAssertNotNil([self visibleApp:@"page2.app.reading" in:app]);
    XCTAssertNil([self visibleApp:@"page2.app.vocab" in:app]);
    [[self folderPager:app] swipeLeft];
    XCTAssertNotNil([self visibleApp:@"page2.app.vocab" in:app]);
    XCTAssertNil([self visibleApp:@"page2.app.reading" in:app]);
}
- (void)testIncomingAppCanLandOnSecondFolderPage {
    XCUIApplication *app=[self openHome];
    XCUIElement *folderElement=[self createClosedFolder:app];
    CGRect folder=folderElement.frame;
    CGPoint start=[self centerOfIcon:[self visibleApp:@"page2.app.health" in:app]];
    CGPoint tap=CGPointMake(CGRectGetMaxX(folder)-10,folder.origin.y+folder.size.width-10);
    Class pc=NSClassFromString(@"XCPointerEventPath"),rc=NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a=[[pc alloc] initForTouchAtPoint:start offset:0];
    [a moveToPoint:start atOffset:0.15];[a moveToPoint:CGPointMake(220,580) atOffset:0.65];[a liftUpAtOffset:3.2];
    XCPointerEventPath *b=[[pc alloc] initForTouchAtPoint:tap offset:1.0];[b liftUpAtOffset:1.1];
    XCPointerEventPath *c=[[pc alloc] initForTouchAtPoint:CGPointMake(340,560) offset:1.6];
    for (int step=1;step<=20;step++) { [c moveToPoint:CGPointMake(340-12*step,560) atOffset:1.6+0.02*step]; }
    [c liftUpAtOffset:2.1];
    XCSynthesizedEventRecord *record=[[rc alloc] initWithName:@"A outside, B opens then pages folder, A releases" interfaceOrientation:1];
    [record addPointerEventPath:a];[record addPointerEventPath:b];[record addPointerEventPath:c];[self deliver:record];
    XCUIElement *pager=[self folderPager:app];XCTAssertNotNil(pager);
    XCTAssertTrue([(NSString *)pager.value hasPrefix:@"第2页"]);
    XCUIElement *health=[self visibleApp:@"page2.app.health" in:app];XCTAssertNotNil(health);
    XCTAssertLessThan(CGRectGetMidX(health.frame),170);XCTAssertLessThan(health.frame.origin.y,400);
    XCTAssertNil([self visibleApp:@"page2.app.vocab" in:app]);
    [[self point:CGPointMake(424,740) app:app] tap];
    NSPredicate *closed=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) { return folderElement.hittable; }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:closed object:nil]] timeout:4],XCTWaiterResultCompleted);
    [folderElement tap];
    NSPredicate *opened=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) { return [self visibleApp:@"page2.app.reading" in:app] != nil; }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:opened object:nil]] timeout:4],XCTWaiterResultCompleted);
    XCTAssertNotNil([self visibleApp:@"page2.app.reading" in:app]);
    XCTAssertNotNil([self visibleApp:@"page2.app.vocab" in:app]);
    XCTAssertNil([self visibleApp:@"page2.app.health" in:app]);
    [[self folderPager:app] swipeLeft];
    XCTAssertNotNil([self visibleApp:@"page2.app.health" in:app]);
}

- (void)testTenthAppStaysClosedThenOpensDestinationPage {
    XCUIApplication *app=[[XCUIApplication alloc] init];
    app.launchArguments=@[@"page2-ui-test",@"-onboardingCompletedV1",@"YES",@"-page2HomePresentation_v1",@"free",@"-settings.proMode",@"YES"];
    app.launchEnvironment=@{@"PAGE2_UI_LAYOUT_CASE":NSUUID.UUID.UUIDString,@"PAGE2_UI_FOLDER_NINE":@"1",@"PAGE2_UI_RENDERING":@"standard"};
    if ([app respondsToSelector:NSSelectorFromString(@"setIdleAnimationWaitEnabled:")]) [app setValue:@NO forKey:@"idleAnimationWaitEnabled"];
    [app terminate];
    [app launch];
    XCUIElement *folder=[app.buttons matchingIdentifier:@"九个应用"].firstMatch;
    XCTAssertTrue([folder waitForExistenceWithTimeout:25]);
    XCUIElement *source=[self visibleApp:@"page2.app.health" in:app];XCTAssertNotNil(source);
    CGPoint target=[self centerOfIcon:folder];
    [[self point:[self centerOfIcon:source] app:app] pressForDuration:0.5 thenDragToCoordinate:[self point:target app:app] withVelocity:180 thenHoldForDuration:0.25];
    NSPredicate *removed=[NSPredicate predicateWithBlock:^BOOL(id value,NSDictionary *bindings) { return [self visibleApp:@"page2.app.health" in:app] == nil; }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:removed object:nil]] timeout:5],XCTWaiterResultCompleted);
    XCUIElement *title=[app.textFields matchingPredicate:[NSPredicate predicateWithFormat:@"placeholderValue == %@",@"文件夹"]].firstMatch;
    XCTAssertFalse(title.exists);
    [folder tap];
    XCTAssertNotNil([self visibleApp:@"page2.app.health" in:app]);
    XCTAssertTrue([(NSString *)[self folderPager:app].value hasPrefix:@"第2页"]);
    [[self folderPager:app] swipeRight];
    XCTAssertNotNil([self visibleApp:@"page2.app.reading" in:app]);
    XCTAssertNil([self visibleApp:@"page2.app.health" in:app]);
}

- (void)testSecondFingerCanPageBackWhileHoldingApp {
    XCUIApplication *app = [self openHome];
    XCUIElement *source = [self visibleApp:@"page2.app.vocab" in:app];
    [source pressForDuration:3.4];
    CGPoint start = [self centerOfIcon:source];
    CGFloat width = app.frame.size.width;
    Class paths = NSClassFromString(@"XCPointerEventPath"), records = NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a = [[paths alloc] initForTouchAtPoint:start offset:0];
    [a moveToPoint:start atOffset:0.15];
    [a moveToPoint:CGPointMake(width-10,480) atOffset:0.65];
    [a moveToPoint:CGPointMake(width-10,480) atOffset:1.45];
    [a moveToPoint:CGPointMake(210,480) atOffset:1.8];
    [a liftUpAtOffset:4.8];
    XCPointerEventPath *b = [[paths alloc] initForTouchAtPoint:CGPointMake(40,720) offset:3.0];
    [b moveToPoint:CGPointMake(width-40,720) atOffset:3.5]; [b liftUpAtOffset:3.6];
    XCSynthesizedEventRecord *record = [[records alloc] initWithName:@"A holds across edge paging; B returns; A releases" interfaceOrientation:1];
    [record addPointerEventPath:a]; [record addPointerEventPath:b];
    XCTestExpectation *done = [[XCTestExpectation alloc] initWithDescription:@"held source released"];
    __block BOOL success = NO; __block NSError *failure = nil;
    [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:record completion:^(BOOL result,NSError *error) { success=result;failure=error;[done fulfill]; }];
    XCUIElement *pager = [app.scrollViews matchingIdentifier:@"page2.native-pager"].firstMatch;
    NSPredicate *secondPage = [NSPredicate predicateWithFormat:@"value BEGINSWITH %@", @"第2页"];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:secondPage object:pager]] timeout:3], XCTWaiterResultCompleted);
    XCTAssertEqual([XCTWaiter waitForExpectations:@[done] timeout:10],XCTWaiterResultCompleted);
    XCTAssertTrue(success,@"%@",failure);
    NSPredicate *firstPage = [NSPredicate predicateWithFormat:@"value BEGINSWITH %@", @"第1页"];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:firstPage object:pager]] timeout:5], XCTWaiterResultCompleted);
    XCTAssertNotNil([self visibleApp:@"page2.app.vocab" in:app]);
}

- (void)testDoneCancelsWidgetResize {
    XCUIApplication *app = [self openHome];
    [[self visibleApp:@"page2.app.vocab" in:app] pressForDuration:3.4];
    XCUIElement *handle = [app.otherElements matchingIdentifier:@"page2.resize.todo"].firstMatch;
    XCTAssertTrue([handle waitForExistenceWithTimeout:5]);
    CGPoint original = CGPointMake(CGRectGetMidX(handle.frame),CGRectGetMidY(handle.frame));
    XCUIElement *done = [app.buttons matchingIdentifier:@"完成"].firstMatch;
    CGPoint close = CGPointMake(CGRectGetMidX(done.frame),CGRectGetMidY(done.frame));
    Class paths = NSClassFromString(@"XCPointerEventPath"), records = NSClassFromString(@"XCSynthesizedEventRecord");
    XCPointerEventPath *a = [[paths alloc] initForTouchAtPoint:original offset:0];
    [a moveToPoint:CGPointMake(original.x+160,original.y) atOffset:0.8];
    [a liftUpAtOffset:2.4];
    XCPointerEventPath *b = [[paths alloc] initForTouchAtPoint:close offset:1.4]; [b liftUpAtOffset:1.5];
    XCSynthesizedEventRecord *record = [[records alloc] initWithName:@"A resizes, B Done cancels before A releases" interfaceOrientation:1];
    [record addPointerEventPath:a]; [record addPointerEventPath:b]; [self deliver:record];
    XCTAssertFalse(done.exists);
    [[self visibleApp:@"page2.app.vocab" in:app] pressForDuration:3.4];
    XCTAssertTrue([handle waitForExistenceWithTimeout:5]);
    XCTAssertEqualWithAccuracy(CGRectGetMidX(handle.frame),original.x,4);
    XCTAssertEqualWithAccuracy(CGRectGetMidY(handle.frame),original.y,4);
    XCTAttachment *shot = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    shot.name=@"page2-resize-cancelled";shot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:shot];
}
- (void)testFolderClosesIntoItsHomeIcon {
    XCUIApplication *app = [self openHome];
    XCUIElement *folder = [self createClosedFolder:app];
    CGRect original = folder.frame;
    XCUIElement *title = [app.textFields matchingPredicate:[NSPredicate predicateWithFormat:@"placeholderValue == %@",@"文件夹"]].firstMatch;
    [folder tap];
    XCTAssertTrue([title waitForExistenceWithTimeout:5]);
    [NSThread sleepForTimeInterval:0.7];
    [[app coordinateWithNormalizedOffset:CGVectorMake(0.5,0.87)] tap];
    XCTAttachment *closing=[XCTAttachment attachmentWithScreenshot:app.screenshot];
    closing.name=@"page2-folder-closing";closing.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:closing];
    XCTAssertTrue([title waitForNonExistenceWithTimeout:4]);
    NSPredicate *ready=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {return folder.hittable;}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:nil]] timeout:4],XCTWaiterResultCompleted);
    XCTAssertEqualWithAccuracy(CGRectGetMidX(folder.frame),CGRectGetMidX(original),3);
    XCTAssertEqualWithAccuracy(CGRectGetMidY(folder.frame),CGRectGetMidY(original),3);
    NSDate *opening = NSDate.date;
    [folder tap];
    NSLog(@"QUICK_CLOSE_REQUEST after=%.3f",[NSDate.date timeIntervalSinceDate:opening]);
    [[app coordinateWithNormalizedOffset:CGVectorMake(0.5,0.87)] tap];
    XCTAssertTrue([title waitForNonExistenceWithTimeout:4]);
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:nil]] timeout:4],XCTWaiterResultCompleted);
    [folder tap];
    XCTAssertTrue([title waitForExistenceWithTimeout:5]);
    [NSThread sleepForTimeInterval:0.7];
    XCTAssertTrue(title.exists);
    XCTAttachment *reopened=[XCTAttachment attachmentWithScreenshot:app.screenshot];
    reopened.name=@"page2-folder-reopened-after-quick-close";reopened.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:reopened];
}

- (void)testRejectedFolderExtractionKeepsPanelDismissible {
    XCUIApplication *app = [self openHomeWithOptions:@{@"PAGE2_UI_REJECT_EXTRACTION": @"1"}];
    XCUIElement *folder = [self createClosedFolder:app]; [folder tap];
    XCUIElement *title = [app.textFields matchingPredicate:[NSPredicate predicateWithFormat:@"placeholderValue == %@",@"文件夹"]].firstMatch;
    XCTAssertTrue([title waitForExistenceWithTimeout:5]);
    XCUIElement *child = [self visibleApp:@"page2.app.vocab" in:app];
    XCTAssertNotNil(child); XCTAssertGreaterThan(child.frame.origin.y,250);
    [[self point:[self centerOfIcon:child] app:app] pressForDuration:0.3 thenDragToCoordinate:[self point:CGPointMake(370,735) app:app] withVelocity:180 thenHoldForDuration:0.3];
    XCTAssertTrue(title.exists);
    child = [self visibleApp:@"page2.app.vocab" in:app];
    XCTAssertNotNil(child); XCTAssertGreaterThan(child.frame.origin.y,250); XCTAssertLessThan(child.frame.origin.y,650);
    XCTAttachment *shot = [XCTAttachment attachmentWithScreenshot:app.screenshot]; shot.name=@"rejected-extraction-panel-stays-visible"; shot.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:shot];
    [[self point:CGPointMake(220,832) app:app] tap];
    XCTAssertTrue([title waitForNonExistenceWithTimeout:5]);
    XCTAssertTrue(folder.hittable);
}
- (void)testRapidFolderCyclesAndBackgroundRecoverClearHome {
    XCUIApplication *app = [self openHome];
    XCUIElement *folder = [self createClosedFolder:app];
    [[self point:[self centerOfIcon:folder] app:app] pressForDuration:0.3 thenDragToCoordinate:[self point:CGPointMake(371,675) app:app] withVelocity:220 thenHoldForDuration:0.3];
    NSPredicate *positioned = [NSPredicate predicateWithBlock:^BOOL(id value,NSDictionary *bindings) { return folder.frame.origin.y > 600 && CGRectGetMidX(folder.frame) > 330; }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:positioned object:nil]] timeout:5],XCTWaiterResultCompleted);
    CGPoint origin = [self centerOfIcon:folder]; [folder tap];
    XCUIElement *title = [app.textFields matchingPredicate:[NSPredicate predicateWithFormat:@"placeholderValue == %@",@"文件夹"]].firstMatch;
    XCTAssertTrue([title waitForExistenceWithTimeout:5]);
    XCSynthesizedEventRecord *record = [[NSClassFromString(@"XCSynthesizedEventRecord") alloc] initWithName:@"rapid partial folder closing and reopening" interfaceOrientation:1];
    for (NSInteger index=0; index<4; index++) {
        double t = 0.15 + index*0.9;
        XCPointerEventPath *close = [[NSClassFromString(@"XCPointerEventPath") alloc] initForTouchAtPoint:CGPointMake(220,832) offset:t];
        [close liftUpAtOffset:t+0.04]; [record addPointerEventPath:close];
        XCPointerEventPath *open = [[NSClassFromString(@"XCPointerEventPath") alloc] initForTouchAtPoint:origin offset:t+0.58];
        [open liftUpAtOffset:t+0.62]; [record addPointerEventPath:open];
    }
    [self deliver:record];
    NSPredicate *usable = [NSPredicate predicateWithBlock:^BOOL(id value,NSDictionary *bindings) { return folder.hittable || (title.exists && title.hittable); }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:usable object:nil]] timeout:5],XCTWaiterResultCompleted);
    if (!title.exists) { [folder tap]; XCTAssertTrue([title waitForExistenceWithTimeout:5]); }
    [[self point:CGPointMake(220,832) app:app] tap];
    [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
    [app activate];
    XCTAssertTrue([title waitForNonExistenceWithTimeout:5]);
    NSPredicate *ready = [NSPredicate predicateWithBlock:^BOOL(id value,NSDictionary *bindings) { return folder.hittable; }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:nil]] timeout:5],XCTWaiterResultCompleted);
    [folder tap]; XCTAssertTrue([title waitForExistenceWithTimeout:5]);
    XCTAssertNotNil([self visibleApp:@"page2.app.vocab" in:app]);
    XCTAssertNotNil([self visibleApp:@"page2.app.reading" in:app]);
    [[self point:CGPointMake(220,832) app:app] tap]; XCTAssertTrue([title waitForNonExistenceWithTimeout:5]);
    XCTAttachment *shot = [XCTAttachment attachmentWithScreenshot:app.screenshot]; shot.name=@"folder-background-recovery-clear"; shot.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:shot];
}
- (void)testRemovingLastFolderMemberRemovesBackdrop {
    XCUIApplication *app = [self openHome];
    [[self createClosedFolder:app] tap];
    XCUIElement *title = [app.textFields matchingPredicate:[NSPredicate predicateWithFormat:@"placeholderValue == %@",@"文件夹"]].firstMatch;
    XCTAssertTrue([title waitForExistenceWithTimeout:5]);
    XCUIElement *first = [app.buttons matchingIdentifier:@"从文件夹移除单词"].firstMatch;
    XCTAssertTrue([first waitForExistenceWithTimeout:5]); [first tap];
    XCUIElement *last = [app.buttons matchingIdentifier:@"从文件夹移除读书"].firstMatch;
    XCTAssertTrue([last waitForExistenceWithTimeout:5]); [last tap];
    XCTAssertTrue([title waitForNonExistenceWithTimeout:5]);
    [[app.buttons matchingIdentifier:@"完成"].firstMatch tap];
    XCUIElement *search = [app.buttons matchingIdentifier:@"搜索应用"].firstMatch;
    XCTAssertTrue([search waitForExistenceWithTimeout:5]); [search tap];
    XCTAssertTrue([[[app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"page2.spotlight-field"].firstMatch waitForExistenceWithTimeout:5]);
}
@end
