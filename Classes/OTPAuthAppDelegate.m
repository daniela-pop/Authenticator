//
//  OTPAuthAppDelegate.m
//
//  Copyright 2011 Google Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not
//  use this file except in compliance with the License.  You may obtain a copy
//  of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
//  License for the specific language governing permissions and limitations under
//  the License.
//

#import "OTPAuthAppDelegate.h"
#import "OTPAuthURL.h"
#import "HOTPGenerator.h"
#import "TOTPGenerator.h"
#import "OTPTableViewCell.h"
#import "OTPWelcomeViewController.h"
#import "OTPAuthBarClock.h"
#import "UIColor+MobileColors.h"
#import "RootViewController.h"

static NSString *const kOTPKeychainEntriesArray = @"OTPKeychainEntries";

@interface OTPGoodTokenSheet : UIActionSheet
@property(readwrite, nonatomic, strong) OTPAuthURL *authURL;
@end

@interface OTPAuthAppDelegate () <UINavigationControllerDelegate>
// The OTPAuthURL objects in this array are loaded from the keychain at
// startup and serialized there on shutdown.
@property (nonatomic, strong) NSMutableArray *authURLs;
@property (nonatomic, strong) RootViewController *rootViewController;
@property (nonatomic, strong) UIBarButtonItem *editButton;
@property (nonatomic) OTPEditingState editingState;
@property (nonatomic, strong) OTPAuthURL *urlBeingAdded;
@property (nonatomic, strong) UIAlertView *urlAddAlert;

- (void)saveKeychainArray;
- (void)updateUI;
@end

@implementation OTPAuthAppDelegate
@synthesize window = window_;
@synthesize navigationController = navigationController_;
@synthesize authURLs = authURLs_;
@synthesize rootViewController = rootViewController_;
@synthesize editButton = editButton_;
@synthesize editingState = editingState_;
@synthesize urlAddAlert = urlAddAlert_;
@synthesize urlBeingAdded = urlBeingAdded_;

- (void)updateUI {
  BOOL hidden = YES;
  for (OTPAuthURL *url in self.authURLs) {
    if ([url isMemberOfClass:[TOTPAuthURL class]]) {
      hidden = NO;
      break;
    }
  }
  self.rootViewController.clock.hidden = hidden;
  self.editButton.enabled = [self.authURLs count] > 0;
}

- (void)saveKeychainArray {
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  NSArray *keychainReferences = [self valueForKeyPath:@"authURLs.keychainItemRef"];
  [ud setObject:keychainReferences forKey:kOTPKeychainEntriesArray];
  [ud synchronize];
}

#pragma mark -
#pragma mark Application Delegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  NSArray *savedKeychainReferences = [ud arrayForKey:kOTPKeychainEntriesArray];
  self.authURLs
      = [NSMutableArray arrayWithCapacity:[savedKeychainReferences count]];
  for (NSData *keychainRef in savedKeychainReferences) {
    OTPAuthURL *authURL = [OTPAuthURL authURLWithKeychainItemRef:keychainRef];
    if (authURL) {
      [self.authURLs addObject:authURL];
    }
  }
    
    UIWindow *window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    RootViewController *rootVC = [[RootViewController alloc] init];
    rootVC.delegate = self;
    self.rootViewController = rootVC;
    
    UINavigationController *rootNavController = [[UINavigationController alloc] initWithRootViewController:rootVC];
    rootNavController.delegate = self;
    self.navigationController = rootNavController;

    window.rootViewController = rootNavController;
	[window makeKeyAndVisible];
	self.window = window;

  if ([self.authURLs count] == 0) {
    OTPWelcomeViewController *controller = [[OTPWelcomeViewController alloc] init];
    [rootNavController pushViewController:controller animated:NO];
  }
    
  return YES;
}

