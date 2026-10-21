#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

static NSHashTable<UILabel *> *gNetSpeedLabels;
static dispatch_source_t gSampleTimer;
static uint64_t gPreviousReceived, gPreviousSent, gPreviousTimestamp;
static double gSmoothedDownload, gSmoothedUpload;
static NSString * const kNetSpeedPreferencesDomain = @"com.m9d2.wangsu";
static NSString * const kNetSpeedPreferencesChangedNotification = @"com.m9d2.wangsu/preferences.changed";
static BOOL gNetSpeedEnabled = YES;
static BOOL gShowDownload = YES;
static BOOL gShowUpload = YES;
static CGFloat gFontSize = 8.0;

static void NetSpeedApplyLayout(UILabel *label);

static void NetSpeedLoadPreferences(void) {
	NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:kNetSpeedPreferencesDomain];
	NSUserDefaults *previousPreferences = [[NSUserDefaults alloc] initWithSuiteName:@"com.m9d2.netspeedstatus"];
	for (NSString *key in @[@"enabled", @"showDownload", @"showUpload", @"fontSize"]) {
		if ([preferences objectForKey:key] == nil) {
			id oldValue = [previousPreferences objectForKey:key];
			if (oldValue != nil) [preferences setObject:oldValue forKey:key];
		}
	}
	id enabled = [preferences objectForKey:@"enabled"];
	id showDownload = [preferences objectForKey:@"showDownload"];
	id showUpload = [preferences objectForKey:@"showUpload"];
	id fontSize = [preferences objectForKey:@"fontSize"];
	gNetSpeedEnabled = enabled == nil ? YES : [enabled boolValue];
	gShowDownload = showDownload == nil ? YES : [showDownload boolValue];
	gShowUpload = showUpload == nil ? YES : [showUpload boolValue];
	gFontSize = fontSize == nil ? 8.0 : MIN(12.0, MAX(6.0, [fontSize doubleValue]));
	[preferences synchronize];
}

static uint64_t NetSpeedNow(void) {
	return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

static void NetSpeedReadCounters(uint64_t *received, uint64_t *sent) {
	*received = 0;
	*sent = 0;
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0 || interfaces == NULL) return;

	NSMutableSet<NSString *> *countedInterfaces = [NSMutableSet set];
	for (struct ifaddrs *current = interfaces; current != NULL; current = current->ifa_next) {
		if (current->ifa_name == NULL || current->ifa_addr == NULL || current->ifa_data == NULL) continue;
		if ((current->ifa_flags & IFF_LOOPBACK) != 0) continue;
		NSString *name = [NSString stringWithUTF8String:current->ifa_name];
		if (!([name isEqualToString:@"en0"] || [name hasPrefix:@"pdp_ip"])) continue;
		if ([countedInterfaces containsObject:name]) continue;
		[countedInterfaces addObject:name];

		struct if_data *data = (struct if_data *)current->ifa_data;
		uint64_t rx = (uint64_t)data->ifi_ibytes;
		uint64_t tx = (uint64_t)data->ifi_obytes;
		*received = UINT64_MAX - *received < rx ? UINT64_MAX : *received + rx;
		*sent = UINT64_MAX - *sent < tx ? UINT64_MAX : *sent + tx;
	}
	freeifaddrs(interfaces);
}

