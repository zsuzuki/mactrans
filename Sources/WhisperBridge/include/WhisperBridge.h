#ifndef MAC_TRANS_WHISPER_BRIDGE_H
#define MAC_TRANS_WHISPER_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mt_whisper mt_whisper_t;

mt_whisper_t * mt_whisper_create(
    const char * model_path,
    const char * vad_model_path,
    const char * language,
    bool use_gpu,
    int n_threads,
    char * error_buffer,
    int error_capacity
);

// Returns the number of timestamped words, or -1 on failure. Results remain
// owned by the runtime and are valid until the next transcription.
int mt_whisper_transcribe(
    mt_whisper_t * runtime,
    const float * samples,
    int sample_count,
    char * error_buffer,
    int error_capacity
);

const char * mt_whisper_word_text(mt_whisper_t * runtime, int index);
int64_t mt_whisper_word_start_ms(mt_whisper_t * runtime, int index);
int64_t mt_whisper_word_end_ms(mt_whisper_t * runtime, int index);

// Input: complete 512-sample frames at 16 kHz. Keeps VAD state across calls.
// Returns the number of probabilities, or -1 on failure.
int mt_whisper_vad(mt_whisper_t * runtime, const float * samples, int sample_count,
                   float * probabilities, int capacity);

void mt_whisper_reset(mt_whisper_t * runtime);
void mt_whisper_destroy(mt_whisper_t * runtime);

#ifdef __cplusplus
}
#endif

#endif
