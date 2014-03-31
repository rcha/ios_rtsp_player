//
//  YUVDisplayGLViewController.h
//  rtsp_player
//
//  Created by J.C. Li on 11/17/12.
//  Copyright (c) 2012 J.C. Li. All rights reserved.
//

#import <GLKit/GLKit.h>
#import "../../../TeraPlayer/FfmpegWrapper.h"

@interface YUVDisplayGLViewController : GLKViewController

-(int) loadFrameData: (AVFrameData) frameData;
- (void) updateLut: (char*)textureData size:(uint) size;

@end
