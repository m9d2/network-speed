#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const kNetSpeedPreferencesDomain = @"com.m9d2.netspeedstatus";
static NSString * const kNetSpeedPreferencesChangedNotification = @"com.m9d2.netspeedstatus/preferences.changed";

@interface NSRootListController : PSListController
@end

@implementation NSRootListController

- (NSArray *)specifiers {
	if (_specifiers == nil) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
	NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:kNetSpeedPreferencesDomain];
	id value = [preferences objectForKey:specifier.properties[@"key"]];
	return value ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:kNetSpeedPreferencesDomain];
	[preferences setObject:value forKey:specifier.properties[@"key"]];
	[preferences synchronize];
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
		(__bridge CFStringRef)kNetSpeedPreferencesChangedNotification, NULL, NULL, YES);
}

@end
