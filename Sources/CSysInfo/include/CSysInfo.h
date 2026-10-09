#ifndef CSYSINFO_H
#define CSYSINFO_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Process enumeration (sysctl kern.proc.all) — readable for every process.

typedef struct {
    int32_t pid;
    int32_t ppid;
    int32_t pgid;
    int32_t sessionLeaderPid;
    uint32_t uid;       // effective
    uint32_t ruid;
    uint32_t svuid;
    uint32_t rgid;
    uint32_t svgid;
    int32_t status;     // SIDL, SRUN, SSLEEP, SSTOP, SZOMB
    uint32_t flags;     // P_* flags
    int32_t nice;
    int32_t tdev;       // controlling terminal, -1 if none
    int64_t startSec;
    int64_t startUsec;
    char comm[17];
} si_kinfo;

/// Returns number of entries written into a malloc'd array (caller frees), or -errno.
int si_list_kinfo(si_kinfo **out);

/// Raw KERN_PROCARGS2 buffer. Returns length (>0) or -errno. Caller frees *out.
int si_proc_args_raw(pid_t pid, char **out);

// ---------------------------------------------------------------------------
// Per-process task statistics (proc_pidinfo + proc_pid_rusage).
// Requires same user or root.

typedef struct {
    int32_t hasTaskInfo;
    int32_t hasRusage;
    int32_t hasBsdInfo;

    // proc_taskinfo
    uint64_t virtualSize;
    uint64_t residentSize;
    uint64_t userTimeNs;
    uint64_t systemTimeNs;
    int32_t threadCount;
    int32_t runningThreads;
    int32_t priority;
    int32_t faults;
    int32_t pageins;
    int32_t cowFaults;
    int32_t messagesSent;
    int32_t messagesReceived;
    int32_t syscallsMach;
    int32_t syscallsUnix;
    int32_t contextSwitches;

    // proc_bsdinfo
    uint32_t bsdFlags;
    int32_t nice;
    uint32_t openFiles;   // pbi_nfiles (max fd)

    // rusage_info_v6
    uint64_t physFootprint;
    uint64_t lifetimeMaxFootprint;
    uint64_t wiredSize;
    uint64_t diskBytesRead;
    uint64_t diskBytesWritten;
    uint64_t logicalWrites;
    uint64_t instructions;
    uint64_t cycles;
    uint64_t energyNj;
    uint64_t billedEnergy;
    uint64_t idleWakeups;
    uint64_t interruptWakeups;
    uint64_t pageinsRU;
    uint64_t runnableTimeNs;
    uint64_t qosDefaultNs;
    uint64_t qosBackgroundNs;
    uint64_t qosUserInteractiveNs;
    uint64_t neuralFootprint;
    uint64_t pcpuInstructions;
    uint64_t pcpuCycles;
    uint64_t ecpuInstructions;  // efficiency cores (derived)
    uint64_t pTimeNs;           // time on performance cores
    uint64_t procStartAbs;

    // task_info(TASK_VM_INFO) through the task's name port (same user or root)
    int32_t hasVmInfo;
    uint64_t compressed;        // bytes held in the compressor for the task
    uint64_t purgeableVolatile; // volatile purgeable memory charged to the task
} si_task_stats;

int si_task_stats_for_pid(pid_t pid, si_task_stats *out);

/// One process's jetsam (memory pressure) priority band and memory limit.
typedef struct {
    int32_t pid;
    int32_t priority;
    int32_t limitMB;            // -1 when there is no limit
} si_jetsam_entry;

/// Every process's jetsam priority and limit (memorystatus_control). Root only. Returns the number
/// of entries in a malloc'd array (caller frees), or -errno.
int si_jetsam_list(si_jetsam_entry **out);

/// Current working directory. Returns 0 on success, -errno on failure.
int si_pid_cwd(pid_t pid, char *buf, int size);

/// Number of open file descriptors, or -errno.
int si_fd_count(pid_t pid);

// ---------------------------------------------------------------------------
// File descriptors

