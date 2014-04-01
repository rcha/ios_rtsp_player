//
//  YUVDisplayGLViewController.m
//  rtsp_player
//
//  Created by J.C. Li on 11/17/12.
//  Copyright (c) 2012 J.C. Li. All rights reserved.
//

#import "YUVDisplayGLViewController.h"
#import <QuartzCore/QuartzCore.h>
#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>

typedef struct {
    float Position[3];
    float Color[4];
    float TexCoord[2];
} Vertex;

const Vertex Vertices[] = {
    {{1, -1, 0}, {1, 1, 1, 1}, {1, 1}},
    {{1, 1, 0}, {1, 1, 1, 1}, {1, 0}},
    {{-1, 1, 0}, {1, 1, 1, 1}, {0, 0}},
    {{-1, -1, 0}, {1, 1, 1, 1}, {0, 1}}
};

const GLubyte Indices[] = {
    0, 1, 2,
    2, 3, 0
};

#pragma mark - shaders

#define STRINGIZE(x) #x
#define STRINGIZE2(x) STRINGIZE(x)
#define SHADER_STRING(text) @ STRINGIZE2(text)

NSString *const vertexShaderString = SHADER_STRING
(
 attribute vec4 Position; // 1
 attribute vec4 SourceColor; // 2
 
 varying vec4 DestinationColor; // 3
 
 attribute vec2 TexCoordIn;
 varying vec2 TexCoordOut;
 
 
 void main(void) { // 4
     DestinationColor = SourceColor; // 5
     gl_Position = Position; // 6
     TexCoordOut = TexCoordIn; // New
 }
);

NSString *const rgbFragmentShaderString = SHADER_STRING
(
 precision highp float;
 
 varying highp vec2 TexCoordOut;
 uniform sampler2D s_texture_y;
 uniform sampler2D s_texture_u;
 uniform sampler2D s_texture_v;
 
 uniform sampler2D s_texture_lut;
 uniform float lut_size;
 uniform float lut_scale;
 uniform float lut_offset;
 uniform float lut_split_position;
 
 void main()
 {
     highp float y = texture2D(s_texture_y, TexCoordOut).r;
     highp float u = texture2D(s_texture_u, TexCoordOut).r - 0.5;
     highp float v = texture2D(s_texture_v, TexCoordOut).r - 0.5;
     
     highp float r = y +             1.402 * v;
     highp float g = y - 0.344 * u - 0.714 * v;
     highp float b = y + 1.772 * u;
     
     if (lut_size > 0.0 && TexCoordOut.x <= lut_split_position) {
         vec3 c = vec3(r, g, b);
         c = clamp(c, 0.0, 1.0);
         c = vec3(lut_scale * c.rg + lut_offset, c.b);
         
         float cb_sc = c.b * (lut_size - 1.0);
         float y1 = (c.g + floor(cb_sc))/lut_size;
         float y2 = y1 + 1.0/lut_size;
         
         vec3 out_color1 = texture2D(s_texture_lut, vec2(c.r, y1)).rgb;
         vec3 out_color2 = texture2D(s_texture_lut, vec2(c.r, y2)).rgb;
         vec3 out_color = mix(out_color1, out_color2, (cb_sc - floor(cb_sc)));
         
         gl_FragColor = vec4(out_color,1.0);
     } else {
         gl_FragColor = vec4(r,g,b,1.0);
     }
 }
);


#pragma mark - YUVDisplayGLViewController implementation

@interface YUVDisplayGLViewController(){
    float _curRed;
    BOOL _increasing;
    
    float _pixelAspectRatio;
    
    GLuint _vertexBuffer;
    GLuint _indexBuffer;
    
    GLuint _positionSlot;
    GLuint _colorSlot;
    
    uint16_t _textureWidth;
    uint16_t _textureHeight;
    GLuint _yTexture;
    GLuint _uTexture;
    GLuint _vTexture;
    GLuint _texCoordSlot;
    GLuint _yTextureUniform;
    GLuint _uTextureUniform;
    GLuint _vTextureUniform;
    
