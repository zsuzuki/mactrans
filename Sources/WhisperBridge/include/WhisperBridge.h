#ifndef MAC_TRANS_WHISPER_BRIDGE_H
#define MAC_TRANS_WHISPER_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mt_whisper mt_whisper_t;

mt_whisper_t * mt_whisper_create(
    const char * model_path,
    const char * language,
    bool use_gpu,
    int n_threads,
    char * error_buffer,
    int error_capacity
);

char * mt_whisper_transcribe(
    mt_whisper_t * runtime,
    const float * samples,
    int sample_count,
    bool * is_final,
    char * error_buffer,
    int error_capacity
);

void mt_whisper_reset(mt_whisper_t * runtime);
void mt_whisper_destroy(mt_whisper_t * runtime);
void mt_whisper_free_string(char * value);

#ifdef __cplusplus
}
#endif

#endif
