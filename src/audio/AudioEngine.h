#pragma once

#include <JuceHeader.h>
#include "audio/GaplessPlaylistSource.h"
#include "audio/TrackMetadata.h"

#include <functional>
#include <map>
#include <string>
#include <vector>

/** Owns device, playlist and transport. The UI never touches audio sources. */
class AudioEngine : private juce::ChangeListener
{
public:
    using RepeatMode = GaplessPlaylistSource::RepeatMode;

    struct State
    {
        bool hasFile = false;
        bool isPlaying = false;
        double positionSeconds = 0.0;
        double lengthSeconds = 0.0;
        juce::String fileName;
        juce::String filePath;
        int currentTrackIndex = -1;
        RepeatMode repeatMode = RepeatMode::playlist;
        bool gaplessPlayback = true;
        juce::String activePlaylistId;
        juce::String activePlaylistName;
        bool queueIsActive = true;
        TrackMetadataPtr currentTrackMetadata;
        juce::StringArray playlistNames;
        juce::StringArray playlistPaths;
        std::vector<TrackMetadataPtr> playlistMetadata;
    };

    using StateCallback = std::function<void(const State&)>;

    AudioEngine();
    ~AudioEngine() override;

    int addFiles(const juce::Array<juce::File>& files, bool startPlaybackIfEmpty = true);
    int playAlbumPlaylist(const juce::String& playlistId,
                          const juce::String& playlistName,
                          const juce::Array<juce::File>& files);
    bool removeTrack(int index);
    void clearPlaylist();
    void playTrack(int index);
    void setRepeatMode(RepeatMode mode);
    void setGaplessPlayback(bool shouldBeGapless);
    void play();
    void pause();
    void stop();
    void togglePlayPause();
    void playPrevious();
    void playNext();
    void setPosition(double seconds);
    void setGain(float gain01);

    int readAnalysisSamples(float* destination, int maxSamples);

    State getState() const;
    void setStateCallback(StateCallback cb);

private:
    struct PlaylistContext
    {
        juce::String id;
        juce::String name;
        std::unique_ptr<GaplessPlaylistSource> source;
    };

    void changeListenerCallback(juce::ChangeBroadcaster*) override;
    void notifyState();
    void startPositionTimer();
    void stopPositionTimer();
    void configureProperties();
    void restorePlaylist();
    void savePlaylist();
    void scheduleMetadataRead(const juce::File& file);
    void metadataReady(TrackMetadata metadata);

    std::unique_ptr<PlaylistContext> createPlaylistContext(const juce::String& id,
                                                           const juce::String& name);
    PlaylistContext& queuePlaylist();
    const PlaylistContext& queuePlaylist() const;
    PlaylistContext* findPlaylist(const juce::String& id);
    GaplessPlaylistSource& activeSource();
    const GaplessPlaylistSource& activeSource() const;
    void switchToPlaylist(PlaylistContext& context);
    void playActiveTrack(int index);

    class AnalysisAudioSource;

    juce::AudioDeviceManager deviceManager;
    juce::AudioFormatManager formatManager;
    juce::TimeSliceThread readAheadThread;
    std::vector<std::unique_ptr<PlaylistContext>> playlists;
    PlaylistContext* activePlaylist = nullptr;
    RepeatMode currentRepeatMode = RepeatMode::playlist;
    bool currentGaplessPlayback = true;
    juce::AudioTransportSource transportSource;
    std::unique_ptr<AnalysisAudioSource> analysisSource;
    juce::AudioSourcePlayer sourcePlayer;
    juce::ApplicationProperties applicationProperties;

    StateCallback stateCallback;

    class PositionTimer;
    std::unique_ptr<PositionTimer> positionTimer;
    TrackMetadataReader metadataReader;
    mutable juce::CriticalSection metadataLock;
    std::map<std::string, TrackMetadataPtr> metadataByPath;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(AudioEngine)
};
