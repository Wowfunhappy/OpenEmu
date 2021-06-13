/*
 Copyright (c) 2011, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEGameViewController.h"

#import "OEDBRom.h"
#import "OEDBSystem.h"
#import "OEDBGame.h"
#import "OEDBScreenshot.h"

#import "OEGameView.h"
#import "OECorePickerController.h"
#import "OEDOGameCoreHelper.h"
#import "OEDOGameCoreManager.h"
#import "OEGameCoreManager.h"
#import "OEThreadGameCoreManager.h"
#import "OEXPCGameCoreManager.h"

#import "OESystemPlugin.h"
#import "OECorePlugin.h"

#import "OEDBSaveState.h"
//#import "OEGameControlsBar.h"

#import "OECoreUpdater.h"

#import "OEGameDocument.h"
#import "OEAudioDeviceManager.h"

#import "OEHUDAlert+DefaultAlertsAdditions.h"
#import "NSURL+OELibraryAdditions.h"
#import "NSColor+OEAdditions.h"
#import "NSViewController+OEAdditions.h"

#import "OEPreferencesController.h"
#import "OELibraryDatabase.h"

//Wowfunhappy
#import "OECompositionPlugin.h"
#import "OEShaderPlugin.h"
#import "OEGameIntegralScalingDelegate.h"

#import <OpenEmuSystem/OpenEmuSystem.h>

NSString *const OEGameVolumeKey = @"volume";
NSString *const OEGameDefaultVideoFilterKey = @"videoFilter";
NSString *const OEGameSystemVideoFilterKeyFormat = @"videoFilter.%@";
NSString *const OEGameCoresInBackgroundKey = @"gameCoreInBackgroundThread";
NSString *const OEDontShowGameTitleInWindowKey = @"dontShowGameTitleInWindow";
NSString *const OEAutoSwitchCoreAlertSuppressionKey = @"changeCoreWhenLoadingStateWitoutConfirmation";
NSString *const OEBackgroundPauseKey = @"backgroundPause";
NSString *const OEForceCorePicker = @"forceCorePicker";
NSString *const OEGameViewControllerEmulationWillFinishNotification = @"OEGameViewControllerEmulationWillFinishNotification";
NSString *const OEGameViewControllerEmulationDidFinishNotification = @"OEGameViewControllerEmulationDidFinishNotification";
NSString *const OETakeNativeScreenshots = @"takeNativeScreenshots";
NSString *const OEGameViewControllerROMKey = @"OEROM";
NSString *const OEGameViewBackgroundColorKey = @"gameViewBackgroundColor";

NSString *const OEScreenshotFileFormatKey = @"screenshotFormat";
NSString *const OEScreenshotPropertiesKey = @"screenshotProperties";

#define UDDefaultCoreMappingKeyPrefix   @"defaultCore"
#define UDSystemCoreMappingKeyForSystemIdentifier(_SYSTEM_IDENTIFIER_) [NSString stringWithFormat:@"%@.%@", UDDefaultCoreMappingKeyPrefix, _SYSTEM_IDENTIFIER_]

@interface OEGameViewController () <OEGameViewDelegate>
{
    // Standard game document stuff
    OEGameView *_gameView;
    OEIntSize   _screenSize;
    OEIntSize   _aspectSize;
    BOOL        _pausedByGoingToBackground;
    
    
    NSArray        *_filterPlugins;
    NSMutableArray *_cheats;
    BOOL            _cheatsLoaded;
}

@end

@implementation OEGameViewController
+ (void)initialize
{
    if([self class] == [OEGameViewController class])
    {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
                                                                  OEScreenshotFileFormatKey : @(NSPNGFileType),
                                                                  OEScreenshotPropertiesKey : @{},
                                                                  }];
    }
}

- (id)init
{
    if((self = [super init]))
    {
        /*_controlsWindow = [[OEGameControlsBar alloc] initWithGameViewController:self];
        [_controlsWindow setReleasedWhenClosed:YES];*/

        NSView *view = [[NSView alloc] initWithFrame:(NSRect){ .size = { 1.0, 1.0 }}];
        [self setView:view];

        _gameView = [[OEGameView alloc] initWithFrame:[[self view] bounds]];
        [_gameView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [_gameView setDelegate:self];

        NSString *backgroundColorName = [[NSUserDefaults standardUserDefaults] objectForKey:OEGameViewBackgroundColorKey];
        if(backgroundColorName != nil)
        {
            NSColor *color = OENSColorFromString(backgroundColorName);
            [_gameView setBackgroundColor:color];
        }
        
        [[self view] addSubview:_gameView];

        //[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewDidChangeFrame:) name:NSViewFrameDidChangeNotification object:_gameView];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_gameView setDelegate:nil];
    _gameView = nil;

    /*[_controlsWindow close];
    _controlsWindow = nil;*/
}

