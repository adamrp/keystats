//
//  AppDelegate.m
//  Keystats
//
//  Created by Yoshiki Vázquez Baeza on 10/22/13.
//  Copyright (c) 2013 Yoshiki Vázquez Baeza. All rights reserved.
//

#import "AppDelegate.h"

#import "YVBKeyLogger.h"
#import "FMDatabase.h"
#import "YVBKeystrokesDataManager.h"
#import "YVBDailyExecutor.h"
#import "YVBKeystrokesSummaryViewController.h"

@implementation AppDelegate

@synthesize summaryView = _summaryView;
@synthesize waitingForConfirmation = _waitingForConfirmation;

- (void)awakeFromNib{
	// now check that we have accessibility access
	if (![YVBKeyLogger accessibilityIsEnabled]) {
		NSAlert *alert = [[NSAlert alloc] init];
		[alert setMessageText:@"Keystats has not yet been allowed as an "
		 "assistive application."];
		[alert setInformativeText:@"Keystats requires that 'Enable access for "
		 "assistive devices' in the 'Universal Access' preferences panel be "
		 "enabled in order to register the keys being pressed. Once you do "
		 "this, restart Keystats."];
		[alert addButtonWithTitle:@"Quit"];
		[alert addButtonWithTitle:@"Enable Accessibility"];
		[alert setAlertStyle:NSCriticalAlertStyle];

		// modal alerts block the main thread so they get a return code
		NSInteger result = [alert runModal];

		if (result == NSAlertFirstButtonReturn) {
			[NSApp terminate:self];

		}
		else if (result == NSAlertSecondButtonReturn) {
			[YVBKeyLogger requestAccessibilityEnabling];
			[NSApp terminate:self];
		}

	}
	_knowsEarliestDate = NO;

	// add the view controller & reposition it to a nice location in the window
	CGSize currentSize;
	_summaryView = [[YVBKeystrokesSummaryViewController alloc] init];
	currentSize = [[_summaryView view] frame].size;
	[[_summaryView view] setFrame:CGRectMake(7, 5, currentSize.width,
											 currentSize.height)];
	[[[self window] contentView] addSubview:[_summaryView view]];

	// the keylogger can stop logging at any time as a requirement from the OS
	// make sure we listen to this notification so we can take action about it
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(keyLoggerPerishedNotification:)
												 name:YVBKeyLoggerPerishedByLackOfResponseNotification
											   object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(keyLoggerPerishedNotification:)
												 name:YVBKeyLoggerPerishedByUserChangeNotification
											   object:nil];
}

