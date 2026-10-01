#include "ClassMirrorReceiver.h"

#include "dnssd.h"
#include "raop.h"

#include <ctype.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CM_CORE_VERSION "UxPlay-v1.73.7"
#define CM_CORE_COMMIT "df67c212a433cf6dda3676dd40c097900d24e645"

struct cm_receiver {
    cm_receiver_callbacks_t callbacks;
    raop_t *raop;
    dnssd_t *dnssd;
    uint16_t port;
    atomic_bool running;
    atomic_bool streaming_started;
    atomic_int open_connections;
    atomic_int video_codec;
    bool require_pin_each_connection;
    bool audio_enabled;
    pthread_mutex_t client_lock;
    char active_device_id[128];
};

static void cm_emit_state(cm_receiver_t *receiver, cm_receiver_state_t state, int error_code, const char *message) {
    if (receiver && receiver->callbacks.on_state) {
        receiver->callbacks.on_state(receiver->callbacks.context, state, error_code, message);
    }
}

static void cm_log(void *context, int level, const char *message) {
    cm_receiver_t *receiver = context;
    if (receiver && receiver->callbacks.on_log) {
        receiver->callbacks.on_log(receiver->callbacks.context, level, message);
    }
}

static bool cm_parse_device_id(const char *string, unsigned char bytes[6]) {
    if (!string || strlen(string) != 17) {
        return false;
    }

    for (int index = 0; index < 6; index++) {
        const int offset = index * 3;
        if (!isxdigit((unsigned char)string[offset]) || !isxdigit((unsigned char)string[offset + 1])) {
            return false;
        }
        if (index < 5 && string[offset + 2] != ':') {
            return false;
        }

        char pair[3] = {string[offset], string[offset + 1], '\0'};
        bytes[index] = (unsigned char)strtoul(pair, NULL, 16);
    }
    return true;
}

static void cm_configure_features(dnssd_t *dnssd, bool legacy_pairing) {
    const int features[32] = {
        0, 1, 1, 0, 0, 1, 1, 1,
        0, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 0,
        0, 1, 0, legacy_pairing ? 1 : 0, 1, 0, 1, 0
    };

    for (int bit = 0; bit < 32; bit++) {
        dnssd_set_airplay_features(dnssd, bit, features[bit]);
    }
    dnssd_set_airplay_features(dnssd, 42, 0);
}

static void cm_connection_init(void *context) {
    cm_receiver_t *receiver = context;
    if (!receiver) return;
    atomic_fetch_add_explicit(&receiver->open_connections, 1, memory_order_relaxed);
}

static void cm_connection_destroy(void *context) {
    cm_receiver_t *receiver = context;
    if (!receiver) return;

    const int remaining = atomic_fetch_sub_explicit(
        &receiver->open_connections,
        1,
        memory_order_relaxed
    ) - 1;

    if (remaining <= 0) {
        atomic_store_explicit(&receiver->open_connections, 0, memory_order_relaxed);
        pthread_mutex_lock(&receiver->client_lock);
        receiver->active_device_id[0] = '\0';
        pthread_mutex_unlock(&receiver->client_lock);
        atomic_store_explicit(&receiver->streaming_started, false, memory_order_relaxed);
        cm_emit_state(receiver, CM_RECEIVER_STATE_READY, 0, "Waiting for a device");
    }
}

static void cm_connection_feedback(void *context) {
    (void)context;
}

static void cm_connection_reset(void *context, int reason) {
    cm_receiver_t *receiver = context;
    if (receiver) {
        atomic_store_explicit(&receiver->streaming_started, false, memory_order_relaxed);
        /*
         * A dropped mirror socket may leave one or more RTSP helper sockets
         * alive for a while. Do not let that stale connection keep ownership
         * of the receiver and reject the client's immediate retry.
         */
        pthread_mutex_lock(&receiver->client_lock);
        receiver->active_device_id[0] = '\0';
        pthread_mutex_unlock(&receiver->client_lock);
    }
    cm_emit_state(receiver, CM_RECEIVER_STATE_INTERRUPTED, reason, "AirPlay connection interrupted");
}

static void cm_video_reset(void *context, reset_type_t reset_type) {
    cm_receiver_t *receiver = context;
    (void)reset_type;
    cm_emit_state(receiver, CM_RECEIVER_STATE_INTERRUPTED, 0, "Video stream reset");
}

