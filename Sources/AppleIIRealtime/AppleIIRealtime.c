#include "AppleIIRealtime.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

struct AppleIIAudioFIFO {
    float *samples;
    uint32_t capacity;
    _Atomic(uint32_t) read_index;
    _Atomic(uint32_t) write_index;
};

AppleIIAudioFIFO *appleii_audio_fifo_create(size_t capacity) {
    if (capacity < 2 || capacity > UINT32_MAX) return NULL;
    AppleIIAudioFIFO *fifo = calloc(1, sizeof(*fifo));
    if (!fifo) return NULL;
    fifo->samples = calloc(capacity, sizeof(float));
    if (!fifo->samples) { free(fifo); return NULL; }
    fifo->capacity = (uint32_t)capacity;
    return fifo;
}

void appleii_audio_fifo_destroy(AppleIIAudioFIFO *fifo) {
    if (!fifo) return;
    free(fifo->samples);
    free(fifo);
}

size_t appleii_audio_fifo_available(const AppleIIAudioFIFO *fifo) {
    uint32_t write = atomic_load_explicit(&fifo->write_index, memory_order_acquire);
    uint32_t read = atomic_load_explicit(&fifo->read_index, memory_order_acquire);
    return write - read;
}

size_t appleii_audio_fifo_write(AppleIIAudioFIFO *fifo, const float *samples, size_t count) {
    uint32_t write = atomic_load_explicit(&fifo->write_index, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&fifo->read_index, memory_order_acquire);
    size_t writable = fifo->capacity - (write - read);
    if (count > writable) count = writable;
    for (size_t i = 0; i < count; i++) fifo->samples[(write + (uint32_t)i) % fifo->capacity] = samples[i];
    atomic_store_explicit(&fifo->write_index, write + (uint32_t)count, memory_order_release);
    return count;
}

size_t appleii_audio_fifo_read(AppleIIAudioFIFO *fifo, float *samples, size_t count) {
    uint32_t read = atomic_load_explicit(&fifo->read_index, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&fifo->write_index, memory_order_acquire);
    size_t available = write - read;
    if (count > available) count = available;
    for (size_t i = 0; i < count; i++) samples[i] = fifo->samples[(read + (uint32_t)i) % fifo->capacity];
    atomic_store_explicit(&fifo->read_index, read + (uint32_t)count, memory_order_release);
    return count;
}