#pragma mark -

- (void)viewDidAppear
{
    [super viewDidAppear];

    /*if([_controlsWindow parentWindow] != nil)
        [[_controlsWindow parentWindow] removeChildWindow:_controlsWindow];*/

    NSWindow *window = [self OE_rootWindow];
    if(window == nil) return;

    /*[window addChildWindow:_controlsWindow ordered:NSWindowAbove];
    [self OE_repositionControlsWindow];
    [_controlsWindow orderFront:self];*/

    [window makeFirstResponder:_gameView];
    
    
    
    //Wowfunhappy
    
    NSMutableSet   *filterSet     = [NSMutableSet set];
    [filterSet addObjectsFromArray:[OECompositionPlugin allPluginNames]];
    [filterSet addObjectsFromArray:[OEShaderPlugin allPluginNames]];
    [filterSet filterUsingPredicate:[NSPredicate predicateWithFormat:@"NOT SELF beginswith '_'"]];
    _filterPlugins = [[filterSet allObjects] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    
    [self extraMenuItemSetup];
    
    
}

//- (void)viewWillDisappear
//{
//    [super viewWillDisappear];
//
//    //[_controlsWindow hide];
//    [[self OE_rootWindow] removeChildWindow:_controlsWindow];
//}

#pragma mark - Controlling Emulation

- (BOOL)supportsCheats;
{
    return [[self document] supportsCheats];
}

- (BOOL)supportsSaveStates
{
    return [[self document] supportsSaveStates];
}

- (NSString *)coreIdentifier;
{
    return [[self document] coreIdentifier];
}

- (NSString *)systemIdentifier;
{
    return [[self document] systemIdentifier];
}

- (NSImage *)takeNativeScreenshot
{
    return [_gameView nativeScreenshot];
}

#pragma mark - HUD Bar Actions
- (void)selectFilter:(id)sender
{
    NSString *filterName;
    if([sender isKindOfClass:[NSString class]])
        filterName = sender;
    else if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] isKindOfClass:[NSString class]])
        filterName = [sender representedObject];
    else if([sender respondsToSelector:@selector(title)] && [[sender title] isKindOfClass:[NSString class]])
        filterName = [sender title];
    else
        DLog(@"Invalid argument passed: %@", sender);

    [_gameView setFilterName:filterName];
    [[NSUserDefaults standardUserDefaults] setObject:filterName forKey:[NSString stringWithFormat:OEGameSystemVideoFilterKeyFormat, [[self document] systemIdentifier]]];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];

    if(action == @selector(selectFilter:))
    {
        if ([[_gameView filterName] isEqualToString:[menuItem title]]) {
            [menuItem setState:NSOnState];
        } else {
            [menuItem setState:NSOffState];
        }
    }
    
    return YES;
}



