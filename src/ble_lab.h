// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef PLANK_BLE_LAB_H
#define PLANK_BLE_LAB_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PltrBleLab PltrBleLab;
PltrBleLab *pltr_ble_lab_create(const char *directory);
void pltr_ble_lab_destroy(PltrBleLab *lab);
int pltr_ble_lab_open_pairing(PltrBleLab *lab, uint64_t wall_seconds, uint64_t now_ms);
void pltr_ble_lab_disconnect(PltrBleLab *lab, uint64_t now_ms);
int pltr_ble_lab_receive(PltrBleLab *lab, const uint8_t *data, size_t size,
    size_t *consumed, uint64_t now_ms, uint8_t *out, size_t capacity, size_t *written);
int pltr_ble_lab_key(PltrBleLab *lab, uint8_t key, uint64_t now_ms,
    uint8_t *out, size_t capacity, size_t *written);
void pltr_ble_lab_tablet(PltrBleLab *lab, int attached);
int pltr_ble_lab_button(PltrBleLab *lab, uint16_t code, int value,
    uint64_t wall_seconds, uint64_t now_ms,
    uint8_t *out, size_t capacity, size_t *written);
int pltr_ble_lab_tick(PltrBleLab *lab, uint64_t now_ms,
    uint8_t *out, size_t capacity, size_t *written);
int pltr_ble_lab_observing(const PltrBleLab *lab);
int pltr_ble_lab_has_clients(const PltrBleLab *lab);
int pltr_ble_lab_reset_clients(PltrBleLab *lab);
// Copy one authenticated management request; no input/report privileges implied.
int pltr_ble_lab_take_management(PltrBleLab *lab, uint8_t *out, size_t capacity);
int pltr_ble_lab_management_reply(PltrBleLab *lab, const uint8_t *payload, size_t size,
    uint8_t *out, size_t capacity, size_t *written);
// Local diagnostic state only: 0 = not waiting, 1 = new Client, 2 = known Client.
int pltr_ble_lab_approval_pending(const PltrBleLab *lab);
int pltr_ble_lab_sample(PltrBleLab *lab, const uint8_t *payload, size_t size,
    uint8_t *out, size_t capacity, size_t *written);
#ifdef __cplusplus
}
#endif
#endif
