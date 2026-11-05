#include <CoreFoundation/CoreFoundation.h>

#include "Sensors.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <math.h>
#include <string.h>
#include <sys/sysctl.h>
// AppleSMC wire ABI: 80 bytes, data payload begins at byte 48.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version,length; uint32_t cpu,gpu,mem; } Limits;
typedef struct { uint32_t size,type; uint8_t attributes; } KeyInfo;
typedef struct { uint32_t key; Version version; Limits limits; KeyInfo info; uint8_t result,status,command; uint32_t index; uint8_t bytes[32]; } Packet;
_Static_assert(sizeof(Packet)==80,"SMC ABI");
_Static_assert(offsetof(Packet,bytes)==48,"SMC payload offset");
static io_connect_t connection;
// Key metadata is stable for a connection. Avoid a metadata request per sample.
static struct { uint32_t key, type, size; } metadata[512];
static size_t metadata_count;
static uint32_t code(const char *s) { return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16 | (uint32_t)(uint8_t)s[2]<<8 | (uint8_t)s[3]; }
static int call(Packet *in, Packet *out) { size_t size=sizeof(*out); return connection && IOConnectCallStructMethod(connection,2,in,sizeof(*in),out,&size)==KERN_SUCCESS && size==sizeof(*out) && out->result==0; }
int sensor_open(void) { io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC")); if(!service) return 0; kern_return_t result=IOServiceOpen(service,mach_task_self(),0,&connection); IOObjectRelease(service); return result==KERN_SUCCESS; }
void sensor_close(void) { if(connection) IOServiceClose(connection); connection=0; metadata_count=0; }
double sensor_read(const char *key) {
 if(!key || strlen(key)!=4) return NAN;
 Packet in={0},out={0}; in.key=code(key);
 uint32_t type=0, size=0;
 for(size_t i=0;i<metadata_count;i++) if(metadata[i].key==in.key) { type=metadata[i].type; size=metadata[i].size; break; }
 if(!size) {
   in.command=9;
   if(!call(&in,&out) || !out.info.size || out.info.size>32) return NAN;
   type=out.info.type; size=out.info.size;
   if(metadata_count<512) { metadata[metadata_count].key=in.key; metadata[metadata_count].type=type; metadata[metadata_count].size=size; metadata_count++; }
 }
 in.info.size=size; in.command=5; memset(&out,0,sizeof(out)); if(!call(&in,&out)) return NAN;
 uint8_t *b=out.bytes;
 if(type==code("flt ") && size==4) { float f; memcpy(&f,b,4); return isfinite(f)?f:NAN; }
 if(type==code("sp78") && size==2) return (int16_t)((b[0]<<8)|b[1])/256.0;
 if(type==code("fpe2") && size==2) return ((b[0]<<8)|b[1])/4.0;
 if(type==code("ui32") && size==4) return ((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|(b[2]<<8)|b[3];
 if(type==code("ui16") && size==2) return (b[0]<<8)|b[1];
 if(type==code("ui8 ") && size==1) return b[0];
 return NAN;
}
int sensor_count(void) { double n=sensor_read("#KEY"); return isfinite(n)&&n>0&&n<20000?(int)n:0; }
int sensor_key(int index,char *key) { Packet in={0},out={0}; in.command=8; in.index=index; if(!call(&in,&out)) return 0; for(int i=0;i<4;i++) key[i]=(out.key>>(24-8*i))&255; key[4]=0; return 1; }
double cpu_usage(void) { static uint64_t lastTotal=0,lastIdle=0; host_cpu_load_info_data_t info; mach_msg_type_number_t n=HOST_CPU_LOAD_INFO_COUNT; mach_port_t host=mach_host_self(); kern_return_t result=host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&info,&n); mach_port_deallocate(mach_task_self(),host); if(result!=KERN_SUCCESS) return NAN; uint64_t total=0; for(int i=0;i<CPU_STATE_MAX;i++)total+=info.cpu_ticks[i]; uint64_t idle=info.cpu_ticks[CPU_STATE_IDLE]; double value=lastTotal && total>lastTotal?100.0*(1.0-(double)(idle-lastIdle)/(total-lastTotal)):NAN; lastTotal=total;lastIdle=idle;return value; }
double memory_total(void) { uint64_t size=0; size_t n=sizeof(size); sysctlbyname("hw.memsize",&size,&n,0,0);return size; }
double memory_used(void) { vm_statistics64_data_t vm; mach_msg_type_number_t n=HOST_VM_INFO64_COUNT; mach_port_t host=mach_host_self(); kern_return_t result=host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&vm,&n); vm_size_t page=0;host_page_size(host,&page);mach_port_deallocate(mach_task_self(),host); if(result!=KERN_SUCCESS)return NAN;return ((double)vm.active_count+vm.wire_count+vm.compressor_page_count)*page; }
double gpu_usage(void) { io_iterator_t iterator; if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOAccelerator"),&iterator)!=KERN_SUCCESS)return NAN; double result=NAN; io_service_t service; while((service=IOIteratorNext(iterator))) { CFTypeRef stats=IORegistryEntryCreateCFProperty(service,CFSTR("PerformanceStatistics"),kCFAllocatorDefault,0); if(stats && CFGetTypeID(stats)==CFDictionaryGetTypeID()) { CFNumberRef value=CFDictionaryGetValue(stats,CFSTR("Device Utilization %")); if(value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue(value,kCFNumberDoubleType,&result); } if(stats)CFRelease(stats);IOObjectRelease(service); } IOObjectRelease(iterator);return result; }

static double dictionary_number(CFDictionaryRef dictionary, CFStringRef key) {
 if(!dictionary || CFGetTypeID(dictionary)!=CFDictionaryGetTypeID()) return NAN;
 CFTypeRef value=CFDictionaryGetValue(dictionary,key);
 double result=NAN;
 if(value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue(value,kCFNumberDoubleType,&result);
 return result;
}
static PowerReading power_from_properties(CFDictionaryRef properties) {
 PowerReading r={NAN,NAN,NAN,NAN,NAN,-1};
 if(!properties) return r;
 CFTypeRef external=CFDictionaryGetValue(properties,CFSTR("ExternalConnected"));
 if(external && CFGetTypeID(external)==CFBooleanGetTypeID()) r.external_connected=CFBooleanGetValue(external)?1:0;
 double mv=dictionary_number(properties,CFSTR("Voltage"));
 // Read as a signed integer first: IORegistry can serialize negative current as uint64.
 CFTypeRef value=CFDictionaryGetValue(properties,CFSTR("InstantAmperage"));
 if(!value) value=CFDictionaryGetValue(properties,CFSTR("Amperage"));
 int64_t signed_ma=0;
 if(value && CFGetTypeID(value)==CFNumberGetTypeID() && CFNumberGetValue(value,kCFNumberSInt64Type,&signed_ma)) {
   // Some drivers expose a wrapped 32-bit signed value instead.
   if(signed_ma>=INT64_C(2147483648) && signed_ma<=INT64_C(4294967295)) signed_ma-=INT64_C(4294967296);
   if(isfinite(mv) && mv>=1000 && mv<=30000 && signed_ma>=-30000 && signed_ma<=30000) {
     r.voltage=mv/1000.0; r.amperage=signed_ma/1000.0;
     r.battery_watts=r.voltage*r.amperage;
   }
 }
 r.updated_unix=dictionary_number(properties,CFSTR("UpdateTime"));
 if(r.external_connected==0) r.adapter_watts=0;
 if(r.external_connected==1) {
   CFTypeRef telemetry=CFDictionaryGetValue(properties,CFSTR("PowerTelemetryData"));
   if(telemetry && CFGetTypeID(telemetry)==CFDictionaryGetTypeID()) {
     double mw=dictionary_number((CFDictionaryRef)telemetry,CFSTR("SystemPowerIn"));
     if(isfinite(mw) && mw>=0 && mw<=1000000) r.adapter_watts=mw/1000.0;
   }
 }
 return r;
}
PowerReading power_read(void) {
 PowerReading result={NAN,NAN,NAN,NAN,NAN,-1};
 io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSmartBattery"));
 if(!service) return result;
 CFMutableDictionaryRef properties=NULL;
 if(IORegistryEntryCreateCFProperties(service,&properties,kCFAllocatorDefault,0)==KERN_SUCCESS && properties) result=power_from_properties(properties);
 if(properties) CFRelease(properties);
 IOObjectRelease(service);
 return result;
}