static void cm_report_client_request(
    void *context,
    char *device_id,
    char *model,
    char *name,
    bool *admit
) {
    cm_receiver_t *receiver = context;
    if (!receiver || !admit) return;

    const char *safe_device_id = device_id ? device_id : "";
    bool is_existing_client = false;

    pthread_mutex_lock(&receiver->client_lock);
    if (receiver->active_device_id[0] != '\0') {
        is_existing_client = strcmp(receiver->active_device_id, safe_device_id) == 0;
        if (!is_existing_client) {
            *admit = false;
            pthread_mutex_unlock(&receiver->client_lock);
            return;
        }
    }
    pthread_mutex_unlock(&receiver->client_lock);

    bool accepted = true;
    if (!is_existing_client && receiver->callbacks.on_connection_request) {
        accepted = receiver->callbacks.on_connection_request(
            receiver->callbacks.context,
            safe_device_id,
            model ? model : "",
            name ? name : "Unknown device"
        );
    }

    *admit = accepted;
    if (!accepted) return;

    pthread_mutex_lock(&receiver->client_lock);
    snprintf(receiver->active_device_id, sizeof(receiver->active_device_id), "%s", safe_device_id);
    pthread_mutex_unlock(&receiver->client_lock);
    cm_emit_state(receiver, CM_RECEIVER_STATE_CLIENT_CONNECTED, 0, name ? name : "Device connected");
}

static void cm_display_pin(void *context, char *pin) {
    cm_receiver_t *receiver = context;
    if (receiver && receiver->callbacks.on_pin) {
        receiver->callbacks.on_pin(receiver->callbacks.context, pin ? pin : "");
    }
}

static const char *cm_password(void *context, int *length) {
    cm_receiver_t *receiver = context;
    if (!length) return NULL;
    *length = receiver && receiver->require_pin_each_connection ? -1 : 0;
    return NULL;
}

static int cm_video_set_codec(void *context, video_codec_t codec) {
    cm_receiver_t *receiver = context;
    if (!receiver) return -1;
    if (codec != VIDEO_CODEC_H264) return -1;
    atomic_store_explicit(&receiver->video_codec, CM_VIDEO_CODEC_H264, memory_order_relaxed);
    return 0;
}

static void cm_video_process(void *context, raop_ntp_t *ntp, video_decode_struct *data) {
    (void)ntp;
    cm_receiver_t *receiver = context;
    if (!receiver || !data || !data->data || data->data_len <= 0) return;

    if (receiver->callbacks.on_video) {
        receiver->callbacks.on_video(
            receiver->callbacks.context,
            (cm_video_codec_t)atomic_load_explicit(&receiver->video_codec, memory_order_relaxed),
            data->data,
            (size_t)data->data_len,
            data->nal_count,
            data->ntp_time_local,
            data->ntp_time_remote
        );
    }
    const bool was_streaming = atomic_exchange_explicit(
        &receiver->streaming_started,
        true,
        memory_order_relaxed
    );
    if (!was_streaming) {
        cm_emit_state(receiver, CM_RECEIVER_STATE_STREAMING, 0, "Receiving video");
    }
}

static void cm_audio_get_format(
    void *context,
    unsigned char *compression_type,
    unsigned short *samples_per_frame,
    bool *using_screen,
    bool *is_media,
    uint64_t *audio_format
) {
    cm_receiver_t *receiver = context;
    if (!receiver || !receiver->callbacks.on_audio_format) return;
    receiver->callbacks.on_audio_format(
        receiver->callbacks.context,
        compression_type ? *compression_type : 0,
        samples_per_frame ? *samples_per_frame : 0,
        using_screen ? *using_screen : false,
        is_media ? *is_media : false,
        audio_format ? *audio_format : 0
    );
}

static void cm_audio_process(void *context, raop_ntp_t *ntp, audio_decode_struct *data) {
    (void)ntp;
    cm_receiver_t *receiver = context;
    if (!receiver || !receiver->audio_enabled || !data || !data->data || data->data_len <= 0) return;
    if (!receiver->callbacks.on_audio) return;

    receiver->callbacks.on_audio(
        receiver->callbacks.context,
        data->ct,
        data->data,
        (size_t)data->data_len,
        data->seqnum,
        data->rtp_time,
        data->ntp_time_local,
        data->ntp_time_remote
    );
}

