

//
//  IPDFCameraViewController.m
//  InstaPDF
//
//  Created by Maximilian Mackh on 06/01/15.
//  Copyright (c) 2015 mackh ag. All rights reserved.
//

#import "IPDFCameraViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <GLKit/GLKit.h>

@interface IPDFRectangleFeature : NSObject

@property (nonatomic, assign) CGPoint topLeft;
@property (nonatomic, assign) CGPoint topRight;
@property (nonatomic, assign) CGPoint bottomRight;
@property (nonatomic, assign) CGPoint bottomLeft;

@end

@implementation IPDFRectangleFeature

@end

@interface IPDFCameraViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureDevice *captureDevice;
@property (nonatomic, strong) EAGLContext *context;

@property (nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;

@property (nonatomic, assign) BOOL forceStop;
@property (nonatomic, assign) CGSize intrinsicContentSize;
@property (atomic) CGRect cachedBounds;

@end

@implementation IPDFCameraViewController {
    CIContext *_coreImageContext;
    GLuint _renderBuffer;
    GLKView *_glkView;

    BOOL _isStopped;

    CGFloat _imageDedectionConfidence;
    NSTimer *_borderDetectTimeKeeper;
    BOOL _borderDetectFrame;
    CIRectangleFeature *_borderDetectLastRectangleFeature;

    CGFloat _confidenceLevl;
    BOOL _isCapturing;
}

- (void)awakeFromNib {
    [super awakeFromNib];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backgroundMode) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_foregroundMode) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)_backgroundMode {
    self.forceStop = YES;
}

- (void)_foregroundMode {
    self.forceStop = NO;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)createGLKView {
    if (self.context) return;

    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    GLKView *view = [[GLKView alloc] initWithFrame:self.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.context = self.context;
    view.contentScaleFactor = 1.0;
    view.drawableDepthFormat = GLKViewDrawableDepthFormat24;
    [self insertSubview:view atIndex:0];
    _glkView = view;
    glGenRenderbuffers(1, &_renderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderBuffer);
    _coreImageContext = [CIContext contextWithEAGLContext:self.context];
    [EAGLContext setCurrentContext:self.context];
}

- (void)setupCameraView {
    [self createGLKView];

    NSArray *possibleDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    AVCaptureDevice *device = [possibleDevices firstObject];
    if (!device) return;

    _imageDedectionConfidence = 0.0;

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    session.sessionPreset = AVCaptureSessionPresetPhoto;
    [session beginConfiguration];

    self.captureSession = session;
    self.captureDevice = device;

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    session.sessionPreset = AVCaptureSessionPresetPhoto;
    [session addInput:input];

    AVCaptureVideoDataOutput *dataOutput = [[AVCaptureVideoDataOutput alloc] init];
    dataOutput.alwaysDiscardsLateVideoFrames = YES;
    dataOutput.videoSettings = @{
        (NSString *) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    [dataOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    [session addOutput:dataOutput];

    self.stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
    self.stillImageOutput.outputSettings = @{
        AVVideoCodecKey: AVVideoCodecJPEG,
        AVVideoQualityKey: [NSNumber numberWithInteger:1.0]
    };
    [session addOutput:self.stillImageOutput];

    AVCaptureConnection *connection = [dataOutput.connections firstObject];
    [connection setVideoOrientation:AVCaptureVideoOrientationPortrait];

    if (device.isFlashAvailable) {
        [device lockForConfiguration:nil];
        [device setFlashMode:AVCaptureFlashModeOff];
        [device unlockForConfiguration];

        if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            [device lockForConfiguration:nil];
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
            [device unlockForConfiguration];
        }
    }

    [session commitConfiguration];
}

- (void)setCameraViewType:(IPDFCameraViewType)cameraViewType {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *viewWithBlurredBackground = [[UIVisualEffectView alloc] initWithEffect:effect];
    viewWithBlurredBackground.frame = self.bounds;
    [self insertSubview:viewWithBlurredBackground aboveSubview:_glkView];

    _cameraViewType = cameraViewType;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [viewWithBlurredBackground removeFromSuperview];
    });
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (self.forceStop) return;
    if (_isStopped || _isCapturing || !CMSampleBufferIsValid(sampleBuffer)) return;

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef) CMSampleBufferGetImageBuffer(sampleBuffer);

    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];

    if (self.cameraViewType != IPDFCameraViewTypeNormal) {
        image = [self filteredImageUsingEnhanceFilterOnImage:image];
    } else {
        image = [self filteredImageUsingContrastFilterOnImage:image];
    }

    //if (self.isBorderDetectionEnabled) {
    if (_borderDetectFrame) {
        _confidenceLevl = _imageDedectionConfidence;
        _borderDetectLastRectangleFeature = [self biggestRectangleInRectangles:[[self highAccuracyRectangleDetector] featuresInImage:image]];
        _borderDetectFrame = NO;
    }

    if (_borderDetectLastRectangleFeature) {
        _imageDedectionConfidence += 0.5;

        image = [self drawHighlightOverlayForPoints:image topLeft:_borderDetectLastRectangleFeature.topLeft topRight:_borderDetectLastRectangleFeature.topRight bottomLeft:_borderDetectLastRectangleFeature.bottomLeft bottomRight:_borderDetectLastRectangleFeature.bottomRight];
    } else {
        _imageDedectionConfidence = 0.0;
    }
    //}

    if (self.context && _coreImageContext) {
        if (_context != [EAGLContext currentContext]) {
            [EAGLContext setCurrentContext:_context];
        }
        [_glkView bindDrawable];
        [_coreImageContext drawImage:image inRect:self.cachedBounds fromRect:[self cropRectForPreviewImage:image]];
        [_glkView display];

        if (_intrinsicContentSize.width != image.extent.size.width) {
            self.intrinsicContentSize = image.extent.size;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self invalidateIntrinsicContentSize];
            });
        }

        image = nil;
    }
}

