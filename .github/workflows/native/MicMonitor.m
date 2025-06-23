#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

void microphoneActivityListener(AudioObjectID inObjectID,
                                UInt32 inNumberAddresses,
                                const AudioObjectPropertyAddress inAddresses[],
                                void *inClientData)
{
    UInt32 isRunning = 0;
    UInt32 propertySize = sizeof(isRunning);

    AudioObjectPropertyAddress deviceIsRunningProperty = {
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};

    OSStatus status = AudioObjectGetPropertyData(inObjectID,
                                                 &deviceIsRunningProperty,
                                                 0,
                                                 NULL,
                                                 &propertySize,
                                                 &isRunning);

    if (status == noErr)
    {
        if (isRunning)
        {
            printf("🎤 Microphone is ACTIVE");
            fflush(stdout);
        }
        else
        {
            printf("🎤 Microphone is INACTIVE");
            fflush(stdout);
        }
    }
    else
    {
        NSLog(@"Error getting microphone running state: %d", (int)status);
    }
}

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        // Get default input device
        AudioDeviceID inputDeviceID = kAudioObjectUnknown;
        UInt32 propertySize = sizeof(inputDeviceID);
        AudioObjectPropertyAddress defaultInputDeviceProperty = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};

        OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                     &defaultInputDeviceProperty,
                                                     0,
                                                     NULL,
                                                     &propertySize,
                                                     &inputDeviceID);
        if (status != noErr)
        {
            NSLog(@"Error getting default input device: %d", (int)status);
            return -1;
        }

        // Set up listener for microphone running state changes
        AudioObjectPropertyAddress deviceIsRunningProperty = {
            kAudioDevicePropertyDeviceIsRunningSomewhere,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};

        status = AudioObjectAddPropertyListenerBlock(inputDeviceID,
                                                     &deviceIsRunningProperty,
                                                     dispatch_get_main_queue(),
                                                     ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
                                                       microphoneActivityListener(inputDeviceID, inNumberAddresses, inAddresses, NULL);
                                                     });

        if (status != noErr)
        {
            NSLog(@"Failed to add property listener: %d", (int)status);
            return -1;
        }

        // Initial state check
        microphoneActivityListener(inputDeviceID, 0, NULL, NULL);

        // Run the main run loop to receive callbacks
        NSLog(@"Starting microphone activity monitor...");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}