static void cm_video_report_size(
    void *context,
    float *source_width,
    float *source_height,
    float *display_width,
    float *display_height
) {
    cm_receiver_t *receiver = context;
    if (!receiver || !receiver->callbacks.on_video_size) return;
    receiver->callbacks.on_video_size(
        receiver->callbacks.context,
        source_width ? *source_width : 0,
        source_height ? *source_height : 0,
        display_width ? *display_width : 0,
        display_height ? *display_height : 0
    );
}

static void cm_noop(void *context) { (void)context; }
static void cm_set_volume(void *context, float volume) { (void)context; (void)volume; }
static double cm_client_volume(void *context) { (void)context; return 0.0; }

cm_receiver_t *cm_receiver_create(cm_receiver_callbacks_t callbacks) {
    cm_receiver_t *receiver = calloc(1, sizeof(cm_receiver_t));
    if (!receiver) return NULL;
    receiver->callbacks = callbacks;
    atomic_init(&receiver->running, false);
    atomic_init(&receiver->streaming_started, false);
    atomic_init(&receiver->open_connections, 0);
    atomic_init(&receiver->video_codec, CM_VIDEO_CODEC_H264);
    pthread_mutex_init(&receiver->client_lock, NULL);
    return receiver;
}

int cm_receiver_start(cm_receiver_t *receiver, const cm_receiver_configuration_t *configuration) {
    if (!receiver || !configuration || !configuration->receiver_name || !configuration->device_id) return -1;
    if (atomic_load_explicit(&receiver->running, memory_order_acquire)) return -2;

    unsigned char device_id[6];
    if (!cm_parse_device_id(configuration->device_id, device_id)) return -3;

    cm_emit_state(receiver, CM_RECEIVER_STATE_STARTING, 0, "Starting receiver");
    const bool peer_to_peer_enabled = configuration->peer_to_peer_enabled;
    receiver->require_pin_each_connection = configuration->require_pin_each_connection && !peer_to_peer_enabled;
    receiver->audio_enabled = configuration->audio_enabled;

    int dnssd_error = 0;
    const unsigned char pin_mode = peer_to_peer_enabled
        ? 1
        : (configuration->require_pin_each_connection ? 3 : 0);
    receiver->dnssd = dnssd_init(
        configuration->receiver_name,
        (int)strlen(configuration->receiver_name),
        (const char *)device_id,
        6,
        &dnssd_error,
        pin_mode
    );
    if (!receiver->dnssd || dnssd_error) {
        cm_emit_state(receiver, CM_RECEIVER_STATE_FAILED, dnssd_error, "Bonjour initialization failed");
        cm_receiver_stop(receiver);
        return -4;
    }
#if defined(__APPLE__) && defined(UXPLAY_HAVE_APPLE_P2P)
    dnssd_set_peer_to_peer(receiver->dnssd, peer_to_peer_enabled ? 1 : 0);
#endif
    cm_configure_features(receiver->dnssd, peer_to_peer_enabled);

    raop_callbacks_t callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.cls = receiver;
    callbacks.conn_init = cm_connection_init;
    callbacks.conn_destroy = cm_connection_destroy;
    callbacks.conn_reset = cm_connection_reset;
    callbacks.conn_feedback = cm_connection_feedback;
    callbacks.video_reset = cm_video_reset;
    callbacks.audio_process = cm_audio_process;
    callbacks.video_process = cm_video_process;
    callbacks.audio_flush = cm_noop;
    callbacks.video_flush = cm_noop;
    callbacks.video_pause = cm_noop;
    callbacks.video_resume = cm_noop;
    callbacks.audio_set_client_volume = cm_client_volume;
    callbacks.audio_set_volume = cm_set_volume;
    callbacks.audio_get_format = cm_audio_get_format;
    callbacks.video_report_size = cm_video_report_size;
    callbacks.report_client_request = cm_report_client_request;
    callbacks.display_pin = cm_display_pin;
    callbacks.passwd = cm_password;
    callbacks.video_set_codec = cm_video_set_codec;

    receiver->raop = raop_init(&callbacks);
    if (!receiver->raop) {
        cm_emit_state(receiver, CM_RECEIVER_STATE_FAILED, -5, "RAOP initialization failed");
        cm_receiver_stop(receiver);
        return -5;
    }
    raop_set_log_callback(receiver->raop, cm_log, receiver);
    raop_set_log_level(receiver->raop, 6);

    if (raop_init2(receiver->raop, 0, configuration->device_id, "")) {
        cm_emit_state(receiver, CM_RECEIVER_STATE_FAILED, -6, "RAOP security initialization failed");
        cm_receiver_stop(receiver);
        return -6;
    }

    if (configuration->width) raop_set_plist(receiver->raop, "width", configuration->width);
    if (configuration->height) raop_set_plist(receiver->raop, "height", configuration->height);
    if (configuration->refresh_rate) raop_set_plist(receiver->raop, "refreshRate", configuration->refresh_rate);
    if (configuration->max_fps) raop_set_plist(receiver->raop, "maxFPS", configuration->max_fps);
    raop_set_plist(receiver->raop, "overscanned", 0);
    if (peer_to_peer_enabled) raop_set_plist(receiver->raop, "pin", 0);

    unsigned short tcp_ports[2] = {0, 0};
    unsigned short udp_ports[3] = {0, 0, 0};
    raop_set_tcp_ports(receiver->raop, tcp_ports);
    raop_set_udp_ports(receiver->raop, udp_ports);

    receiver->port = raop_get_port(receiver->raop);
    /* UxPlay's httpd_start returns 1 on success and a negative value on failure. */
    if (raop_start_httpd(receiver->raop, &receiver->port) <= 0) {
        cm_emit_state(receiver, CM_RECEIVER_STATE_FAILED, -7, "RAOP listener failed to start");
        cm_receiver_stop(receiver);
        return -7;
    }
    raop_set_port(receiver->raop, receiver->port);
    raop_set_dnssd(receiver->raop, receiver->dnssd);

    int error = dnssd_register_raop(receiver->dnssd, receiver->port);
    if (!error) error = dnssd_register_airplay(receiver->dnssd, receiver->port);
    if (error) {
        cm_emit_state(receiver, CM_RECEIVER_STATE_FAILED, error, "Bonjour service registration failed");
        cm_receiver_stop(receiver);
        return -8;
    }

    atomic_store_explicit(&receiver->running, true, memory_order_release);
    cm_emit_state(receiver, CM_RECEIVER_STATE_READY, 0, configuration->receiver_name);
    return 0;
}