- (BOOL)application:(UIApplication *)application handleOpenURL:(NSURL *)url {
  OTPAuthURL *authURL = [OTPAuthURL authURLWithURL:url secret:nil];
  if (authURL) {
    NSString *title = NSLocalizedString(@"Add Token",
                                        @"Add Token Alert Title");
    NSString *message
      = [NSString stringWithFormat:
         NSLocalizedString(@"Do you want to add the token named “%@”?",
                           @"Add Token Message"), [authURL name]];
    NSString *noButton = NSLocalizedString(@"No", @"No");
    NSString *yesButton = NSLocalizedString(@"Yes", @"Yes");

    self.urlAddAlert = [[UIAlertView alloc] initWithTitle:title
                                                   message:message
                                                  delegate:self
                                         cancelButtonTitle:noButton
                                         otherButtonTitles:yesButton, nil];
    self.urlBeingAdded = authURL;
    [self.urlAddAlert show];
  }
  return authURL != nil;
}

#pragma mark -
#pragma mark OTPManualAuthURLEntryControllerDelegate

- (void)authURLEntryController:(OTPAuthURLEntryController*)controller
              didCreateAuthURL:(OTPAuthURL *)authURL {
  [self.navigationController dismissViewControllerAnimated:YES completion:NULL];
  [self.navigationController popToRootViewControllerAnimated:NO];
  [authURL saveToKeychain];
  [self.authURLs addObject:authURL];
  [self saveKeychainArray];
  [self updateUI];
  UITableView *tableView = (UITableView*)self.rootViewController.view;
  [tableView reloadData];
}

#pragma mark -
#pragma mark UINavigationControllerDelegate

- (void)navigationController:(UINavigationController *)navigationController
      willShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
  [self.rootViewController setEditing:NO animated:animated];
  // Only display the toolbar for the rootViewController.
  BOOL hidden = viewController != self.rootViewController;
  [navigationController setToolbarHidden:hidden animated:YES];
}

- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
  if (viewController == self.rootViewController) {
    self.editButton = viewController.editButtonItem;
    UIToolbar *toolbar = self.navigationController.toolbar;
    NSMutableArray *items = [NSMutableArray arrayWithArray:toolbar.items];
    // We are replacing our "proxy edit button" with a real one.
    items[0] = self.editButton;
    toolbar.items = items;

    [self updateUI];
  }
}

#pragma mark -
#pragma mark UITableViewDataSource

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSString *cellIdentifier = nil;
  Class cellClass = Nil;

  // See otp_tableViewWillBeginEditing for comments on why this is being done.
  NSUInteger idx = self.editingState == kOTPEditingTable ? [indexPath row] : [indexPath section];
  OTPAuthURL *url = (self.authURLs)[idx];
  if ([url isMemberOfClass:[HOTPAuthURL class]]) {
    cellIdentifier = @"HOTPCell";
    cellClass = [HOTPTableViewCell class];
  } else if ([url isMemberOfClass:[TOTPAuthURL class]]) {
    cellIdentifier = @"TOTPCell";
    cellClass = [TOTPTableViewCell class];
  }
  UITableViewCell *cell
    = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
  if (!cell) {
    cell = [[cellClass alloc] initWithStyle:UITableViewCellStyleDefault
                             reuseIdentifier:cellIdentifier];
  }
  [(OTPTableViewCell *)cell setAuthURL:url];
  return cell;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  // See otp_tableViewWillBeginEditing for comments on why this is being done.
  return self.editingState == kOTPEditingTable ? 1 : [self.authURLs count];
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
  // See otp_tableViewWillBeginEditing for comments on why this is being done.
  return self.editingState == kOTPEditingTable ? [self.authURLs count] : 1;
}

- (void)tableView:(UITableView *)tableView
    moveRowAtIndexPath:(NSIndexPath *)fromIndexPath
           toIndexPath:(NSIndexPath *)toIndexPath {
  NSUInteger oldIndex = [fromIndexPath row];
  NSUInteger newIndex = [toIndexPath row];
  [self.authURLs exchangeObjectAtIndex:oldIndex withObjectAtIndex:newIndex];
  [self saveKeychainArray];
}