- (CGSize)intrinsicContentSize {
    if (_intrinsicContentSize.width == 0 || _intrinsicContentSize.height == 0) {
        return CGSizeMake(1.0, 1.0);
    }
    return _intrinsicContentSize;
}

- (CGRect)cropRectForPreviewImage:(CIImage *)image {
    CGFloat cropWidth = image.extent.size.width;
    CGFloat cropHeight = image.extent.size.height;
    if (image.extent.size.width > image.extent.size.height) {
        cropWidth = image.extent.size.width;
        cropHeight = cropWidth * self.cachedBounds.size.height / self.cachedBounds.size.width;
    } else if (image.extent.size.width < image.extent.size.height) {
        cropHeight = image.extent.size.height;
        cropWidth = cropHeight * self.cachedBounds.size.width / self.cachedBounds.size.height;
    }
    return CGRectInset(image.extent, (image.extent.size.width - cropWidth) / 2, (image.extent.size.height - cropHeight) / 2);
}

- (void)enableBorderDetectFrame {
    _borderDetectFrame = YES;
}

- (CIImage *)drawHighlightOverlayForPoints:(CIImage *)image topLeft:(CGPoint)topLeft topRight:(CGPoint)topRight bottomLeft:(CGPoint)bottomLeft bottomRight:(CGPoint)bottomRight {
    CIImage *overlay;
    if (_confidenceLevl > 50) {
        overlay = [CIImage imageWithColor:[CIColor colorWithRed:0.00 green:0.50 blue:0.00 alpha:0.30]];
    } else {
        overlay = [CIImage imageWithColor:[CIColor colorWithRed:1.00 green:0.80 blue:0.18 alpha:0.30]];
    }

    overlay = [overlay imageByCroppingToRect:image.extent];
    overlay = [overlay imageByApplyingFilter:@"CIPerspectiveTransformWithExtent"
                         withInputParameters:@{ @"inputExtent": [CIVector vectorWithCGRect:image.extent],
                                                @"inputTopLeft": [CIVector vectorWithCGPoint:topLeft],
                                                @"inputTopRight": [CIVector vectorWithCGPoint:topRight],
                                                @"inputBottomLeft": [CIVector vectorWithCGPoint:bottomLeft],
                                                @"inputBottomRight": [CIVector vectorWithCGPoint:bottomRight] }];

    return [overlay imageByCompositingOverImage:image];
}

- (void)start {
    _isStopped = NO;
    _isCapturing = NO;

    [self.captureSession startRunning];

    _borderDetectTimeKeeper = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(enableBorderDetectFrame) userInfo:nil repeats:YES];

    [self hideGLKView:NO completion:nil];
}

- (void)stop {
    _isStopped = YES;
    _isCapturing = YES;

    [self.captureSession stopRunning];

    [_borderDetectTimeKeeper invalidate];

    [self hideGLKView:YES completion:nil];
}