    GLuint _lutTexture;
    GLuint _lutTextureUniform;
    GLfloat _lutSize;
    GLfloat _lutScale;
    GLfloat _lutOffset;
    GLfloat _lutSplitPosition;
    GLuint _lutSizeUniform;
    GLuint _lutScaleUniform;
    GLuint _lutOffsetUniform;
    GLuint _lutSplitPositionUniform;
    
    dispatch_semaphore_t _textureUpdateRenderSemaphore;

}

@property (strong, nonatomic) EAGLContext *context;
@property (strong, nonatomic) NSData *testYUVInputData;

@end

@implementation YUVDisplayGLViewController
@synthesize context = _context;
@synthesize testYUVInputData = _testYUVInputData;

- (void) awakeFromNib
{
    [super awakeFromNib];
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // Custom initialization
    }
    return self;
}


- (void)setupGL
{
    
    [EAGLContext setCurrentContext:self.context];
    
    glGenBuffers(1, &_vertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, _vertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Vertices), Vertices, GL_STATIC_DRAW);
    
    glGenBuffers(1, &_indexBuffer);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(Indices), Indices, GL_STATIC_DRAW);
    
    // init the update render semaphore
    _textureUpdateRenderSemaphore = dispatch_semaphore_create((long)1);
    
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view.
    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    
    if (!self.context) {
        NSLog(@"Failed to create ES context");
    }
    
    GLKView *view = (GLKView *)self.view;
    view.context = self.context;
    
    [self setupGL];
    [self compileShaders];
    
    // setup the textures
    _textureWidth = 1280;
    _textureHeight = 720;
    _pixelAspectRatio = 1;
    _yTexture = [self setupTexture:nil width:_textureWidth height:_textureHeight textureIndex:0];
    _uTexture = [self setupTexture:nil width:_textureWidth/2 height:_textureHeight/2 textureIndex:1];
    _vTexture = [self setupTexture:nil width:_textureWidth/2 height:_textureHeight/2 textureIndex:2];
    
    // setup LUT texture
    _lutTexture = [self setupLut:nil size:0];
    
    _lutSplitPosition = 2.0;
    
    [self setPauseOnWillResignActive:YES];
}

- (void)tearDownGL {
    
    [EAGLContext setCurrentContext:self.context];
    
    glDeleteBuffers(1, &_vertexBuffer);
    glDeleteBuffers(1, &_indexBuffer);
    
    glDeleteTextures(1, &_yTexture);
    glDeleteTextures(1, &_uTexture);
    glDeleteTextures(1, &_vTexture);
    
    glDeleteTextures(1, &_lutTexture);
}

-(void)viewDidUnload
{
    [super viewDidUnload];
    if ([EAGLContext currentContext] == self.context) {
        [EAGLContext setCurrentContext:nil];
    }
    self.context = nil;
    
    [self tearDownGL];
}
- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - texture setup

