#include "WhisperBridge.h"
#include "whisper.h"

#include <stdlib.h>
#include <string.h>

struct mt_whisper {
    struct whisper_context * context;
    char language[16];
    int n_threads;
};

static void mt_set_error(char * buffer, int capacity, const char * message) {
    if (buffer == NULL || capacity <= 0) {
        return;
    }
    if (message == NULL) {
        message = "Unknown whisper.cpp error";
    }
    snprintf(buffer, (size_t) capacity, "%s", message);
}

static char * mt_copy_string(const char * value) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value);
    char * output = (char *) malloc(length + 1);
    if (output == NULL) {
        return NULL;
    }
    memcpy(output, value, length + 1);
    return output;
}

mt_whisper_t * mt_whisper_create(
    const char * model_path,
    const char * language,
    bool use_gpu,
    int n_threads,
    char * error_buffer,
    int error_capacity
) {
    if (model_path == NULL || strlen(model_path) == 0) {
        mt_set_error(error_buffer, error_capacity, "Missing whisper model path");
        return NULL;
    }

    struct whisper_context_params context_params = whisper_context_default_params();
    context_params.use_gpu = use_gpu;

    struct whisper_context * context = whisper_init_from_file_with_params(model_path, context_params);
    if (context == NULL) {
        mt_set_error(error_buffer, error_capacity, "Failed to initialize whisper.cpp context");
        return NULL;
    }

    mt_whisper_t * runtime = (mt_whisper_t *) calloc(1, sizeof(mt_whisper_t));
    if (runtime == NULL) {
        whisper_free(context);
        mt_set_error(error_buffer, error_capacity, "Failed to allocate whisper runtime");
        return NULL;
    }

    runtime->context = context;
    runtime->n_threads = n_threads > 0 ? n_threads : 4;
    snprintf(runtime->language, sizeof(runtime->language), "%s", language != NULL ? language : "en");
    return runtime;
}

char * mt_whisper_transcribe(
    mt_whisper_t * runtime,
    const float * samples,
    int sample_count,
    bool * is_final,
    char * error_buffer,
    int error_capacity
) {
    if (is_final != NULL) {
        *is_final = false;
    }

    if (runtime == NULL || runtime->context == NULL) {
        mt_set_error(error_buffer, error_capacity, "Whisper runtime is not initialized");
        return NULL;
    }
    if (samples == NULL || sample_count < WHISPER_SAMPLE_RATE) {
        return mt_copy_string("");
    }

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    params.n_threads = runtime->n_threads;
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = true;
    params.max_tokens = 0;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.suppress_blank = true;
    params.suppress_nst = false;
    params.temperature = 0.0f;
    params.temperature_inc = 0.0f;
    params.beam_search.beam_size = 5;
    params.language = runtime->language;

    int result = whisper_full(runtime->context, params, samples, sample_count);
    if (result != 0) {
        mt_set_error(error_buffer, error_capacity, "whisper_full failed");
        return NULL;
    }

    int segment_count = whisper_full_n_segments(runtime->context);
    if (segment_count <= 0) {
        return mt_copy_string("");
    }

    size_t total_length = 0;
    for (int index = 0; index < segment_count; index++) {
        const char * text = whisper_full_get_segment_text(runtime->context, index);
        if (text != NULL) {
            total_length += strlen(text);
        }
    }

    char * output = (char *) calloc(total_length + 1, sizeof(char));
    if (output == NULL) {
        mt_set_error(error_buffer, error_capacity, "Failed to allocate transcription text");
        return NULL;
    }

    for (int index = 0; index < segment_count; index++) {
        const char * text = whisper_full_get_segment_text(runtime->context, index);
        if (text != NULL) {
            strlcat(output, text, total_length + 1);
        }
    }

    return output;
}

void mt_whisper_reset(mt_whisper_t * runtime) {
    (void) runtime;
}

void mt_whisper_destroy(mt_whisper_t * runtime) {
    if (runtime == NULL) {
        return;
    }
    if (runtime->context != NULL) {
        whisper_free(runtime->context);
    }
    free(runtime);
}

void mt_whisper_free_string(char * value) {
    free(value);
}