static NSString *NetSpeedFormat(double bytesPerSecond) {
	if (!isfinite(bytesPerSecond) || bytesPerSecond < 0.0) bytesPerSecond = 0.0;
	if (bytesPerSecond >= 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.1fM/s", bytesPerSecond / (1024.0 * 1024.0)];
	if (bytesPerSecond >= 1024.0) return [NSString stringWithFormat:@"%.1fK/s", bytesPerSecond / 1024.0];
	return [NSString stringWithFormat:@"%.0fB/s", bytesPerSecond];
}

static UIView *NetSpeedFindStatusBarRoot(UIView *view) {
	for (UIView *ancestor = view; ancestor != nil; ancestor = ancestor.superview) {
		if (ancestor.bounds.size.width >= UIScreen.mainScreen.bounds.size.width * 0.75) return ancestor;
	}
	return view;
}

static UIView *NetSpeedFindClockView(UIView *root) {
	UIView *best = nil;
	CGFloat bestX = CGFLOAT_MAX;
	NSString *className = NSStringFromClass(root.class);
	if ([className rangeOfString:@"Time" options:NSCaseInsensitiveSearch].location != NSNotFound &&
		root.bounds.size.width > 0.0 && root.bounds.size.width < 110.0 && !root.hidden) {
		best = root;
		bestX = [root.superview convertRect:root.frame toView:root.window].origin.x;
	}
	if ([root isKindOfClass:UILabel.class] && !root.hidden) {
		NSString *text = ((UILabel *)root).text ?: @"";
		if ([text rangeOfString:@"^[0-9]{1,2}:[0-9]{2}$" options:NSRegularExpressionSearch].location != NSNotFound) {
			CGFloat x = [root.superview convertRect:root.frame toView:root.window].origin.x;
			if (x < bestX) { best = root; bestX = x; }
		}
	}
	for (UIView *subview in root.subviews) {
		UIView *found = NetSpeedFindClockView(subview);
		if (found != nil) {
			CGFloat x = [found.superview convertRect:found.frame toView:found.window].origin.x;
			if (x < bestX) { best = found; bestX = x; }
		}
	}
	return best;
}

static void NetSpeedAttachLabel(UIView *statusBar) {
	UIView *container = NetSpeedFindStatusBarRoot(statusBar);
	if (container == nil || container.bounds.size.width <= 0.0 || container.bounds.size.height <= 0.0) return;
	if (gNetSpeedLabels == nil) gNetSpeedLabels = [NSHashTable weakObjectsHashTable];
	UILabel *label = (UILabel *)[container viewWithTag:0x4E535053];
	if (label == nil) {
		label = [[UILabel alloc] initWithFrame:CGRectZero];
		label.tag = 0x4E535053;
		label.font = [UIFont monospacedDigitSystemFontOfSize:gFontSize weight:UIFontWeightMedium];
		label.textColor = UIColor.labelColor;
		label.textAlignment = NSTextAlignmentLeft;
		label.numberOfLines = 2;
		label.adjustsFontSizeToFitWidth = YES;
		label.minimumScaleFactor = 0.7;
		label.userInteractionEnabled = NO;
		label.hidden = YES;
		label.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
		[container addSubview:label];
	}
	[gNetSpeedLabels addObject:label];
	NetSpeedApplyLayout(label);
}

static void NetSpeedApplyLayout(UILabel *label) {
	UIView *container = label.superview;
	if (container == nil) return;
	UIView *clock = NetSpeedFindClockView(container);
	static char originalClockTransformKey;
	NSValue *savedTransform = clock == nil ? nil : objc_getAssociatedObject(clock, &originalClockTransformKey);
	if (clock != nil && savedTransform == nil) {
		savedTransform = [NSValue valueWithCGAffineTransform:clock.transform];
		objc_setAssociatedObject(clock, &originalClockTransformKey, savedTransform, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	if (!gNetSpeedEnabled || (!gShowDownload && !gShowUpload)) {
		if (clock != nil && savedTransform != nil) clock.transform = savedTransform.CGAffineTransformValue;
		label.hidden = YES;
		return;
	}
	CGFloat x = 64.0;
	if (clock != nil && clock.window != nil) {
		clock.transform = savedTransform.CGAffineTransformValue;
		CGRect originalClockFrame = [clock.superview convertRect:clock.frame toView:container];
		x = CGRectGetMaxX(originalClockFrame) - 3.0;
		clock.transform = CGAffineTransformTranslate(savedTransform.CGAffineTransformValue, -6.0, 0.0);
	}
	// iPhone 15 Pro Dynamic Island occupies the center; keep the label in the left status-bar lane.
	CGFloat islandSafeRight = (container.bounds.size.width - 126.0) / 2.0 - 5.0;
	CGFloat width = MIN(62.0, MAX(0.0, islandSafeRight - x));
	if (width < 28.0) {
		if (clock != nil && savedTransform != nil) clock.transform = savedTransform.CGAffineTransformValue;
		label.hidden = YES;
		return;
	}
	CGFloat height = MIN(22.0, container.bounds.size.height - 2.0);
	label.frame = CGRectMake(x, (container.bounds.size.height - height) / 2.0, width, height);
}

static void NetSpeedPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	dispatch_async(dispatch_get_main_queue(), ^{
		NetSpeedLoadPreferences();
		for (UILabel *label in gNetSpeedLabels.allObjects) {
			label.font = [UIFont monospacedDigitSystemFontOfSize:gFontSize weight:UIFontWeightMedium];
			label.hidden = !gNetSpeedEnabled || (!gShowDownload && !gShowUpload);
			NetSpeedApplyLayout(label);
		}
	});
}

static void NetSpeedStartSampling(void) {
	if (gSampleTimer != nil) return;
	dispatch_queue_t queue = dispatch_queue_create("com.m9d2.wangsu.sampling", DISPATCH_QUEUE_SERIAL);
	gSampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	dispatch_source_set_timer(gSampleTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(gSampleTimer, ^{
		uint64_t received = 0, sent = 0, now = NetSpeedNow();
		double currentDownload = 0.0, currentUpload = 0.0;
		NetSpeedReadCounters(&received, &sent);
		if (gPreviousTimestamp != 0 && now > gPreviousTimestamp && received >= gPreviousReceived && sent >= gPreviousSent) {
			double interval = (double)(now - gPreviousTimestamp) / 1000000000.0;
			currentDownload = (double)(received - gPreviousReceived) / interval;
			currentUpload = (double)(sent - gPreviousSent) / interval;
			gSmoothedDownload = gSmoothedDownload == 0.0 ? currentDownload : gSmoothedDownload * 0.7 + currentDownload * 0.3;
			gSmoothedUpload = gSmoothedUpload == 0.0 ? currentUpload : gSmoothedUpload * 0.7 + currentUpload * 0.3;
		}
		gPreviousReceived = received;
		gPreviousSent = sent;
		gPreviousTimestamp = now;

		NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:2];
		if (gShowDownload) [lines addObject:[NSString stringWithFormat:@"↓ %@", NetSpeedFormat(gSmoothedDownload)]];
		if (gShowUpload) [lines addObject:[NSString stringWithFormat:@"↑ %@", NetSpeedFormat(gSmoothedUpload)]];
		NSString *text = [lines componentsJoinedByString:@"\n"];
		dispatch_async(dispatch_get_main_queue(), ^{
			for (UILabel *label in gNetSpeedLabels.allObjects) {
				label.font = [UIFont monospacedDigitSystemFontOfSize:gFontSize weight:UIFontWeightMedium];
				label.hidden = !gNetSpeedEnabled || lines.count == 0;
				label.text = text;
				NetSpeedApplyLayout(label);
			}
		});
	});
	dispatch_resume(gSampleTimer);
}

@interface STUIStatusBarForegroundView : UIView
@end

@interface STUIStatusBarDisplayableContainerView : UIView
@end

@interface UIStatusBarForegroundView : UIView
@end

@interface _UIStatusBarForegroundView : UIView
@end

%group NetSpeedSTUIStatusBar

%hook STUIStatusBarForegroundView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachLabel(self);
}

%end

%end

%group NetSpeedSTUIDisplayableContainer

%hook STUIStatusBarDisplayableContainerView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachLabel(self);
}

%end

%end

%group NetSpeedUIStatusBar

%hook UIStatusBarForegroundView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachLabel(self);
}

%end

%end

%group NetSpeedUnderscoreStatusBar

%hook _UIStatusBarForegroundView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachLabel(self);
}

%end

%end

%group NetSpeedCore

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
	%orig;
	NetSpeedLoadPreferences();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		NetSpeedPreferencesChanged, (__bridge CFStringRef)kNetSpeedPreferencesChangedNotification, NULL,
		CFNotificationSuspensionBehaviorDeliverImmediately);
	NetSpeedStartSampling();
}

%end

%end

%ctor {
	NetSpeedLoadPreferences();
	%init(NetSpeedCore);
	if (NSClassFromString(@"STUIStatusBarForegroundView") != Nil) %init(NetSpeedSTUIStatusBar);
	if (NSClassFromString(@"STUIStatusBarDisplayableContainerView") != Nil) %init(NetSpeedSTUIDisplayableContainer);
	if (NSClassFromString(@"UIStatusBarForegroundView") != Nil) %init(NetSpeedUIStatusBar);
	if (NSClassFromString(@"_UIStatusBarForegroundView") != Nil) %init(NetSpeedUnderscoreStatusBar);
}
