#ifndef RECORD_WHISPER_H
#define RECORD_WHISPER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct record_whisper record_whisper;

record_whisper * record_whisper_create(const char * model_path, int thread_count);
void record_whisper_destroy(record_whisper * instance);

/// Transcribes (or translates, when `translate` is non-zero) `sample_count`
/// mono 16 kHz float samples. Returns a UTF-8 null-terminated string that
/// the caller must free with `record_whisper_string_destroy`. Returns NULL
/// on failure and writes a non-zero code into `error_code`.
char * record_whisper_transcribe(
    record_whisper * instance,
    const float * samples,
    int sample_count,
    int translate,
    int * error_code
);
void record_whisper_string_destroy(char * value);

#ifdef __cplusplus
}
#endif

#endif // RECORD_WHISPER_H
