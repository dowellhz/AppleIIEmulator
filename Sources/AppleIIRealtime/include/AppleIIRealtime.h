#pragma once
#include <stddef.h>

typedef struct AppleIIAudioFIFO AppleIIAudioFIFO;
AppleIIAudioFIFO *appleii_audio_fifo_create(size_t capacity);
void appleii_audio_fifo_destroy(AppleIIAudioFIFO *fifo);
size_t appleii_audio_fifo_available(const AppleIIAudioFIFO *fifo);
size_t appleii_audio_fifo_write(AppleIIAudioFIFO *fifo, const float *samples, size_t count);
size_t appleii_audio_fifo_read(AppleIIAudioFIFO *fifo, float *samples, size_t count);