- (void)keyLoggerPerishedNotification:(NSNotification *)aNotification{
#ifdef DEBUG
	NSLog(@"KeyLogger perished");
#endif

	NSString *explanationString = @"Keystats has stopped logging keystrokes";
	NSLog(@"Notification name is %@", [aNotification name]);
	if ([[aNotification name] isEqualToString:YVBKeyLoggerPerishedByUserChangeNotification]) {
		explanationString = @"USER CHANGES NOTIFICATION";
	}
	if ([[aNotification name] isEqualToString:YVBKeyLoggerPerishedByLackOfResponseNotification]) {
		explanationString = @"TIMEOUT NOTIFICATION";
	}

	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:explanationString];
	[alert setInformativeText:@"This usually happens when the system is being "
	 "slowed down by the action of logging the keystrokes in your system. "
	 "Keystats is letting you know in case you want to continue Keystats "
	 "regardless or if you've seen this message a few times recently, then "
	 "quit the application and contact the developer."];
	[alert addButtonWithTitle:@"Continue using Keystats"];
	[alert addButtonWithTitle:@"Terminate Keystats"];
	[alert setAlertStyle:NSCriticalAlertStyle];

	// modal alerts block the main thread so they get a return code
	NSInteger result = [alert runModal];

	if (result == NSAlertFirstButtonReturn) {
		// restart the keylogger and unlock this alert
		[self applicationDidFinishLaunching:nil];
		[self setWaitingForConfirmation:NO];

		return;
	}
	else if (result == NSAlertSecondButtonReturn) {
		[NSApp terminate:self];
	}


}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification{
	// Insert code here to initialize your application
	NSString *databaseFilePath = [[self pathForApplicationDatabase] path];

	// verify we have a database outside the application's environment
	if (![[NSFileManager defaultManager] fileExistsAtPath:databaseFilePath]) {
		[self copyDatabase];
	}

	dataManager = [[YVBKeystrokesDataManager alloc] initWithFilePath:databaseFilePath];

	// serve like cache of the values, until I figure out how to query a sqlite
	// database about 100 times per second without it delaying the callbacks
	_totalCountValue = 0;
	_todayCountValue = 0;
	_weeklyCountValue = 0;
	_monthlyCountValue = 0;
	[self computeBufferValuesAndUpdateLabels];

	// this executor will take care on updating the labels on day change
	YVBDailyExecutor *executor = [[YVBDailyExecutor alloc] initWithHandler:^(void){
		[self computeBufferValuesAndUpdateLabels];
	}];
	[executor start];

	NSDateFormatter * __block dateFormat = [[NSDateFormatter alloc] init];
	[dateFormat setDateFormat:@"yyyy-MM-dd HH:mm:ss"];

	NSWorkspace * __block workspace = [NSWorkspace sharedWorkspace];

	YVBKeyPressed handlerBlock = ^(NSString *string, long long keyCode, CGEventType eventType){
		if (eventType == kCGEventKeyDown) {
			_totalCountValue++;
			_weeklyCountValue++;
			_monthlyCountValue++;
			_todayCountValue++;

			// update from the count buffers
			[_summaryView updateWithTotalValue:[[dataManager resultFormatter] stringFromNumber:[NSNumber numberWithLongLong:_totalCountValue]]
									todayValue:[[dataManager resultFormatter] stringFromNumber:[NSNumber numberWithLongLong:_todayCountValue]]
							lastSevenDaysValue:[[dataManager resultFormatter] stringFromNumber:[NSNumber numberWithLongLong:_weeklyCountValue]]
						andLastThirtyDaysValue:[[dataManager resultFormatter] stringFromNumber:[NSNumber numberWithLongLong:_monthlyCountValue]]];


			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW,
													 (unsigned long)NULL), ^(void) {
				NSString *dateString = nil;
				dateString = [dateFormat stringFromDate:[NSDate date]];
				[dataManager addKeystrokeWithTimeStamp:dateString
												string:string
											   keycode:keyCode
											 eventType:eventType
						andApplicationBundleIdentifier:[[workspace frontmostApplication] bundleIdentifier]];
			});
		}
	};

	YVBKeyLogger *someKeyLogger = [[YVBKeyLogger alloc] initWithKeyPressedHandler:[handlerBlock copy]];
	[someKeyLogger startLogging];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{
    return YES;
}


- (void)copyDatabase{
	NSFileManager *defaultManager = [NSFileManager defaultManager];
	NSURL *appSupportDir = [defaultManager URLForDirectory:NSApplicationSupportDirectory
												  inDomain:NSUserDomainMask
										 appropriateForURL:nil
													create:YES
													 error:nil];

	NSURL *keystatsSandbox = [appSupportDir URLByAppendingPathComponent:@"Keystats"];

	// the one in our resources
	NSURL *databaseFilePath = [[NSBundle mainBundle] URLForResource:@"keystrokes"
													  withExtension:@""];
	BOOL directoryCreationWorked;

	NSError *error = nil;

	// check the directory exists already and if it doesn't create it
	if(![defaultManager fileExistsAtPath:[keystatsSandbox path]]) {
		directoryCreationWorked = [defaultManager createDirectoryAtURL:keystatsSandbox
										   withIntermediateDirectories:YES
															attributes:nil
																 error:&error];
		if (!directoryCreationWorked) {
			NSLog(@"Failed to create the Keystats directory: %@", [error localizedDescription]);
			[NSAlert alertWithError:error];
			[NSApp terminate:self];
		}
	}

	// assumming the directory exists by now copy the database there
	if ([defaultManager isReadableFileAtPath:[databaseFilePath path]]){
		[defaultManager copyItemAtURL:databaseFilePath
								toURL:[keystatsSandbox URLByAppendingPathComponent:@"keystrokes"]
								error:&error];
	}
	else{
		NSLog(@"Error writing file to destination: %@. Make sure you have "
			  "permission to write to this directory", [databaseFilePath path]);
		[NSApp terminate:self];
	}

	// in case there was an error after the file was copied
	if (error) {
		NSLog(@"Error copying the database: %@", [error localizedDescription]);
		[NSAlert alertWithError:error];
		[NSApp terminate:self];
	}
}

