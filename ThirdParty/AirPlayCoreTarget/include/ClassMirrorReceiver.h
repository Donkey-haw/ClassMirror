#ifndef CLASS_MIRROR_RECEIVER_H
#define CLASS_MIRROR_RECEIVER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cm_receiver cm_receiver_t;

typedef enum {
    CM_RECEIVER_STATE_STOPPED = 0,
    CM_RECEIVER_STATE_STARTING = 1,
    CM_RECEIVER_STATE_READY = 2,
    CM_RECEIVER_STATE_CLIENT_CONNECTED = 3,
    CM_RECEIVER_STATE_STREAMING = 4,
    CM_RECEIVER_STATE_INTERRUPTED = 5,
    CM_RECEIVER_STATE_FAILED = 6
} cm_receiver_state_t;

typedef enum {
    CM_VIDEO_CODEC_UNKNOWN = 0,
    CM_VIDEO_CODEC_H264 = 1,
    CM_VIDEO_CODEC_H265 = 2
} cm_video_codec_t;

typedef struct {
    const char *receiver_name;
    const char *device_id;
    uint16_t width;
    uint16_t height;
    uint16_t refresh_rate;
    uint16_t max_fps;
    bool require_pin_each_connection;
    bool peer_to_peer_enabled;
    bool audio_enabled;
} cm_receiver_configuration_t;

typedef void (*cm_receiver_state_callback)(
    void *context,
    cm_receiver_state_t state,
    int error_code,
    const char *message
);

typedef bool (*cm_receiver_connection_request_callback)(
    void *context,
    const char *device_id,
    const char *model,
    const char *name
);

typedef void (*cm_receiver_pin_callback)(void *context, const char *pin);

typedef void (*cm_receiver_video_callback)(
    void *context,
    cm_video_codec_t codec,
    const uint8_t *bytes,
    size_t length,
    int nal_count,
    uint64_t local_time_ns,
    uint64_t remote_time_ns
);

typedef void (*cm_receiver_audio_format_callback)(
    void *context,
    uint8_t compression_type,
    uint16_t samples_per_frame,
    bool using_screen,
    bool is_media,
    uint64_t audio_format
);

typedef void (*cm_receiver_audio_callback)(
    void *context,
    uint8_t compression_type,
    const uint8_t *bytes,
    size_t length,
    uint16_t sequence_number,
    uint32_t rtp_time,
    uint64_t local_time_ns,
    uint64_t remote_time_ns
);

typedef void (*cm_receiver_video_size_callback)(
    void *context,
    float source_width,
    float source_height,
    float display_width,
    float display_height
);

typedef void (*cm_receiver_log_callback)(void *context, int level, const char *message);

typedef struct {
    void *context;
    cm_receiver_state_callback on_state;
    cm_receiver_connection_request_callback on_connection_request;
    cm_receiver_pin_callback on_pin;
    cm_receiver_video_callback on_video;
    cm_receiver_audio_format_callback on_audio_format;
    cm_receiver_audio_callback on_audio;
    cm_receiver_video_size_callback on_video_size;
    cm_receiver_log_callback on_log;
} cm_receiver_callbacks_t;

cm_receiver_t *cm_receiver_create(cm_receiver_callbacks_t callbacks);
int cm_receiver_start(cm_receiver_t *receiver, const cm_receiver_configuration_t *configuration);
void cm_receiver_stop(cm_receiver_t *receiver);
void cm_receiver_disconnect(cm_receiver_t *receiver);
bool cm_receiver_is_running(const cm_receiver_t *receiver);
uint16_t cm_receiver_port(const cm_receiver_t *receiver);
void cm_receiver_destroy(cm_receiver_t *receiver);

const char *cm_receiver_version(void);
const char *cm_receiver_upstream_commit(void);

#ifdef __cplusplus
}
#endif

#endif
