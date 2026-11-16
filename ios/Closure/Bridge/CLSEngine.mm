#import "CLSEngine.h"

#include "closure/PlaybackEngine.h"

#include <memory>

namespace
{
NSString* toNSString(const std::string& value)
{
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}

NSError* makeError(const std::string& message)
{
    return [NSError errorWithDomain:@"com.qar.closure.engine"
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: toNSString(message) }];
}

NSString* codecName(std::uint32_t formatID)
{
    switch (formatID)
    {
        case 'flac': return @"FLAC";
        case 'alac': return @"ALAC";
        case 'lpcm': return @"PCM";
        case 'aac ': return @"AAC";
        case '.mp3': return @"MP3";
        default: break;
    }

    const char code[5] = { static_cast<char>(formatID >> 24), static_cast<char>(formatID >> 16),
                           static_cast<char>(formatID >> 8), static_cast<char>(formatID), 0 };
    return [NSString stringWithUTF8String:code] ?: @"?";
}
} // namespace

@interface CLSSourceInfo ()
- (instancetype)initWithInfo:(const closure::SourceInfo&)info;
@end

@implementation CLSSourceInfo
- (instancetype)initWithInfo:(const closure::SourceInfo&)info
{
    if ((self = [super init]))
    {
        _ok = info.ok;
        _error = toNSString(info.error);
        _sampleRate = info.sampleRate;
        _channels = info.channels;
        _durationSeconds = info.durationSeconds();
        _codec = codecName(info.formatID);
        _bitDepth = info.bitDepth;
        _lossless = info.lossless;
    }
    return self;
}
@end

@interface CLSEngineStatus ()
- (instancetype)initWithStatus:(const closure::EngineStatus&)status;
@end

@implementation CLSEngineStatus
- (instancetype)initWithStatus:(const closure::EngineStatus&)status
{
    if ((self = [super init]))
    {
        _playing = status.playing;
        _ended = status.ended;
        _trackIndex = status.trackIndex;
        _trackCount = status.trackCount;
        _positionSeconds = status.positionSeconds;
        _durationSeconds = status.durationSeconds;
        _outputSampleRate = status.outputSampleRate;
        _sourceSampleRate = status.sourceSampleRate;
        _resampling = status.resampling;
        _bufferedSeconds = status.bufferedSeconds;
        _underruns = status.underruns;
    }
    return self;
}
@end

@implementation CLSEngine
{
    std::unique_ptr<closure::PlaybackEngine> _engine;
}

+ (CLSSourceInfo*)probe:(NSString*)path
{
    return [[CLSSourceInfo alloc] initWithInfo:closure::probeSource(path.fileSystemRepresentation)];
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _engine = std::make_unique<closure::PlaybackEngine>();

        __weak CLSEngine* weakSelf = self;
        _engine->setEventHandler([weakSelf](const closure::EngineEvent& event)
        {
            const auto type = static_cast<CLSEngineEventType>(event.type);
            const NSInteger index = event.trackIndex;
            NSString* message = toNSString(event.message);
            dispatch_async(dispatch_get_main_queue(), ^{
                CLSEngine* strongSelf = weakSelf;
                if (strongSelf != nil && strongSelf.eventHandler != nil)
                    strongSelf.eventHandler(type, index, message);
            });
        });
    }
    return self;
}

- (BOOL)setOutputSampleRate:(double)sampleRate error:(NSError**)error
{
    std::string message;
    if (_engine->setOutputSampleRate(sampleRate, &message))
        return YES;

    if (error != nullptr)
        *error = makeError(message);
    return NO;
}

- (void)setQueue:(NSArray<NSString*>*)paths startIndex:(NSInteger)startIndex
{
    std::vector<std::string> converted;
    converted.reserve(paths.count);
    for (NSString* path in paths)
        converted.emplace_back(path.fileSystemRepresentation);

    _engine->setQueue(std::move(converted), static_cast<int>(startIndex));
}

- (BOOL)playAndReturnError:(NSError**)error
{
    std::string message;
    if (_engine->play(&message))
        return YES;

    if (error != nullptr)
        *error = makeError(message);
    return NO;
}

- (void)resetOutput { _engine->resetOutput(); }
- (void)pause { _engine->pause(); }
- (void)togglePlayPause { _engine->togglePlayPause(); }
- (void)playIndex:(NSInteger)index { _engine->playIndex(static_cast<int>(index)); }
- (void)next { _engine->next(); }
- (void)previous { _engine->previous(); }
- (void)seekTo:(double)seconds { _engine->seek(seconds); }

- (void)setRepeatMode:(CLSRepeatMode)mode
{
    switch (mode)
    {
        case CLSRepeatModeOff: _engine->setRepeatMode(closure::RepeatMode::off); break;
        case CLSRepeatModeAll: _engine->setRepeatMode(closure::RepeatMode::all); break;
        case CLSRepeatModeOne: _engine->setRepeatMode(closure::RepeatMode::one); break;
    }
}

- (CLSEngineStatus*)status
{
    return [[CLSEngineStatus alloc] initWithStatus:_engine->status()];
}
@end