- (void) updateTexture: (char*)textureData width:(uint) width height:(uint) height textureIndex:(GLuint)index
{
    long renderStatus = dispatch_semaphore_wait(_textureUpdateRenderSemaphore, DISPATCH_TIME_NOW);
    if (renderStatus==0){
        GLubyte *glTextureData;
        if (textureData){
            glTextureData = (GLubyte*)(textureData);
        }else{
            glTextureData = (GLubyte *) malloc(width*height);
            if (index == 0)
                memset(glTextureData, 0x10, width*height);
            else
                memset(glTextureData, 0x80, width*height);
        }
        glActiveTexture(GL_TEXTURE0+index);
        //        glBindTexture(GL_TEXTURE_2D, texName);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, width, height, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, glTextureData);
        
        if (!textureData){
            free(glTextureData);
        }
        dispatch_semaphore_signal(_textureUpdateRenderSemaphore);
    }
}
- (void) updateLut: (char*)textureData size:(uint) size
{
    long renderStatus = dispatch_semaphore_wait(_textureUpdateRenderSemaphore, DISPATCH_TIME_NOW);
    if (renderStatus==0){
        GLubyte *glTextureData;
        
        if (size > 1) {
            if (textureData) {
                glTextureData = (GLubyte*)(textureData);
            } else {
                glTextureData = (GLubyte *) malloc(size*size*size*4);
                for (int r = 0; r < size; r++) {
                    for (int g = 0; g < size; g++) {
                        for (int b = 0; b < size; b++) {
                            int offs = ((b*size+g)*size+r)*4;
                            glTextureData[offs] = (float)r/(size-1)*255;
                            glTextureData[offs+1] = (float)g/(size-1)*255;
                            glTextureData[offs+2] = (float)b/(size-1)*255;
                            glTextureData[offs+3] = 255;
                        }
                    }
                }
            }
            glActiveTexture(GL_TEXTURE0+3);
            //glPixelStorei(GL_PACK_ALIGNMENT, 1);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, size, size*size, 0, GL_RGBA, GL_UNSIGNED_BYTE, glTextureData);
            
            if (!textureData){
                free(glTextureData);
            }
            
            _lutSize = size;
            _lutScale = (_lutSize - 1.0)/_lutSize;
            _lutOffset = 1.0/(2.0*_lutSize);
        } else {
            _lutSize = -1;
        }
        
        dispatch_semaphore_signal(_textureUpdateRenderSemaphore);
    }
}

- (void) updateLutSplitPosition: (float)position
{
    // position = 0.0 (most frame is without LUT correction) .. 1.0 (all frame with LUT correction)
    _lutSplitPosition = position;
}

- (GLuint)setupTexture:(char *)textureData width:(uint) width height:(uint) height textureIndex:(GLuint) index
{
    GLuint texName;
    
    glGenTextures(1, &texName);
    glActiveTexture(GL_TEXTURE0+index);
    glBindTexture(GL_TEXTURE_2D, texName);
    
    [self updateTexture:textureData width:width height:height textureIndex:index];
    
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    return texName;
}

- (GLuint)setupLut:(char *)textureData size:(uint) size
{
    GLuint texName;
    
    glGenTextures(1, &texName);
    glActiveTexture(GL_TEXTURE0+3);
    glBindTexture(GL_TEXTURE_2D, texName);
    
    [self updateLut:textureData size:size];
    
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    return texName;
}

#pragma mark - compile and load shaders

- (GLuint)compileShader:(NSString*)shaderString withType:(GLenum)shaderType
{
    GLuint shaderHandle = glCreateShader(shaderType);
    if (shaderHandle == 0 || shaderHandle == GL_INVALID_ENUM) {
        NSLog(@"Failed to create shader %d", shaderType);
        exit(1);
    }
    // 3
    const char * shaderStringUTF8 = [shaderString UTF8String];
    int shaderStringLength = [shaderString length];
    glShaderSource(shaderHandle, 1, &shaderStringUTF8, &shaderStringLength);
    
    // 4
    glCompileShader(shaderHandle);
    
    // 5
    GLint compileSuccess;
    glGetShaderiv(shaderHandle, GL_COMPILE_STATUS, &compileSuccess);
    if (compileSuccess == GL_FALSE) {
        GLchar messages[256];
        glGetShaderInfoLog(shaderHandle, sizeof(messages), 0, &messages[0]);
        NSString *messageString = [NSString stringWithUTF8String:messages];
        NSLog(@"%@", messageString);
        exit(1);
    }
    
    return shaderHandle;
}

