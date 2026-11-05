#pragma once
int sensor_open(void);
int sensor_count(void);
int sensor_key(int index, char *key);
double sensor_read(const char *key);
void sensor_close(void);
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
