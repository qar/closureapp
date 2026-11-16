#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CLSRepeatMode) {
    CLSRepeatModeOff,
    CLSRepeatModeAll,
    CLSRepeatModeOne,
};

typedef NS_ENUM(NSInteger, CLSEngineEventType) {
    CLSEngineEventTypeTrackChanged,
    CLSEngineEventTypeEnded,
    CLSEngineEventTypeError,
};

/// Facts about one audio file, read without decoding it.
@interface CLSSourceInfo : NSObject
@property (nonatomic, readonly) BOOL ok;
@property (nonatomic, readonly, copy) NSString *error;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSInteger channels;
@property (nonatomic, readonly) double durationSeconds;
@property (nonatomic, readonly, copy) NSString *codec;
@property (nonatomic, readonly) NSInteger bitDepth;
@property (nonatomic, readonly) BOOL lossless;
@end

@interface CLSEngineStatus : NSObject
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL ended;
@property (nonatomic, readonly) NSInteger trackIndex;
@property (nonatomic, readonly) NSInteger trackCount;
@property (nonatomic, readonly) double positionSeconds;
@property (nonatomic, readonly) double durationSeconds;
@property (nonatomic, readonly) double outputSampleRate;
@property (nonatomic, readonly) double sourceSampleRate;
@property (nonatomic, readonly) BOOL resampling;
@property (nonatomic, readonly) double bufferedSeconds;
@property (nonatomic, readonly) uint64_t underruns;
@end

/// Objective-C++ face of closure::PlaybackEngine for Swift.
@interface CLSEngine : NSObject

+ (CLSSourceInfo *)probe:(NSString *)path;

- (BOOL)setOutputSampleRate:(double)sampleRate error:(NSError **)error;
/// Drops the output unit after a media services reset. Call setOutputSampleRate next.
- (void)resetOutput;
- (void)setQueue:(NSArray<NSString *> *)paths startIndex:(NSInteger)startIndex;
- (BOOL)playAndReturnError:(NSError **)error;
- (void)pause;
- (void)togglePlayPause;
- (void)playIndex:(NSInteger)index;
- (void)next;
- (void)previous;
- (void)seekTo:(double)seconds;
- (void)setRepeatMode:(CLSRepeatMode)mode;

@property (nonatomic, readonly) CLSEngineStatus *status;

/// Called on the main queue.
@property (nonatomic, copy, nullable) void (^eventHandler)(CLSEngineEventType type, NSInteger trackIndex, NSString *message);

@end

NS_ASSUME_NONNULL_END