-(NSURL *)pathForApplicationDatabase{
	NSURL *appSupportDir = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
																  inDomain:NSUserDomainMask
														 appropriateForURL:nil
																	create:YES
																	 error:nil];
	NSURL *keystatsSandbox = [appSupportDir URLByAppendingPathComponent:@"Keystats/keystrokes"];

	return keystatsSandbox;
}

- (void)computeBufferValuesAndUpdateLabels{
	// set the labels
	[dataManager getTotalCount:^(NSString *result) {
		[[_summaryView totalCountLabel] setStringValue:result];
		_totalCountValue = [[result stringByReplacingOccurrencesOfString:@","
															  withString:@""] longLongValue];
#ifdef DEBUG
		NSLog(@"The value of total %lld", _totalCountValue);
#endif
	}];
	[dataManager getTodayCount:^(NSString *result) {
		[[_summaryView todayCountLabel] setStringValue:result];
		_todayCountValue = [[result stringByReplacingOccurrencesOfString:@","
															  withString:@""] longLongValue];
#ifdef DEBUG
		NSLog(@"The value of today %lld", _todayCountValue);
#endif
	}];
	[dataManager getWeeklyCount:^(NSString *result) {
		[[_summaryView lastSevenDaysCountLabel] setStringValue:result];
		_weeklyCountValue = [[result stringByReplacingOccurrencesOfString:@","
															   withString:@""] longLongValue];
#ifdef DEBUG
		NSLog(@"The value of this week %lld", _weeklyCountValue);
#endif
	}];
	[dataManager getMonthlyCount:^(NSString *result) {
		[[_summaryView lastThirtyDaysCountLabel] setStringValue:result];
		_monthlyCountValue = [[result stringByReplacingOccurrencesOfString:@","
																withString:@""] longLongValue];
#ifdef DEBUG
		NSLog(@"The value of this month %lld", _monthlyCountValue);
#endif
	}];

	if (!_knowsEarliestDate){
		[dataManager getEarliestDate:^(NSString *result) {
			NSString *dateString;

			// we only need to compute the earliest date one time
			_knowsEarliestDate = YES;

			if (!result) {
				dateString = @"No data has been collected yet";
			}
			else{
				dateString = [NSString stringWithFormat:@"Keystrokes collected since %@", result];
			}
			[[_summaryView earliestDateLabel] setStringValue:dateString];
#ifdef DEBUG
			NSLog(@"Collecting since: %@", dateString);
#endif
		}];
	}

}

- (IBAction)showAboutWindow:(id)sender{
	//Get the information from the plist
	NSDictionary *dictionary = [[NSBundle mainBundle] infoDictionary];;
	NSString *hash = [dictionary objectForKey:@"GitSHA"];
	NSString *status = [dictionary objectForKey:@"GitStatus"];
	NSString *branch = [dictionary objectForKey:@"GitBranch"];

	// If the current branch is master do not output any extra information but
	// the SHA, else then print SHA@BRANCH_NAME for the info in head
	NSString *head = [NSString stringWithFormat:@"%@%@", hash, ([branch isEqualToString:@"master"] ? @"" : [NSString stringWithFormat:@"@%@", branch])];
	NSString *gitInfo;
	NSDictionary *options;

	// when status is 1 the repository has unstaged changes, therefore append a
	// star to tipify a non-clean repository, else just print the SHA1
	gitInfo = [NSString stringWithFormat:@"%@%@",head,([status isEqualToString:@"1"] ? @" *" : @"")];

	// version right now will be the current git SHA and status
	options = [NSDictionary dictionaryWithObjectsAndKeys:gitInfo,@"Version",nil];

	[[NSApplication sharedApplication] orderFrontStandardAboutPanelWithOptions:options];
}

@end