typedef struct {
    int32_t fd;
    uint32_t fdType;        // PROX_FDTYPE_*
    uint32_t openFlags;
    int64_t offset;
    char path[1024];        // vnode path, unix socket path, pipe/kqueue description
    // vnode
    int32_t vnodeType;      // VREG, VDIR, ...
    int64_t vnodeSize;
    // socket
    int32_t family;         // AF_INET, AF_INET6, AF_UNIX, ...
    int32_t sockType;       // SOCK_STREAM, SOCK_DGRAM, ...
    int32_t protocol;       // IPPROTO_TCP ...
    int32_t sockKind;       // SOCKINFO_*
    int32_t tcpState;       // TSI_S_* or -1
    uint16_t localPort;
    uint16_t remotePort;
    uint8_t localAddr[16];
    uint8_t remoteAddr[16];
    uint8_t isIPv6;
    uint32_t sendQueue;
    uint32_t recvQueue;
} si_fd_info;

/// Fills up to max entries. Returns count, or -errno.
int si_pid_fds(pid_t pid, si_fd_info *out, int max, int socketsOnly);

// ---------------------------------------------------------------------------
// Threads

typedef struct {
    uint64_t threadId;
    uint64_t userTimeNs;
    uint64_t systemTimeNs;
    int32_t cpuUsage;       // scaled, TH_USAGE_SCALE = 1000
    int32_t policy;
    int32_t runState;       // TH_STATE_*
    int32_t flags;          // TH_FLAGS_*
    int32_t sleepTime;
    int32_t currentPriority;
    int32_t priority;
    int32_t maxPriority;
    char name[64];
} si_thread_info;

int si_pid_threads(pid_t pid, si_thread_info *out, int max);

// ---------------------------------------------------------------------------
// Virtual memory regions (proc_pidinfo PROC_PIDREGIONPATHINFO)

typedef struct {
    uint64_t address;
    uint64_t size;
    uint64_t offset;
    uint32_t protection;
    uint32_t maxProtection;
    uint32_t userTag;
    uint32_t shareMode;
    uint32_t pagesResident;
    uint32_t pagesSwappedOut;
    uint32_t pagesDirtied;
    uint32_t privatePagesResident;
    uint32_t sharedPagesResident;
    uint32_t depth;
    uint32_t isSubmap;
    char path[1024];
} si_region_info;

/// Fills up to max regions. Returns count, or -errno.
int si_pid_regions(pid_t pid, si_region_info *out, int max);

// ---------------------------------------------------------------------------
// Security

/// Code-signing status flags via csops(CS_OPS_STATUS). Returns 0 on success.
int si_cs_status(pid_t pid, uint32_t *flags);
/// 1 sandboxed, 0 not, -1 unknown.
int si_is_sandboxed(pid_t pid);
/// Responsible process (the app that launched an XPC service etc), or -1.
pid_t si_responsible_pid(pid_t pid);

// ---------------------------------------------------------------------------
// Host statistics

typedef struct {
    uint64_t user, system, idle, nice;
} si_cpu_ticks;

/// Fills per-cpu tick counters. Returns number of CPUs, or -1.
int si_cpu_ticks_per_core(si_cpu_ticks *out, int max);

typedef struct {
    uint64_t pageSize;
    uint64_t totalBytes;
    uint64_t freePages;
    uint64_t activePages;
    uint64_t inactivePages;
    uint64_t wiredPages;
    uint64_t speculativePages;
    uint64_t compressorPages;      // pages occupied by compressor
    uint64_t compressedPages;      // pages stored in compressor (uncompressed size)
    uint64_t purgeablePages;
    uint64_t externalPages;        // file-backed
    uint64_t internalPages;        // anonymous
    uint64_t pageins, pageouts, faults, cowFaults, compressions, decompressions, swapins, swapouts;
    uint64_t swapTotal, swapUsed;
    int32_t pressureLevel;         // kern.memorystatus_vm_pressure_level (1 normal, 2 warn, 4 critical)
} si_vm_stats;

int si_vm_statistics(si_vm_stats *out);

typedef struct {
    char name[32];
    uint32_t flags;
    uint8_t type;
    uint64_t ibytes, obytes, ipackets, opackets, ierrors, oerrors;
    uint64_t baudrate;
} si_netif;

/// Returns number of interfaces, or -1.
int si_net_interfaces(si_netif *out, int max);

typedef struct {
    uint64_t bytesRead, bytesWritten, opsRead, opsWritten, timeReadNs, timeWriteNs;
} si_disk_io;

int si_disk_io_totals(si_disk_io *out);

/// Machine boot time (seconds since epoch).
int64_t si_boot_time(void);

/// mach_absolute_time units to nanoseconds.
uint64_t si_abs_to_ns(uint64_t abs);

#ifdef __cplusplus
}
#endif

#endif
