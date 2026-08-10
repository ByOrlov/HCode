/*
 * miniaudio_bridge.c — thin C wrapper over miniaudio for hcode's in-process
 * sound playback. The embedded OGG is decoded in memory and played through
 * a single global ma_engine.  Each play call spawns a detached POSIX thread
 * that owns the decoder + sound for the duration of playback; the agent loop
 * is never blocked.
 *
 * The engine is initialized lazily on first play.  If init fails (no audio
 * device, headless server), all play calls become silent no-ops.
 *
 * Built together with the Crystal binary — see Rakefile.
 */

/* Include stb_vorbis implementation first. stb_vorbis.c defines
 * STB_VORBIS_INCLUDE_STB_VORBIS_H internally and provides both header
 * declarations and implementation. miniaudio.h checks for that define to
 * enable its built-in Vorbis decoder backend. */
#define STB_VORBIS_NO_INTEGER_CONVERSION
#include "stb_vorbis.c"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdlib.h>

/* --- Platform threading -------------------------------------------------- */

#if defined(_WIN32) || defined(_WIN64)
  #include <windows.h>
  #define MA_BRIDGE_THREAD HANDLE
  #define ma_bridge_thread_create(tid, fn, arg) \
      (*(tid) = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)(fn), (arg), 0, NULL), \
       (*(tid) != NULL ? 0 : -1))
  #define ma_bridge_thread_detach(tid) CloseHandle(*(tid))
#else
  #include <pthread.h>
  #define MA_BRIDGE_THREAD pthread_t
  #define ma_bridge_thread_create(tid, fn, arg) pthread_create((tid), NULL, (fn), (arg))
  #define ma_bridge_thread_detach(tid) pthread_detach(*(tid))
#endif

/* --- Global engine (lazy-init) ------------------------------------------- */

static ma_engine g_engine;
static int       g_engine_ready = 0;

int ma_notify_init(void)
{
    if (g_engine_ready) return 0;
    if (ma_engine_init(NULL, &g_engine) != MA_SUCCESS) return -1;
    g_engine_ready = 1;
    return 0;
}

void ma_notify_shutdown(void)
{
    if (!g_engine_ready) return;
    ma_engine_uninit(&g_engine);
    g_engine_ready = 0;
}

int ma_notify_is_ready(void)
{
    return g_engine_ready;
}

/* --- Playback ------------------------------------------------------------ */

typedef struct {
    const void  *data;
    size_t       size;
    float        volume;
    ma_engine   *engine;
} play_ctx;

/*
 * Thread entry: decode the OGG blob, create a sound from the decoder, play
 * it, wait for completion, then free everything.  Detached — never joined.
 */
#if defined(_WIN32) || defined(_WIN64)
static DWORD WINAPI play_thread_func(LPVOID userdata)
#else
static void *play_thread_func(void *userdata)
#endif
{
    play_ctx   *ctx = (play_ctx *)userdata;
    ma_decoder  decoder;
    ma_result   result;
    ma_decoder_config dec_cfg;

    /* Channels=0 / sampleRate=0: keep the source's native format; the
     * engine's node graph converts internally. */
    dec_cfg = ma_decoder_config_init(ma_format_f32, 0, 0);

    result = ma_decoder_init_memory(ctx->data, ctx->size, &dec_cfg, &decoder);
    if (result != MA_SUCCESS) goto done;

    ma_sound sound;
    result = ma_sound_init_from_data_source(ctx->engine,
                                            (ma_data_source *)&decoder,
                                            MA_SOUND_FLAG_NO_SPATIALIZATION,
                                            NULL, &sound);
    if (result != MA_SUCCESS) {
        ma_decoder_uninit(&decoder);
        goto done;
    }

    ma_sound_set_volume(&sound, ctx->volume);
    ma_sound_start(&sound);

    /* Poll until playback finishes (1 s notification → ~100 iterations). */
    while (!ma_sound_at_end(&sound))
        ma_sleep(10);

    ma_sound_uninit(&sound);
    ma_decoder_uninit(&decoder);

done:
    free(ctx);
    return 0;
}

void ma_notify_play(const void *data, size_t size, float volume)
{
    if (!g_engine_ready || data == NULL || size == 0) return;

    play_ctx *ctx = (play_ctx *)malloc(sizeof(play_ctx));
    if (ctx == NULL) return;

    ctx->data    = data;
    ctx->size    = size;
    ctx->volume  = volume;
    ctx->engine  = &g_engine;

    MA_BRIDGE_THREAD tid;
    if (ma_bridge_thread_create(&tid, play_thread_func, ctx) != 0) {
        free(ctx);     /* thread creation failed — clean up, stay silent. */
        return;
    }
    ma_bridge_thread_detach(&tid);
}