- (void)tableView:(UITableView *)tableView
   commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (editingStyle == UITableViewCellEditingStyleDelete) {
    OTPTableViewCell *cell
      = (OTPTableViewCell *)[tableView cellForRowAtIndexPath:indexPath];
    [cell didEndEditing];
    [tableView beginUpdates];
    NSUInteger idx = self.editingState == kOTPEditingTable ? [indexPath row] : [indexPath section];
    OTPAuthURL *authURL = (self.authURLs)[idx];

    // See otp_tableViewWillBeginEditing for comments on why this is being done.
    if (self.editingState == kOTPEditingTable) {
      NSIndexPath *path = [NSIndexPath indexPathForRow:idx inSection:0];
      NSArray *rows = @[path];
      [tableView deleteRowsAtIndexPaths:rows
                       withRowAnimation:UITableViewRowAnimationFade];
    } else {
      NSIndexSet *set = [NSIndexSet indexSetWithIndex:idx];
      [tableView deleteSections:set
               withRowAnimation:UITableViewRowAnimationFade];
    }
    [authURL removeFromKeychain];
    [self.authURLs removeObjectAtIndex:idx];
    [self saveKeychainArray];
    [tableView endUpdates];
    [self updateUI];
    if ([self.authURLs count] == 0 && self.editingState != kOTPEditingSingleRow) {
		[self.rootViewController setEditing:!self.rootViewController.editing animated:YES];
    }
  }
}

#pragma mark -
#pragma mark UITableViewDelegate

- (void)tableView:(UITableView*)tableView
    willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  NSAssert(self.editingState == kOTPNotEditing, @"Should not be editing");
  OTPTableViewCell *cell
      = (OTPTableViewCell *)[tableView cellForRowAtIndexPath:indexPath];
  [cell willBeginEditing];
  self.editingState = kOTPEditingSingleRow;
}

- (void)tableView:(UITableView*)tableView
   didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  NSAssert(self.editingState == kOTPEditingSingleRow, @"Must be editing single row");
  OTPTableViewCell *cell
      = (OTPTableViewCell *)[tableView cellForRowAtIndexPath:indexPath];
  [cell didEndEditing];
  self.editingState = kOTPNotEditing;
}

#pragma mark -
#pragma mark OTPTableViewDelegate

// With iOS <= 4 there doesn't appear to be a way to move rows around safely
// in a multisectional table where you want to maintain a single row per
// section. You have control over where a row would go into a section with
// tableView:targetIndexPathForMoveFromRowAtIndexPath:toProposedIndexPath:
// but it doesn't allow you to enforce only one row per section.
// By doing this we collapse the table into a single section with multiple rows
// when editing, and then expand back to the "spaced" out view when editing is
// done. We only want this to be done when editing the entire table (by hitting
// the edit button) as when you swipe a row to edit it doesn't allow you
// to move the row.
// When a row is swiped, tableView:willBeginEditingRowAtIndexPath: is called
// first, which means that self.editingState will be set to kOTPEditingSingleRow
// This means that in all code that deals with indexes of items that we need
// to check to see if self.editingState == kOTPEditingTable to know whether to
// check for the index of rows in section 0, or the indexes of the sections
// themselves.
- (void)otp_tableViewWillBeginEditing:(UITableView *)tableView {
  if (self.editingState == kOTPNotEditing) {
    self.editingState = kOTPEditingTable;
    [tableView reloadData];
  }
}

- (void)otp_tableViewDidEndEditing:(UITableView *)tableView {
  if (self.editingState == kOTPEditingTable) {
    self.editingState = kOTPNotEditing;
    [tableView reloadData];
  }
}

#pragma mark -
#pragma mark UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView
    clickedButtonAtIndex:(NSInteger)buttonIndex {
  NSAssert(alertView == self.urlAddAlert, @"Unexpected Alert");
  if (buttonIndex == 1) {
    [self authURLEntryController:nil
                didCreateAuthURL:self.urlBeingAdded];
  }
  self.urlBeingAdded = nil;
  self.urlAddAlert = nil;
}

#pragma mark -
#pragma mark Actions

- (void)addAuthURL:(id)sender {
    OTPAuthURLEntryController *URLEntry = [[OTPAuthURLEntryController alloc] init];
    URLEntry.delegate = self;
    UINavigationController *authURLNav = [[UINavigationController alloc] initWithRootViewController:URLEntry];
  [self.navigationController presentViewController:authURLNav animated:YES completion:^{
      [self.navigationController popToRootViewControllerAnimated:NO];
      [self.rootViewController setEditing:NO animated:NO];
  }];
}

@end

#pragma mark -

@implementation OTPGoodTokenSheet

@synthesize authURL = authURL_;

@end