- (void)setEnableTorch:(BOOL)enableTorch {
    _enableTorch = enableTorch;

    AVCaptureDevice *device = self.captureDevice;
    if ([device hasTorch] && [device hasFlash]) {
        [device lockForConfiguration:nil];
        if (enableTorch) {
            [device setTorchMode:AVCaptureTorchModeOn];
        } else {
            [device setTorchMode:AVCaptureTorchModeOff];
        }
        [device unlockForConfiguration];
    }
}

- (void)focusAtPoint:(CGPoint)point completionHandler:(void (^)(void))completionHandler {
    AVCaptureDevice *device = self.captureDevice;
    CGPoint pointOfInterest = CGPointZero;
    CGSize frameSize = self.bounds.size;
    pointOfInterest = CGPointMake(point.y / frameSize.height, 1.0 - (point.x / frameSize.width));

    if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        NSError *error;
        if ([device lockForConfiguration:&error]) {
            if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
                [device setFocusPointOfInterest:pointOfInterest];
            }

            if ([device isExposurePointOfInterestSupported] && [device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                [device setExposurePointOfInterest:pointOfInterest];
                [device setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
                completionHandler();
            }

            [device unlockForConfiguration];
        }
    } else {
        completionHandler();
    }
}

- (void)captureImageWithCompletionHander:(void (^)(UIImage *image, CGFloat confidenceeLevel))completionHandler {
    if (_isCapturing) return;

    __weak typeof(self) weakSelf = self;

    [weakSelf hideGLKView:YES
               completion:^{
                   [weakSelf hideGLKView:NO
                              completion:^{
                                  [weakSelf hideGLKView:YES completion:nil];
                              }];
               }];

    _isCapturing = YES;

    AVCaptureConnection *videoConnection = nil;
    for (AVCaptureConnection *connection in self.stillImageOutput.connections) {
        for (AVCaptureInputPort *port in [connection inputPorts]) {
            if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
                videoConnection = connection;
                break;
            }
        }
        if (videoConnection) break;
    }

    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:videoConnection
                                                       completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
                                                           if (error) {
                                                               return;
                                                           }

                                                           @autoreleasepool {
                                                               NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];
                                                               CIImage *enhancedImage = [[CIImage alloc] initWithData:imageData options:@{kCIImageColorSpace: [NSNull null]}];
                                                               imageData = nil;

                                                               if (weakSelf.cameraViewType == IPDFCameraViewTypeBlackAndWhite) {
                                                                   enhancedImage = [self filteredImageUsingEnhanceFilterOnImage:enhancedImage];
                                                               } else {
                                                                   enhancedImage = [self filteredImageUsingContrastFilterOnImage:enhancedImage];
                                                               }

                                                               /*
                                                               if (weakSelf.isBorderDetectionEnabled && rectangleDetectionConfidenceHighEnough(_imageDedectionConfidence)) {
                                                                   CIRectangleFeature *rectangleFeature = [self biggestRectangleInRectangles:[[self highAccuracyRectangleDetector] featuresInImage:enhancedImage]];
                                                                
                                                                   if (rectangleFeature) {
                                                                       enhancedImage = [self correctPerspectiveForImage:enhancedImage withFeatures:rectangleFeature];
                                                                   }
                                                               }
                                                               */

                                                               if (rectangleDetectionConfidenceHighEnough(_imageDedectionConfidence)) {
                                                                   CIRectangleFeature *rectangleFeature = [self biggestRectangleInRectangles:[[self highAccuracyRectangleDetector] featuresInImage:enhancedImage]];

                                                                   if (rectangleFeature) {
                                                                       enhancedImage = [self correctPerspectiveForImage:enhancedImage withFeatures:rectangleFeature];
                                                                   }
                                                               }

                                                               CIFilter *transform = [CIFilter filterWithName:@"CIAffineTransform"];
                                                               [transform setValue:enhancedImage forKey:kCIInputImageKey];
                                                               NSValue *rotation = [NSValue valueWithCGAffineTransform:CGAffineTransformMakeRotation(-90 * (M_PI / 180))];
                                                               [transform setValue:rotation forKey:@"inputTransform"];
                                                               enhancedImage = [transform outputImage];

                                                               if (!enhancedImage || CGRectIsEmpty(enhancedImage.extent)) return;

                                                               static CIContext *ctx = nil;
                                                               if (!ctx) {
                                                                   ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: [NSNull null]}];
                                                               }

                                                               CGSize bounds = enhancedImage.extent.size;
                                                               bounds = CGSizeMake(floorf(bounds.width / 4) * 4, floorf(bounds.height / 4) * 4);
                                                               CGRect extent = CGRectMake(enhancedImage.extent.origin.x, enhancedImage.extent.origin.y, bounds.width, bounds.height);

                                                               static int bytesPerPixel = 8;
                                                               uint rowBytes = bytesPerPixel * bounds.width;
                                                               uint totalBytes = rowBytes * bounds.height;
                                                               uint8_t *byteBuffer = malloc(totalBytes);

                                                               CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

                                                               [ctx render:enhancedImage toBitmap:byteBuffer rowBytes:rowBytes bounds:extent format:kCIFormatRGBA8 colorSpace:colorSpace];

                                                               CGContextRef bitmapContext = CGBitmapContextCreate(byteBuffer, bounds.width, bounds.height, bytesPerPixel, rowBytes, colorSpace, kCGImageAlphaNoneSkipLast);
                                                               CGImageRef imgRef = CGBitmapContextCreateImage(bitmapContext);
                                                               CGColorSpaceRelease(colorSpace);
                                                               CGContextRelease(bitmapContext);
                                                               free(byteBuffer);

                                                               if (imgRef == NULL) {
                                                                   CFRelease(imgRef);
                                                                   return;
                                                               }

                                                               UIImage *useImage = [UIImage imageWithCGImage:imgRef];
                                                               CFRelease(imgRef);

                                                               completionHandler(useImage, _confidenceLevl);

                                                               _imageDedectionConfidence = 0.0;
                                                               _confidenceLevl = _imageDedectionConfidence;
                                                           }
                                                       }];
}

