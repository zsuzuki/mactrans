#include "WhisperBridge.h"
#include "whisper.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct mt_whisper {
    struct whisper_context * context;
    struct whisper_vad_context * vad;
    char language[16];
    int n_threads;
};

static void mt_set_error(char * buffer, int capacity, const char * message) {
    if (buffer != NULL && capacity > 0) {
        snprintf(buffer, (size_t) capacity, "%s", message);
    }
}

static void mt_log(enum ggml_log_level level, const char * text, void * user_data) {
    (void) user_data;
    // Silero logs every 32 ms frame at INFO level. Keep actionable diagnostics.
    if (level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR) {
        fputs(text, stderr);
    }
}

mt_whisper_t * mt_whisper_create(
    const char * model_path, const char * vad_model_path, const char * language,
    bool use_gpu, int n_threads, char * error_buffer, int error_capacity
) {
    if (model_path == NULL || vad_model_path == NULL) {
        mt_set_error(error_buffer, error_capacity, "Missing Whisper or VAD model path");
        return NULL;
    }
    whisper_log_set(mt_log, NULL);
    mt_whisper_t * runtime = calloc(1, sizeof(mt_whisper_t));
    if (runtime == NULL) {
        mt_set_error(error_buffer, error_capacity, "Failed to allocate Whisper runtime");
        return NULL;
    }
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = use_gpu;
    runtime->context = whisper_init_from_file_with_params(model_path, params);
    if (runtime->context == NULL) {
        mt_set_error(error_buffer, error_capacity, "Failed to initialize whisper.cpp context");
        mt_whisper_destroy(runtime);
        return NULL;
    }
    struct whisper_vad_context_params vad_params = whisper_vad_default_context_params();
    vad_params.use_gpu = false;
    vad_params.n_threads = 2;
    runtime->vad = whisper_vad_init_from_file_with_params(vad_model_path, vad_params);
    if (runtime->vad == NULL) {
        mt_set_error(error_buffer, error_capacity, "Failed to load the bundled Silero VAD model");
        mt_whisper_destroy(runtime);
        return NULL;
    }
    runtime->n_threads = n_threads > 0 ? n_threads : 4;
    snprintf(runtime->language, sizeof(runtime->language), "%s", language != NULL ? language : "en");
    return runtime;
}

int mt_whisper_transcribe(mt_whisper_t * runtime, const float * samples, int sample_count,
                         char * error_buffer, int error_capacity) {
    if (runtime == NULL || runtime->context == NULL || samples == NULL || sample_count <= 0) {
        mt_set_error(error_buffer, error_capacity, "Invalid transcription input");
        return -1;
    }
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    params.n_threads = runtime->n_threads;
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = false;
    params.single_segment = false;
    // whisper.cpp splits timestamped tokens at word boundaries for us.
    params.token_timestamps = true;
    params.max_len = 1;
    params.split_on_word = true;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.temperature = 0.0f;
    params.temperature_inc = 0.0f;
    params.beam_search.beam_size = 5;
    params.language = runtime->language;

    if (whisper_full(runtime->context, params, samples, sample_count) != 0) {
        mt_set_error(error_buffer, error_capacity, "whisper_full failed");
        return -1;
    }
    return whisper_full_n_segments(runtime->context);
}

const char * mt_whisper_word_text(mt_whisper_t * runtime, int index) {
    return whisper_full_get_segment_text(runtime->context, index);
}

int64_t mt_whisper_word_start_ms(mt_whisper_t * runtime, int index) {
    return 10 * whisper_full_get_segment_t0(runtime->context, index);
}

int64_t mt_whisper_word_end_ms(mt_whisper_t * runtime, int index) {
    return 10 * whisper_full_get_segment_t1(runtime->context, index);
}

int mt_whisper_vad(mt_whisper_t * runtime, const float * samples, int sample_count,
                   float * probabilities, int capacity) {
    if (runtime == NULL || runtime->vad == NULL || samples == NULL || probabilities == NULL ||
        sample_count <= 0 || sample_count % 512 != 0 || capacity < sample_count / 512) {
        return -1;
    }
    if (!whisper_vad_detect_speech_no_reset(runtime->vad, samples, sample_count)) return -1;
    int count = whisper_vad_n_probs(runtime->vad);
    if (count != sample_count / 512) return -1;
    memcpy(probabilities, whisper_vad_probs(runtime->vad), (size_t) count * sizeof(float));
    return count;
}

void mt_whisper_reset(mt_whisper_t * runtime) {
    if (runtime != NULL && runtime->vad != NULL) whisper_vad_reset_state(runtime->vad);
}

void mt_whisper_destroy(mt_whisper_t * runtime) {
    if (runtime == NULL) return;
    if (runtime->vad != NULL) whisper_vad_free(runtime->vad);
    if (runtime->context != NULL) whisper_free(runtime->context);
    free(runtime);
}