- (void) compileShaders
{
    GLuint vertexShader = [self compileShader:vertexShaderString
                                     withType:GL_VERTEX_SHADER];
    GLuint fragmentShader = [self compileShader:rgbFragmentShaderString
                                       withType:GL_FRAGMENT_SHADER];
    
    GLuint programHandle = glCreateProgram();
    glAttachShader(programHandle, vertexShader);
    glAttachShader(programHandle, fragmentShader);
    glLinkProgram(programHandle);
    
    GLint linkSuccess;
    glGetProgramiv(programHandle, GL_LINK_STATUS, &linkSuccess);
    if (linkSuccess == GL_FALSE) {
        GLchar messages[256];
        glGetProgramInfoLog(programHandle, sizeof(messages), 0, &messages[0]);
        NSString *messageString = [NSString stringWithUTF8String:messages];
        NSLog(@"%@", messageString);
        exit(1);
    }
    
    glUseProgram(programHandle);
    
    _positionSlot = glGetAttribLocation(programHandle, "Position");
    _colorSlot = glGetAttribLocation(programHandle, "SourceColor");
    glEnableVertexAttribArray(_positionSlot);
    glEnableVertexAttribArray(_colorSlot);
    
    // set the shader slots
    _texCoordSlot = glGetAttribLocation(programHandle, "TexCoordIn");
    glEnableVertexAttribArray(_texCoordSlot);
    _yTextureUniform = glGetUniformLocation(programHandle, "s_texture_y");
    _uTextureUniform = glGetUniformLocation(programHandle, "s_texture_u");
    _vTextureUniform = glGetUniformLocation(programHandle, "s_texture_v");
    _yTexture = 0;
    _uTexture = 0;
    _vTexture = 0;
    
    _lutTextureUniform = glGetUniformLocation(programHandle, "s_texture_lut");
    _lutTexture = 0;
    _lutSizeUniform = glGetUniformLocation(programHandle, "lut_size");
    _lutScaleUniform = glGetUniformLocation(programHandle, "lut_scale");
    _lutOffsetUniform = glGetUniformLocation(programHandle, "lut_offset");
    _lutSplitPositionUniform = glGetUniformLocation(programHandle, "lut_split_position");
}

#pragma mark - render code
- (void) setGLViewportToScale
{
    CGFloat scaleFactor = [[UIScreen mainScreen] scale];
    if (_pixelAspectRatio < 0.0000001)
        _pixelAspectRatio = 1;
    if (_textureHeight!=0 && _textureWidth!=0){
        float targetRatio = _textureWidth/(_textureHeight*1.0)*_pixelAspectRatio;
        float viewRatio = self.view.bounds.size.width/(self.view.bounds.size.height*1.0);
        uint16_t x,y,width,height;
        if (targetRatio>viewRatio){
            width=self.view.bounds.size.width*scaleFactor;
            height=width/targetRatio;
            x=0;
            y=(self.view.bounds.size.height*scaleFactor-height)/2;
            
        }else{
            height=self.view.bounds.size.height*scaleFactor;
            width = height*targetRatio;
            y=0;
            x=(self.view.bounds.size.width*scaleFactor-width)/2;
        }
         glViewport(x,y,width,height);
    }else{
        glViewport(self.view.bounds.origin.x, self.view.bounds.origin.y,
                   self.view.bounds.size.width*scaleFactor, self.view.bounds.size.height*scaleFactor);
    }
}

