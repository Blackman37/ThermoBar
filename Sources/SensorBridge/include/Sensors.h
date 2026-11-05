#pragma once
#include <CoreFoundation/CoreFoundation.h>
// Stateful SMC and CPU functions have one owner: the sampler actor.
int sensor_open(void);
int sensor_count(void);
// key must point to a writable buffer of at least five bytes.
int sensor_key(int index, char *key);
double sensor_read(const char *key);
void sensor_close(void);
void cpu_usage_reset(void);
double cpu_usage(void);
double memory_used(void);
double memory_total(void);
double gpu_usage(void);
typedef struct {
    double battery_watts; // positive = into battery; negative = out of battery
    double adapter_watts; // measured DC input; NAN when unavailable
    double voltage;
    double amperage;
    double updated_unix;
    int external_connected; // -1 unknown, 0 battery, 1 external power
} PowerReading;
PowerReading power_read(void);

// Pure IORegistry decoding, shared by the live reader and fixture tests.
PowerReading power_from_properties(CFDictionaryRef properties);