void cm_receiver_stop(cm_receiver_t *receiver) {
    if (!receiver) return;
    atomic_store_explicit(&receiver->running, false, memory_order_release);

    if (receiver->dnssd) {
        dnssd_unregister_raop(receiver->dnssd);
        dnssd_unregister_airplay(receiver->dnssd);
    }
    if (receiver->raop) {
        raop_destroy(receiver->raop);
        receiver->raop = NULL;
    }
    if (receiver->dnssd) {
        dnssd_destroy(receiver->dnssd);
        receiver->dnssd = NULL;
    }
    receiver->port = 0;
    atomic_store_explicit(&receiver->open_connections, 0, memory_order_relaxed);
    atomic_store_explicit(&receiver->streaming_started, false, memory_order_relaxed);
    pthread_mutex_lock(&receiver->client_lock);
    receiver->active_device_id[0] = '\0';
    pthread_mutex_unlock(&receiver->client_lock);
    cm_emit_state(receiver, CM_RECEIVER_STATE_STOPPED, 0, "Receiver stopped");
}

void cm_receiver_disconnect(cm_receiver_t *receiver) {
    if (!receiver || !receiver->raop) return;
    atomic_store_explicit(&receiver->streaming_started, false, memory_order_relaxed);
    pthread_mutex_lock(&receiver->client_lock);
    receiver->active_device_id[0] = '\0';
    pthread_mutex_unlock(&receiver->client_lock);
    raop_remove_known_connections(receiver->raop);
}

bool cm_receiver_is_running(const cm_receiver_t *receiver) {
    return receiver && atomic_load_explicit(&receiver->running, memory_order_acquire);
}

uint16_t cm_receiver_port(const cm_receiver_t *receiver) {
    return receiver ? receiver->port : 0;
}

void cm_receiver_destroy(cm_receiver_t *receiver) {
    if (!receiver) return;
    cm_receiver_stop(receiver);
    pthread_mutex_destroy(&receiver->client_lock);
    free(receiver);
}

const char *cm_receiver_version(void) { return CM_CORE_VERSION; }
const char *cm_receiver_upstream_commit(void) { return CM_CORE_COMMIT; }