- (BOOL)extraMenuItemSetup {
    //Wowfunhappy
    
    NSMenu *mainMenu = [NSApp mainMenu];
    
    //Edit Menu
    NSMenuItem *editMenuItem = [mainMenu itemAtIndex:2];
    NSMenu *editMenu = [editMenuItem submenu];
    [editMenu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *item;
    item = [[NSMenuItem alloc] initWithTitle:OELocalizedString(@"Controls...", @"") action:@selector(editControls:) keyEquivalent:@""];
    [editMenu addItem:item];
    
    // Setup Cheats Menu
    if([self supportsCheats])
    {
        NSMenu *cheatsMenu = [[NSMenu alloc] init];
        [cheatsMenu setTitle:OELocalizedString(@"Select Cheat", @"")];
        item = [[NSMenuItem alloc] init];
        [item setTitle:OELocalizedString(@"Select Cheat", @"")];
        [editMenu addItem:item];
        [item setSubmenu:cheatsMenu];
        
        NSMenuItem *addCheatMenuItem = [[NSMenuItem alloc] initWithTitle:OELocalizedString(@"Add Cheat…", @"")
                                                                  action:@selector(addCheat:)
                                                           keyEquivalent:@""];
        [addCheatMenuItem setRepresentedObject:_cheats];
        [cheatsMenu addItem:addCheatMenuItem];
        
        if([_cheats count] != 0)
            [cheatsMenu addItem:[NSMenuItem separatorItem]];
        
        for(NSDictionary *cheatObject in _cheats)
        {
            NSString *description = [cheatObject objectForKey:@"description"];
            BOOL enabled          = [[cheatObject objectForKey:@"enabled"] boolValue];
            
            NSMenuItem *cheatsMenuItem = [[NSMenuItem alloc] initWithTitle:description action:@selector(setCheat:) keyEquivalent:@""];
            [cheatsMenuItem setRepresentedObject:cheatObject];
            [cheatsMenuItem setState:enabled ? NSOnState : NSOffState];
            
            [cheatsMenu addItem:cheatsMenuItem];
        }
    }
    
    // Setup Core selection menu
    NSMenu *coresMenu = [[NSMenu alloc] init];
    [coresMenu setTitle:OELocalizedString(@"Select Core", @"")];
    
    NSString *systemIdentifier = [self systemIdentifier];
    NSArray *corePlugins = [OECorePlugin corePluginsForSystemIdentifier:systemIdentifier];
    if([corePlugins count] > 1)
    {
        corePlugins = [corePlugins sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
            return [[obj1 displayName] compare:[obj2 displayName]];
        }];
        
        for(OECorePlugin *aPlugin in corePlugins)
        {
            NSMenuItem *coreItem = [[NSMenuItem alloc] initWithTitle:[aPlugin displayName] action:@selector(switchCore:) keyEquivalent:@""];
            [coreItem setRepresentedObject:aPlugin];
            
            if([[aPlugin bundleIdentifier] isEqual:[self coreIdentifier]]) [coreItem setState:NSOnState];
            
            [coresMenu addItem:coreItem];
        }
        
        item = [[NSMenuItem alloc] init];
        item.title = OELocalizedString(@"Select Core", @"");
        [item setSubmenu:coresMenu];
        if([[coresMenu itemArray] count] > 1)
            [editMenu addItem:item];
    }
    
    
    
    //View Menu
    
    NSMenuItem *viewMenuItem = [mainMenu itemAtIndex:3];
    NSMenu *viewMenu = [viewMenuItem submenu];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    
    //Setup Video Filter Menu
    NSMenu *filterMenu = [[NSMenu alloc] init];
    [filterMenu setTitle:OELocalizedString(@"Select Filter", @"")];
    
    NSString *selectedFilter = ([[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:OEGameSystemVideoFilterKeyFormat, systemIdentifier]]
                                ? : [[NSUserDefaults standardUserDefaults] objectForKey:OEGameDefaultVideoFilterKey]);
    
    // Select the Default Filter if the current is not available (ie. deleted)
    if(![_filterPlugins containsObject:selectedFilter])
        selectedFilter = [[NSUserDefaults standardUserDefaults] objectForKey:OEGameDefaultVideoFilterKey];
    
    for(NSString *aName in _filterPlugins)
    {
        NSMenuItem *filterItem = [[NSMenuItem alloc] initWithTitle:aName action:@selector(selectFilter:) keyEquivalent:@""];
        if([aName isEqualToString:selectedFilter]) [filterItem setState:NSOnState];
        [filterMenu addItem:filterItem];
    }
    
    item = [[NSMenuItem alloc] init];
    item.title = OELocalizedString(@"Select Filter", @"");
    [viewMenu addItem:item];
    [item setSubmenu:filterMenu];
    
    // Setup integral scaling
    id<OEGameIntegralScalingDelegate> integralScalingDelegate = [self integralScalingDelegate];
    const BOOL hasSubmenu = [integralScalingDelegate shouldAllowIntegralScaling] && [integralScalingDelegate respondsToSelector:@selector(maximumIntegralScale)];
    
    NSMenu *scaleMenu = [NSMenu new];
    [scaleMenu setTitle:OELocalizedString(@"Select Scale", @"")];
    item = [NSMenuItem new];
    [item setTitle:[scaleMenu title]];
    [viewMenu addItem:item];
    [item setSubmenu:scaleMenu];
    
    if(hasSubmenu)
    {
        unsigned int maxScale = [integralScalingDelegate maximumIntegralScale];
        unsigned int currentScale = [integralScalingDelegate currentIntegralScale];
        
        for(unsigned int scale = 1; scale <= maxScale; scale++)
        {
            NSString *scaleTitle  = [NSString stringWithFormat:OELocalizedString(@"%ux", @"Integral scale menu item title"), scale];
            NSMenuItem *scaleItem = [[NSMenuItem alloc] initWithTitle:scaleTitle action:@selector(changeIntegralScale:) keyEquivalent:@""];
            [scaleItem setRepresentedObject:@(scale)];
            [scaleMenu addItem:scaleItem];
        }
    }
    else
        [item setEnabled:NO];
    
    
    return true;
}