- (void)hideGLKView:(BOOL)hidden completion:(void (^)(void))completion {
    [UIView animateWithDuration:0.1
        animations:^{
            _glkView.alpha = (hidden) ? 0.0 : 1.0;
        }
        completion:^(BOOL finished) {
            if (!completion) return;
            completion();
        }];
}

- (CIImage *)filteredImageUsingEnhanceFilterOnImage:(CIImage *)image {
    return [CIFilter filterWithName:@"CIColorControls"
                      keysAndValues:kCIInputImageKey, image,
                                    @"inputSaturation", [NSNumber numberWithFloat:0.0],
                                    @"inputBrightness", [NSNumber numberWithFloat:0.0],
                                    @"inputContrast", [NSNumber numberWithFloat:1.14], nil]
        .outputImage;
}

- (CIImage *)filteredImageUsingContrastFilterOnImage:(CIImage *)image {
    return [CIFilter filterWithName:@"CIColorControls"
                withInputParameters:@{
                    @"inputSaturation": [NSNumber numberWithFloat:1.14],
                    @"inputBrightness": [NSNumber numberWithFloat:0.0],
                    @"inputContrast": [NSNumber numberWithFloat:1.14],
                    kCIInputImageKey: image
                }]
        .outputImage;
}

- (CIImage *)correctPerspectiveForImage:(CIImage *)image withFeatures:(CIRectangleFeature *)rectangleFeature {
    NSMutableDictionary *rectangleCoordinates = [NSMutableDictionary new];
    rectangleCoordinates[@"inputTopLeft"] = [CIVector vectorWithCGPoint:rectangleFeature.topLeft];
    rectangleCoordinates[@"inputTopRight"] = [CIVector vectorWithCGPoint:rectangleFeature.topRight];
    rectangleCoordinates[@"inputBottomLeft"] = [CIVector vectorWithCGPoint:rectangleFeature.bottomLeft];
    rectangleCoordinates[@"inputBottomRight"] = [CIVector vectorWithCGPoint:rectangleFeature.bottomRight];
    image = [image imageByApplyingFilter:@"CIPerspectiveCorrection" withInputParameters:rectangleCoordinates];
    return image;
}

- (CIDetector *)rectangleDetetor {
    static CIDetector *detector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [CIDetector detectorOfType:CIDetectorTypeRectangle
                                      context:nil
                                      options:@{ CIDetectorAccuracy: CIDetectorAccuracyLow,
                                                 CIDetectorTracking: @(YES) }];
    });
    return detector;
}

- (CIDetector *)highAccuracyRectangleDetector {
    static CIDetector *detector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [CIDetector detectorOfType:CIDetectorTypeRectangle context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
    });
    return detector;
}