- (void)render
{
    [EAGLContext setCurrentContext:self.context];

    [self setGLViewportToScale];
    
    glVertexAttribPointer(_positionSlot, 3, GL_FLOAT, GL_FALSE,
                          sizeof(Vertex), 0);
    glVertexAttribPointer(_colorSlot, 4, GL_FLOAT, GL_FALSE,
                          sizeof(Vertex), (GLvoid*) (sizeof(float) * 3));
    
    // load the texture
    glVertexAttribPointer(_texCoordSlot, 2, GL_FLOAT, GL_FALSE,
                          sizeof(Vertex), (GLvoid*) (sizeof(float) * 7));
    
//    glActiveTexture(GL_TEXTURE0);
//    glBindTexture(GL_TEXTURE_2D, _yTexture);
    glUniform1i(_yTextureUniform, 0);
    
//    glActiveTexture(GL_TEXTURE0+1);
//    glBindTexture(GL_TEXTURE_2D, _uTexture);
    glUniform1i(_uTextureUniform, 1);
    
//    glActiveTexture(GL_TEXTURE0+2);
//    glBindTexture(GL_TEXTURE_2D, _vTexture);
    glUniform1i(_vTextureUniform, 2);
    
    glUniform1i(_lutTextureUniform, 3);
    glUniform1f(_lutSizeUniform, _lutSize);
    glUniform1f(_lutScaleUniform, _lutScale);
    glUniform1f(_lutOffsetUniform, _lutOffset);
    glUniform1f(_lutSplitPositionUniform, _lutSplitPosition);
    
    // draw
    glDrawElements(GL_TRIANGLES, sizeof(Indices)/sizeof(Indices[0]),
                   GL_UNSIGNED_BYTE, 0);
    
    [self.context presentRenderbuffer:GL_RENDERBUFFER];
}


#pragma mark - loading the texture data

- (int) loadFrameData:(AVFrameData)frameData
{
    if (/*frameData && */self.context){
            
        
        [EAGLContext setCurrentContext:self.context];
//        if (!_yTexture){
//            _yTexture = [self setupTexture:frameData.colorPlane0 width:frameData.width.intValue height:frameData.height.intValue textureIndex:0];
//        }else{
//            [self updateTexture:frameData.colorPlane0 width:frameData.width.intValue height:frameData.height.intValue textureName:_yTexture textureIndex:0];
//        }
//        if (!_uTexture){
//            _uTexture = [self setupTexture:frameData.colorPlane1 width:frameData.width.intValue/2 height:frameData.height.intValue/2 textureIndex:1];
//        }else{
//            [self updateTexture:frameData.colorPlane1 width:frameData.width.intValue/2 height:frameData.height.intValue/2 textureName:_uTexture textureIndex:1];
//        }
//        if (!_vTexture){
//            _vTexture = [self setupTexture:frameData.colorPlane2 width:frameData.width.intValue/2 height:frameData.height.intValue/2 textureIndex:2];
//        }else{
//            [self updateTexture:frameData.colorPlane2 width:frameData.width.intValue/2 height:frameData.height.intValue/2 textureName:_vTexture textureIndex:2];
//        }
        if (_yTexture && _uTexture && _vTexture){
            [self updateTexture:frameData.colorPlane0 width:frameData.width height:frameData.height textureIndex:0];
            [self updateTexture:frameData.colorPlane1 width:frameData.width/2 height:frameData.height/2 textureIndex:1];
            [self updateTexture:frameData.colorPlane2 width:frameData.width/2 height:frameData.height/2 textureIndex:2];
            _textureWidth = frameData.width;
            _textureHeight = frameData.height;
        }
        _pixelAspectRatio = frameData.pixelAspectRatio;
        return 0;
    }else{
        return -1;
    }
}

#pragma mark - GLKViewDelegate

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    [self setPaused:NO];
    long textureUpdateStatus = dispatch_semaphore_wait(_textureUpdateRenderSemaphore, DISPATCH_TIME_NOW);
    if (textureUpdateStatus==0){
        glClearColor(0.0, 0.0, 0.0, 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        [self render];
        dispatch_semaphore_signal(_textureUpdateRenderSemaphore);
    }
}

#pragma mark - GLKViewControllerDelegate

- (void) update
{
    if (_increasing) {
        _curRed += 1.0 * self.timeSinceLastUpdate;
    } else {
        _curRed -= 1.0 * self.timeSinceLastUpdate;
    }
    if (_curRed >= 1.0) {
        _curRed = 1.0;
        _increasing = NO;
    }
    if (_curRed <= 0.0) {
        _curRed = 0.0;
        _increasing = YES;
    }
}

@end