#pragma mark - Taking Screenshots
- (void)takeScreenshot:(id)sender
{
    NSImage *screenshotImage;
    bool takeNativeScreenshots = [[NSUserDefaults standardUserDefaults] boolForKey:OETakeNativeScreenshots];
    screenshotImage = takeNativeScreenshots ? [_gameView nativeScreenshot] : [_gameView screenshot];
    NSData *TIFFData = [screenshotImage TIFFRepresentation];

    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    NSBitmapImageFileType type = [standardUserDefaults integerForKey:OEScreenshotFileFormatKey];
    NSDictionary *properties = [standardUserDefaults dictionaryForKey:OEScreenshotPropertiesKey];
    NSBitmapImageRep *bitmapImageRep = [NSBitmapImageRep imageRepWithData:TIFFData];
    NSData *imageData = [bitmapImageRep representationUsingType:type properties:properties];

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH.mm.ss"];
    NSString *timeStamp = [dateFormatter stringFromDate:[NSDate date]];

    NSString *fileName = [NSString stringWithFormat:@"%@ %@.png", [[[[self document] rom] game] displayName], timeStamp];
    NSString *temporaryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSURL *temporaryURL = [NSURL fileURLWithPath:temporaryPath];

    __autoreleasing NSError *error;
    if(![imageData writeToURL:temporaryURL options:NSDataWritingAtomic error:&error])
    {
        NSLog(@"Could not save screenshot at URL: %@, with error: %@", temporaryURL, error);
    } else {
        OEDBRom *rom = [[self document] rom];
        OEDBScreenshot *screenshot = [OEDBScreenshot createObjectInContext:[rom managedObjectContext] forROM:rom withFile:temporaryURL];
        [screenshot save];
    }
}

#pragma mark - OEGameCoreDisplayHelper methods

- (void)setEnableVSync:(BOOL)enable;
{
    [_gameView setEnableVSync:enable];
}

- (void)setScreenSize:(OEIntSize)newScreenSize aspectSize:(OEIntSize)newAspectSize withIOSurfaceID:(IOSurfaceID)newSurfaceID
{
    _screenSize = newScreenSize;
    _aspectSize = newAspectSize;
    [_gameView setScreenSize:_screenSize aspectSize:_aspectSize withIOSurfaceID:newSurfaceID];
}

- (void)setScreenSize:(OEIntSize)newScreenSize withIOSurfaceID:(IOSurfaceID)newSurfaceID;
{
    _screenSize = newScreenSize;
    [_gameView setScreenSize:newScreenSize withIOSurfaceID:newSurfaceID];
}

- (void)setAspectSize:(OEIntSize)newAspectSize;
{
    _aspectSize = newAspectSize;
    [_gameView setAspectSize:newAspectSize];
}

#pragma mark - Info

- (NSSize)defaultScreenSize
{
    if(OEIntSizeIsEmpty(_screenSize) || OEIntSizeIsEmpty(_aspectSize))
        return NSMakeSize(400, 300);

    CGFloat wr = (CGFloat) _aspectSize.width / _screenSize.width;
    CGFloat hr = (CGFloat) _aspectSize.height / _screenSize.height;
    CGFloat ratio = MAX(hr, wr);
    NSSize scaled = NSMakeSize((wr / ratio), (hr / ratio));
    
    CGFloat halfw = scaled.width;
    CGFloat halfh = scaled.height;
    
    return NSMakeSize(_screenSize.width / halfh, _screenSize.height / halfw);
}

#pragma mark - Private Methods

//- (void)OE_repositionControlsWindow
//{
//    NSWindow *gameWindow = [self OE_rootWindow];
//    if(gameWindow == nil) return;
//
//    static const CGFloat _OEControlsMargin = 19;
//
//    NSRect gameViewFrameInWindow = [_gameView convertRect:[_gameView frame] toView:nil];
//    NSPoint origin = [gameWindow convertRectToScreen:gameViewFrameInWindow].origin;
//
//    origin.x += ([_gameView frame].size.width - [_controlsWindow frame].size.width) / 2;
//
//    // If the controls bar fits, it sits over the window
//    if([_gameView frame].size.width >= [_controlsWindow frame].size.width)
//        origin.y += _OEControlsMargin;
//    else
//    {
//        // Otherwise, it sits below the window
//        origin.y -= ([_controlsWindow frame].size.height + _OEControlsMargin);
//
//        // Unless below the window means it being off-screen, in which case it sits above the window
//        if(origin.y < NSMinY([[gameWindow screen] visibleFrame]))
//            origin.y = NSMaxY([gameWindow frame]) + _OEControlsMargin;
//    }
//
//    [_controlsWindow setFrameOrigin:origin];
//}

- (NSWindow *)OE_rootWindow
{
    NSWindow *window = [[self gameView] window];
    while([window parentWindow])
        window = [window parentWindow];
    return window;
}

#pragma mark - Notifications

//- (void)viewDidChangeFrame:(NSNotification*)notification
//{
//    [self OE_repositionControlsWindow];
//}

#pragma mark - OEGameViewDelegate Protocol

- (void)gameView:(OEGameView *)gameView didReceiveMouseEvent:(OEEvent *)event
{
    [[self document] gameViewController:self didReceiveMouseEvent:event];
}

- (void)gameView:(OEGameView *)gameView setDrawSquarePixels:(BOOL)drawSquarePixels
{
    [[self document] gameViewController:self setDrawSquarePixels:drawSquarePixels];
}

@end
