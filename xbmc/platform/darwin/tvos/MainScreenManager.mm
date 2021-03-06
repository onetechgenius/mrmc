/*
 *      Copyright (C) 2012-2013 Team XBMC
 *      http://xbmc.org
 *
 *  This Program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2, or (at your option)
 *  any later version.
 *
 *  This Program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with XBMC; see the file COPYING.  If not, see
 *  <http://www.gnu.org/licenses/>.
 *
 */

#include <signal.h>
#include <sys/resource.h>

#include "utils/log.h"
#include "settings/DisplaySettings.h"
#include "threads/Event.h"
#include "Application.h"
#include "WindowingFactory.h"
#include "settings/DisplaySettings.h"
#include "cores/AudioEngine/AEFactory.h"
#include "platform/darwin/DarwinUtils.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "platform/darwin/tvos/MainScreenManager.h"
#import "platform/darwin/tvos/MainController.h"
#import "platform/darwin/tvos/MainEAGLView.h"

const CGFloat timeSwitchingToExternalSecs = 6.0;
const CGFloat timeSwitchingToInternalSecs = 2.0;
const CGFloat timeFadeSecs                = 2.0;

static CEvent screenChangeEvent;

@implementation MainScreenManager
@synthesize _screenIdx;
@synthesize _externalScreen;
@synthesize _glView;