- (CIRectangleFeature *)_biggestRectangleInRectangles:(NSArray *)rectangles {
    if (![rectangles count]) return nil;

    float halfPerimiterValue = 0;

    CIRectangleFeature *biggestRectangle = [rectangles firstObject];

    for (CIRectangleFeature *rect in rectangles) {
        CGPoint p1 = rect.topLeft;
        CGPoint p2 = rect.topRight;
        CGFloat width = hypotf(p1.x - p2.x, p1.y - p2.y);

        CGPoint p3 = rect.topLeft;
        CGPoint p4 = rect.bottomLeft;
        CGFloat height = hypotf(p3.x - p4.x, p3.y - p4.y);

        CGFloat currentHalfPerimiterValue = height + width;

        if (halfPerimiterValue < currentHalfPerimiterValue) {
            halfPerimiterValue = currentHalfPerimiterValue;
            biggestRectangle = rect;
        }
    }

    return biggestRectangle;
}

- (CIRectangleFeature *)biggestRectangleInRectangles:(NSArray *)rectangles {
    CIRectangleFeature *rectangleFeature = [self _biggestRectangleInRectangles:rectangles];

    if (!rectangleFeature) return nil;

    // Credit: http://stackoverflow.com/a/20399468/1091044

    NSArray *points = @[[NSValue valueWithCGPoint:rectangleFeature.topLeft], [NSValue valueWithCGPoint:rectangleFeature.topRight], [NSValue valueWithCGPoint:rectangleFeature.bottomLeft], [NSValue valueWithCGPoint:rectangleFeature.bottomRight]];

    CGPoint min = [points[0] CGPointValue];
    CGPoint max = min;
    for (NSValue *value in points) {
        CGPoint point = [value CGPointValue];
        min.x = fminf(point.x, min.x);
        min.y = fminf(point.y, min.y);
        max.x = fmaxf(point.x, max.x);
        max.y = fmaxf(point.y, max.y);
    }

    CGPoint center =
        {
            0.5f * (min.x + max.x),
            0.5f * (min.y + max.y),
        };

    NSNumber * (^angleFromPoint)(id) = ^(NSValue *value) {
        CGPoint point = [value CGPointValue];
        CGFloat theta = atan2f(point.y - center.y, point.x - center.x);
        CGFloat angle = fmodf(M_PI - M_PI_4 + theta, 2 * M_PI);
        return @(angle);
    };

    NSArray *sortedPoints = [points sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [angleFromPoint(a) compare:angleFromPoint(b)];
    }];

    IPDFRectangleFeature *rectangleFeatureMutable = [IPDFRectangleFeature new];
    rectangleFeatureMutable.topLeft = [sortedPoints[3] CGPointValue];
    rectangleFeatureMutable.topRight = [sortedPoints[2] CGPointValue];
    rectangleFeatureMutable.bottomRight = [sortedPoints[1] CGPointValue];
    rectangleFeatureMutable.bottomLeft = [sortedPoints[0] CGPointValue];

    if (self.delegate && _confidenceLevl > 50) {
        [self.delegate didDetectRectangle:rectangleFeature withType:[self typeForRectangle:(id) rectangleFeatureMutable]];
    }

    return (id) rectangleFeatureMutable;
}

- (IPDFRectangeType)typeForRectangle:(CIRectangleFeature *)rectangle {
    if (fabs(rectangle.topRight.y - rectangle.topLeft.y) > 100 ||
        fabs(rectangle.topRight.x - rectangle.bottomRight.x) > 100 ||
        fabs(rectangle.topLeft.x - rectangle.bottomLeft.x) > 100 ||
        fabs(rectangle.bottomLeft.y - rectangle.bottomRight.y) > 100) {

        return IPDFRectangeTypeBadAngle;
    } else if ((_glkView.frame.origin.y + _glkView.frame.size.height) - rectangle.topLeft.y > 150 ||
               (_glkView.frame.origin.y + _glkView.frame.size.height) - rectangle.topRight.y > 150 ||
               _glkView.frame.origin.y - rectangle.bottomLeft.y > 150 ||
               _glkView.frame.origin.y - rectangle.bottomRight.y > 150) {

        return IPDFRectangeTypeTooFar;
    }
    return IPDFRectangeTypeGood;
}

BOOL rectangleDetectionConfidenceHighEnough(float confidence) {
    return (confidence > 1.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.cachedBounds = self.bounds;
}

@end
