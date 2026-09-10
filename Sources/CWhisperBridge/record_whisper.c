#include "record_whisper.h"

#include <ggml-backend.h>
#include <stdlib.h>
#include <string.h>
#include <whisper.h>

struct record_whisper {
    struct whisper_context * context;
    int thread_count;
};

static record_whisper * active_instance = NULL;
static int cleanup_registered = 0;

static void record_whisper_cleanup_active(void) {
    if (active_instance == NULL) {
        return;
    }
    whisper_free(active_instance->context);
    active_instance->context = NULL;
    free(active_instance);
    active_instance = NULL;
}

record_whisper * record_whisper_create(const char * model_path, int thread_count) {
    ggml_backend_load_all();
    struct whisper_context_params context_params = whisper_context_default_params();
    context_params.use_gpu = true;
    context_params.flash_attn = true;

    struct whisper_context * context = whisper_init_from_file_with_params(model_path, context_params);
    if (context == NULL) {
        return NULL;
    }

    record_whisper * instance = calloc(1, sizeof(record_whisper));
    if (instance == NULL) {
        whisper_free(context);
        return NULL;
    }

    instance->context = context;
    instance->thread_count = thread_count > 0 ? thread_count : 4;
    active_instance = instance;
    if (!cleanup_registered) {
        atexit(record_whisper_cleanup_active);
        cleanup_registered = 1;
    }
    return instance;
}

void record_whisper_destroy(record_whisper * instance) {
    if (instance == NULL) {
        return;
    }
    whisper_free(instance->context);
    if (active_instance == instance) {
        active_instance = NULL;
    }
    free(instance);
}

char * record_whisper_transcribe(
    record_whisper * instance,
    const float * samples,
    int sample_count,
    int translate,
    int * error_code
) {
    if (error_code != NULL) {
        *error_code = 0;
    }
    if (instance == NULL || samples == NULL || sample_count <= 0) {
        if (error_code != NULL) {
            *error_code = 1;
        }
        return NULL;
    }

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = instance->thread_count;
    params.translate = translate != 0;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = false;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.language = "en";
    params.greedy.best_of = 2;

    if (whisper_full(instance->context, params, samples, sample_count) != 0) {
        if (error_code != NULL) {
            *error_code = 2;
        }
        return NULL;
    }

    const int segment_count = whisper_full_n_segments(instance->context);
    size_t output_size = 1;
    for (int index = 0; index < segment_count; index++) {
        const char * text = whisper_full_get_segment_text(instance->context, index);
        if (text != NULL) {
            output_size += strlen(text);
        }
    }

    char * output = calloc(output_size, sizeof(char));
    if (output == NULL) {
        if (error_code != NULL) {
            *error_code = 3;
        }
        return NULL;
    }

    for (int index = 0; index < segment_count; index++) {
        const char * text = whisper_full_get_segment_text(instance->context, index);
        if (text != NULL) {
            strcat(output, text);
        }
    }
    return output;
}

void record_whisper_string_destroy(char * value) {
    free(value);
}