//--------------------------------------------------------------
- (void) fadeFromBlack:(CGFloat) delaySecs
{
  if([_glView alpha] != 1.0)
  {
    [UIView animateWithDuration:timeFadeSecs delay:delaySecs options:UIViewAnimationOptionCurveEaseInOut animations:^{
      [_glView setAlpha:1.0];
    }
    completion:^(BOOL finished){   screenChangeEvent.Set(); }];
  }
}
//--------------------------------------------------------------
// the real screen/mode change method
- (void) setScreen:(unsigned int) screenIdx withMode:(UIScreenMode *)mode
{
    UIScreen *newScreen = [[UIScreen screens] objectAtIndex:screenIdx];
    bool toExternal = false;

    // current screen is main screen and new screen
    // is different
    if (_screenIdx == 0 && _screenIdx != screenIdx)
      toExternal = true;

    // current screen is not main screen
    // and new screen is the same as current
    // this means we are external already but
    // for example resolution gets changed
    // treat this as toExternal for proper rotation...
    if (_screenIdx != 0 && _screenIdx == screenIdx)
      toExternal = true;

    //set new screen mode
    [newScreen setCurrentMode:mode];

    //mode couldn't be applied to external screen
    //wonkey screen!
    if([newScreen currentMode] != mode)
    {
      NSLog(@"Error setting screen mode!");
      screenChangeEvent.Set();
      return;
    }
    _screenIdx = screenIdx;

    //inform the other layers
    _externalScreen = screenIdx != 0;

    [_glView setScreen:newScreen withFrameBufferResize:TRUE];//will also resize the framebuffer

    if (toExternal)
    {
      // switching back to internal - use same orientation as we used for the touch controller
      [g_xbmcController activateScreen:newScreen];// will attach the screen to xbmc mainwindow
    }

    if(toExternal)//changing the external screen might need some time ...
    {
      //deactivate any overscan compensation when switching to external screens
      if([newScreen respondsToSelector:@selector(overscanCompensation)])
      {
        //since iOS5.0 tvout has an default overscan compensation and property
        //we need to switch it off here so that the tv can handle any
        //needed overscan compensation (else on tvs without "just scan" option
        //we might end up with black borders.
        //Beside that in Apples documentation to setOverscanCompensation
        //the parameter enum is lacking the UIScreenOverscanCompensationNone value.
        //Someone on stackoverflow figured out that value 3 is for turning it off
        //(though there is no enum value for it).
#ifdef __IPHONE_5_0
        [newScreen setOverscanCompensation:(UIScreenOverscanCompensation)3];
#else
        [newScreen setOverscanCompensation:3];
#endif
        CLog::Log(LOGDEBUG, "[IOSScreenManager] Disabling overscancompensation.");
      }
      else
      {
        CLog::Log(LOGDEBUG, "[IOSScreenManager] Disabling overscancompensation not supported on this iOS version.");
      }

      [[MainScreenManager sharedInstance] fadeFromBlack:timeSwitchingToExternalSecs];
    }
    else
    {
      [[MainScreenManager sharedInstance] fadeFromBlack:timeSwitchingToInternalSecs];
    }

    int w = [[newScreen currentMode] size].width;
    int h = [[newScreen currentMode] size].height;
    NSLog(@"Switched to screen %i with %i x %i",screenIdx, w ,h);
}
//--------------------------------------------------------------
// - will fade current screen to black
// - change mode and screen
// - optionally activate external touchscreen controller when
// switching to external screen
// - fade back from black
- (void) changeScreenSelector:(NSDictionary *)dict
{
  int screenIdx = [[dict objectForKey:@"screenIdx"] intValue];
  UIScreenMode *mode = [dict objectForKey:@"screenMode"];

  [UIView animateWithDuration:timeFadeSecs delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
    [_glView setAlpha:0.0];
  }
  completion:^(BOOL finished)
  {
    [self setScreen:screenIdx withMode:mode];
  }];
}
//--------------------------------------------------------------
- (bool) changeScreen: (unsigned int)screenIdx withMode:(UIScreenMode *)mode
{
  //screen has changed - get the new screen
  if(screenIdx >= [[UIScreen screens] count])
    return false;

  //if we are about to switch to current screen
  //with current mode - don't do anything
  if(screenIdx == _screenIdx &&
    mode == (UIScreenMode *)[[[UIScreen screens] objectAtIndex:screenIdx] currentMode])
    return true;

  //put the params into a dict
  NSNumber *idx = [NSNumber numberWithInt:screenIdx];
  NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:mode, @"screenMode",
                                                                  idx,  @"screenIdx", nil];


  CLog::Log(LOGINFO, "Changing screen to %d with %f x %f",screenIdx,[mode size].width, [mode size].height);
  //ensure that the screen change is done in the mainthread
  if([NSThread currentThread] != [NSThread mainThread])
  {
    [self performSelectorOnMainThread:@selector(changeScreenSelector:) withObject:dict  waitUntilDone:YES];
    screenChangeEvent.WaitMSec(30000);
  }
  else
  {
    [self changeScreenSelector:dict];
  }

  // re-enumerate audio devices in that case too
  // as we might gain passthrough capabilities via HDMI
  CAEFactory::DeviceChange();
  return true;
}
//--------------------------------------------------------------
+ (CGRect) getLandscapeResolution:(UIScreen *)screen
{
  CGRect res = [screen bounds];
  #if __IPHONE_8_0
  if (CDarwinUtils::GetIOSVersion() < 8.0)
  #endif
  {
    //main screen is in portrait mode (physically) so exchange height and width
    //at least when compiled with ios sdk < 8.0 (seems to be fixed in later sdks)
    if(screen == [UIScreen mainScreen])
    {
      CGRect frame = res;
      res.size = CGSizeMake(frame.size.height, frame.size.width);
    }
  }
  return res;
}
//--------------------------------------------------------------
- (void) screenDisconnect
{
  //if we are on external screen and he was disconnected
  //change back to internal screen
  if([[UIScreen screens] count] == 1 && _screenIdx != 0)
  {
    RESOLUTION_INFO res = CDisplaySettings::GetInstance().GetResolutionInfo(RES_DESKTOP);//internal screen default res
    g_Windowing.SetFullScreen(true, res, false);
  }
}
//--------------------------------------------------------------
+ (void) updateResolutions
{
  g_Windowing.UpdateResolutions();
}
//--------------------------------------------------------------
- (void) dealloc
{
  [super dealloc];
}
//--------------------------------------------------------------
+ (id) sharedInstance
{
	static MainScreenManager* sharedManager = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
   sharedManager = [[self alloc] init];
	});
	return sharedManager;
}
@end
