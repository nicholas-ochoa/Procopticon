#include "CSysInfo.h"

#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <sys/vnode.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>

// Private libproc flavors (stable since 10.x).
#ifndef PROC_PIDLISTTHREADIDS
#define PROC_PIDLISTTHREADIDS 28
#endif
#ifndef PROC_PIDTHREADID64INFO
#define PROC_PIDTHREADID64INFO 15
#endif

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

// ---------------------------------------------------------------------------

static mach_timebase_info_data_t g_timebase;

uint64_t si_abs_to_ns(uint64_t abs) {
    if (g_timebase.denom == 0) {
        mach_timebase_info(&g_timebase);
    }
    if (g_timebase.numer == g_timebase.denom) {
        return abs;
    }
    return (uint64_t)((__uint128_t)abs * g_timebase.numer / g_timebase.denom);
}

int si_list_kinfo(si_kinfo **out) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    struct kinfo_proc *procs = NULL;
    for (int attempt = 0; attempt < 8; attempt++) {
        if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
            return -errno;
        }
        size += size / 8 + sizeof(struct kinfo_proc) * 16;
        struct kinfo_proc *buf = realloc(procs, size);
        if (!buf) {
            free(procs);
            return -ENOMEM;
        }
        procs = buf;
        if (sysctl(mib, 3, procs, &size, NULL, 0) == 0) {
            break;
        }
        if (errno != ENOMEM) {
            free(procs);
            return -errno;
        }
    }
    int count = (int)(size / sizeof(struct kinfo_proc));
    si_kinfo *result = calloc((size_t)(count > 0 ? count : 1), sizeof(si_kinfo));
    if (!result) {
        free(procs);
        return -ENOMEM;
    }
    for (int i = 0; i < count; i++) {
        struct kinfo_proc *kp = &procs[i];
        si_kinfo *k = &result[i];
        k->pid = kp->kp_proc.p_pid;
        k->ppid = kp->kp_eproc.e_ppid;
        k->pgid = kp->kp_eproc.e_pgid;
        k->sessionLeaderPid = 0;
        k->uid = kp->kp_eproc.e_ucred.cr_uid;
        k->ruid = kp->kp_eproc.e_pcred.p_ruid;
        k->svuid = kp->kp_eproc.e_pcred.p_svuid;
        k->rgid = kp->kp_eproc.e_pcred.p_rgid;
        k->svgid = kp->kp_eproc.e_pcred.p_svgid;
        k->status = kp->kp_proc.p_stat;
        k->flags = (uint32_t)kp->kp_proc.p_flag;
        k->nice = kp->kp_proc.p_nice;
        k->tdev = kp->kp_eproc.e_tdev;
        k->startSec = kp->kp_proc.p_starttime.tv_sec;
        k->startUsec = kp->kp_proc.p_starttime.tv_usec;
        strlcpy(k->comm, kp->kp_proc.p_comm, sizeof(k->comm));
    }
    free(procs);
    *out = result;
    return count;
}

int si_proc_args_raw(pid_t pid, char **out) {
    int argmax = 0;
    int mib[3] = {CTL_KERN, KERN_ARGMAX, 0};
    size_t size = sizeof(argmax);
    if (sysctl(mib, 2, &argmax, &size, NULL, 0) != 0 || argmax <= 0) {
        argmax = 1024 * 1024;
    }
    char *buf = malloc((size_t)argmax);
    if (!buf) {
        return -ENOMEM;
    }
    int mib2[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size = (size_t)argmax;
    if (sysctl(mib2, 3, buf, &size, NULL, 0) != 0) {
        int err = errno;
        free(buf);
        return -err;
    }
    *out = buf;
    return (int)size;
}

int si_task_stats_for_pid(pid_t pid, si_task_stats *out) {
    memset(out, 0, sizeof(*out));
    struct proc_taskallinfo ti;
    int r = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &ti, sizeof(ti));
    if (r == (int)sizeof(ti)) {
        out->hasTaskInfo = 1;
        out->hasBsdInfo = 1;
        struct proc_taskinfo *t = &ti.ptinfo;
        out->virtualSize = t->pti_virtual_size;
        out->residentSize = t->pti_resident_size;
        out->userTimeNs = si_abs_to_ns(t->pti_total_user);
        out->systemTimeNs = si_abs_to_ns(t->pti_total_system);
        out->threadCount = t->pti_threadnum;
        out->runningThreads = t->pti_numrunning;
        out->priority = t->pti_priority;
        out->faults = t->pti_faults;
        out->pageins = t->pti_pageins;
        out->cowFaults = t->pti_cow_faults;
        out->messagesSent = t->pti_messages_sent;
        out->messagesReceived = t->pti_messages_received;
        out->syscallsMach = t->pti_syscalls_mach;
        out->syscallsUnix = t->pti_syscalls_unix;
        out->contextSwitches = t->pti_csw;
        out->bsdFlags = ti.pbsd.pbi_flags;
        out->nice = ti.pbsd.pbi_nice;
        out->openFiles = ti.pbsd.pbi_nfiles;
    } else {
        struct proc_bsdinfo bi;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof(bi)) == (int)sizeof(bi)) {
            out->hasBsdInfo = 1;
            out->bsdFlags = bi.pbi_flags;
            out->nice = bi.pbi_nice;
            out->openFiles = bi.pbi_nfiles;
        }
    }

    struct rusage_info_v6 ru;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru) == 0) {
        out->hasRusage = 1;
        out->physFootprint = ru.ri_phys_footprint;
        out->lifetimeMaxFootprint = ru.ri_lifetime_max_phys_footprint;
        out->wiredSize = ru.ri_wired_size;
        out->diskBytesRead = ru.ri_diskio_bytesread;
        out->diskBytesWritten = ru.ri_diskio_byteswritten;
        out->logicalWrites = ru.ri_logical_writes;
        out->instructions = ru.ri_instructions;
        out->cycles = ru.ri_cycles;
        out->energyNj = ru.ri_energy_nj;
        out->billedEnergy = ru.ri_billed_energy;
        out->idleWakeups = ru.ri_pkg_idle_wkups;
        out->interruptWakeups = ru.ri_interrupt_wkups;
        out->pageinsRU = ru.ri_pageins;
        out->runnableTimeNs = si_abs_to_ns(ru.ri_runnable_time);
        out->qosDefaultNs = si_abs_to_ns(ru.ri_cpu_time_qos_default);
        out->qosBackgroundNs = si_abs_to_ns(ru.ri_cpu_time_qos_background + ru.ri_cpu_time_qos_maintenance);
        out->qosUserInteractiveNs = si_abs_to_ns(ru.ri_cpu_time_qos_user_interactive);
        out->neuralFootprint = ru.ri_neural_footprint;
        out->pcpuInstructions = ru.ri_pinstructions;
        out->pcpuCycles = ru.ri_pcycles;
        out->ecpuInstructions = ru.ri_instructions > ru.ri_pinstructions ? ru.ri_instructions - ru.ri_pinstructions : 0;
        out->pTimeNs = si_abs_to_ns(ru.ri_user_ptime + ru.ri_system_ptime);
        out->procStartAbs = ru.ri_proc_start_abstime;
        if (!out->hasTaskInfo) {
            out->userTimeNs = si_abs_to_ns(ru.ri_user_time);
            out->systemTimeNs = si_abs_to_ns(ru.ri_system_time);
            out->residentSize = ru.ri_resident_size;
        }
    }

    // The name port is enough for TASK_VM_INFO, and unlike the task port it's granted for any
    // process of the same user (or any process to root), Apple's included.
    mach_port_t task = MACH_PORT_NULL;
    if (pid > 0 && task_name_for_pid(mach_task_self(), pid, &task) == KERN_SUCCESS) {
        task_vm_info_data_t vm;
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        if (task_info(task, TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS) {
            out->hasVmInfo = 1;
            out->compressed = vm.compressed;
            if (count >= TASK_VM_INFO_REV2_COUNT) {
                out->purgeableVolatile = vm.ledger_purgeable_volatile;
            }
        }
        mach_port_deallocate(mach_task_self(), task);
    }
    return (out->hasTaskInfo || out->hasRusage || out->hasBsdInfo) ? 0 : -EPERM;
}

// Private (sys/kern_memorystatus.h); exported by libsystem_kernel.
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define SI_MEMORYSTATUS_CMD_GET_PRIORITY_LIST 1

typedef struct {
    int32_t pid;
    int32_t priority;
    uint64_t user_data;
    int32_t limit;
    uint32_t state;
} si_memorystatus_priority_entry;

int si_jetsam_list(si_jetsam_entry **out) {
    *out = NULL;
    int size = memorystatus_control(SI_MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, NULL, 0);
    if (size <= 0) {
        return size < 0 ? -errno : 0;
    }
    // Room for processes started since the size was asked for.
    size_t capacity = (size_t)size + 64 * sizeof(si_memorystatus_priority_entry);
    si_memorystatus_priority_entry *list = malloc(capacity);
    if (!list) {
        return -ENOMEM;
    }
    int got = memorystatus_control(SI_MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, list, capacity);
    if (got < 0) {
        int e = errno;
        free(list);
        return -e;
    }
    int n = got / (int)sizeof(si_memorystatus_priority_entry);
    si_jetsam_entry *result = calloc((size_t)(n > 0 ? n : 1), sizeof(si_jetsam_entry));
    if (!result) {
        free(list);
        return -ENOMEM;
    }
    for (int i = 0; i < n; i++) {
        result[i].pid = list[i].pid;
        result[i].priority = list[i].priority;
        result[i].limitMB = list[i].limit;
    }
    free(list);
    *out = result;
    return n;
}

int si_pid_cwd(pid_t pid, char *buf, int size) {
    struct proc_vnodepathinfo vpi;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi)) != (int)sizeof(vpi)) {
        return errno ? -errno : -EPERM;
    }
    strlcpy(buf, vpi.pvi_cdir.vip_path, (size_t)size);
    return 0;
}

int si_fd_count(pid_t pid) {
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) {
        return errno ? -errno : 0;
    }
    struct proc_fdinfo *fds = malloc((size_t)size);
    if (!fds) {
        return -ENOMEM;
    }
    int r = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
    free(fds);
    if (r <= 0) {
        return -errno;
    }
    return r / (int)sizeof(struct proc_fdinfo);
}

static void si_fill_socket(si_fd_info *info, struct socket_fdinfo *si) {
    struct socket_info *s = &si->psi;
    info->family = s->soi_family;
    info->sockType = s->soi_type;
    info->protocol = s->soi_protocol;
    info->sockKind = s->soi_kind;
    info->tcpState = -1;
    info->sendQueue = s->soi_snd.sbi_cc;
    info->recvQueue = s->soi_rcv.sbi_cc;

    struct in_sockinfo *ini = NULL;
    if (s->soi_kind == SOCKINFO_TCP) {
        ini = &s->soi_proto.pri_tcp.tcpsi_ini;
        info->tcpState = s->soi_proto.pri_tcp.tcpsi_state;
    } else if (s->soi_kind == SOCKINFO_IN) {
        ini = &s->soi_proto.pri_in;
    } else if (s->soi_kind == SOCKINFO_UN) {
        struct un_sockinfo *un = &s->soi_proto.pri_un;
        const struct sockaddr_un *addr = (const struct sockaddr_un *)&un->unsi_addr.ua_sun;
        if (addr->sun_path[0]) {
            strlcpy(info->path, addr->sun_path, sizeof(info->path));
        } else {
            const struct sockaddr_un *peer = (const struct sockaddr_un *)&un->unsi_caddr.ua_sun;
            if (peer->sun_path[0]) {
                strlcpy(info->path, peer->sun_path, sizeof(info->path));
            }
        }
    }
    if (ini) {
        info->localPort = ntohs((uint16_t)ini->insi_lport);
        info->remotePort = ntohs((uint16_t)ini->insi_fport);
        if (ini->insi_vflag & INI_IPV6) {
            info->isIPv6 = 1;
            memcpy(info->localAddr, &ini->insi_laddr.ina_6, 16);
            memcpy(info->remoteAddr, &ini->insi_faddr.ina_6, 16);
        } else {
            info->isIPv6 = 0;
            memcpy(info->localAddr, &ini->insi_laddr.ina_46.i46a_addr4, 4);
            memcpy(info->remoteAddr, &ini->insi_faddr.ina_46.i46a_addr4, 4);
        }
    }
}

int si_pid_fds(pid_t pid, si_fd_info *out, int max, int socketsOnly) {
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) {
        return errno ? -errno : 0;
    }
    size += 32 * (int)sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = malloc((size_t)size);
    if (!fds) {
        return -ENOMEM;
    }
    int r = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
    if (r <= 0) {
        int err = errno;
        free(fds);
        return -err;
    }
    int n = r / (int)sizeof(struct proc_fdinfo);
    int count = 0;
    for (int i = 0; i < n && count < max; i++) {
        struct proc_fdinfo *fd = &fds[i];
        if (socketsOnly && fd->proc_fdtype != PROX_FDTYPE_SOCKET) {
            continue;
        }
        si_fd_info *info = &out[count];
        memset(info, 0, sizeof(*info));
        info->fd = fd->proc_fd;
        info->fdType = fd->proc_fdtype;
        info->tcpState = -1;
        switch (fd->proc_fdtype) {
        case PROX_FDTYPE_VNODE: {
            struct vnode_fdinfowithpath vi;
            if (proc_pidfdinfo(pid, fd->proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, sizeof(vi)) == (int)sizeof(vi)) {
                strlcpy(info->path, vi.pvip.vip_path, sizeof(info->path));
                info->openFlags = vi.pfi.fi_openflags;
                info->offset = vi.pfi.fi_offset;
                info->vnodeType = vi.pvip.vip_vi.vi_type;
                info->vnodeSize = vi.pvip.vip_vi.vi_stat.vst_size;
            }
            break;
        }
        case PROX_FDTYPE_SOCKET: {
            struct socket_fdinfo si;
            if (proc_pidfdinfo(pid, fd->proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof(si)) == (int)sizeof(si)) {
                info->openFlags = si.pfi.fi_openflags;
                si_fill_socket(info, &si);
            }
            break;
        }
        case PROX_FDTYPE_PIPE: {
            struct pipe_fdinfo pi;
            if (proc_pidfdinfo(pid, fd->proc_fd, PROC_PIDFDPIPEINFO, &pi, sizeof(pi)) == (int)sizeof(pi)) {
                info->openFlags = pi.pfi.fi_openflags;
                snprintf(info->path, sizeof(info->path), "pipe 0x%llx -> 0x%llx (%u bytes buffered)",
                         (unsigned long long)pi.pipeinfo.pipe_handle, (unsigned long long)pi.pipeinfo.pipe_peerhandle,
                         pi.pipeinfo.pipe_stat.vst_size > 0 ? (unsigned)pi.pipeinfo.pipe_stat.vst_size : 0u);
            }
            break;
        }
        case PROX_FDTYPE_KQUEUE: {
            struct kqueue_fdinfo ki;
            if (proc_pidfdinfo(pid, fd->proc_fd, PROC_PIDFDKQUEUEINFO, &ki, sizeof(ki)) == (int)sizeof(ki)) {
                info->openFlags = ki.pfi.fi_openflags;
                snprintf(info->path, sizeof(info->path), "kqueue (%u pending)", (unsigned)ki.kqueueinfo.kq_stat.vst_size);
            }
            break;
        }
        case PROX_FDTYPE_PSHM: {
            struct pshm_fdinfo pi;
            if (proc_pidfdinfo(pid, fd->proc_fd, PROC_PIDFDPSHMINFO, &pi, sizeof(pi)) == (int)sizeof(pi)) {
                info->openFlags = pi.pfi.fi_openflags;
                strlcpy(info->path, pi.pshminfo.pshm_name, sizeof(info->path));
                info->vnodeSize = pi.pshminfo.pshm_stat.vst_size;
            }
            break;
        }
        case PROX_FDTYPE_PSEM: {
            struct psem_fdinfo pi;
            if (proc_pidfdinfo(pid, fd->proc_fd, PROC_PIDFDPSEMINFO, &pi, sizeof(pi)) == (int)sizeof(pi)) {
                info->openFlags = pi.pfi.fi_openflags;
                strlcpy(info->path, pi.pseminfo.psem_name, sizeof(info->path));
            }
            break;
        }
        default:
            break;
        }
        count++;
    }
    free(fds);
    return count;
}

int si_pid_threads(pid_t pid, si_thread_info *out, int max) {
    int cap = 4096;
    uint64_t *ids = malloc(sizeof(uint64_t) * (size_t)cap);
    if (!ids) {
        return -ENOMEM;
    }
    int useIds = 1;
    int r = proc_pidinfo(pid, PROC_PIDLISTTHREADIDS, 0, ids, (int)(sizeof(uint64_t) * (size_t)cap));
    if (r <= 0) {
        useIds = 0;
        r = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, ids, (int)(sizeof(uint64_t) * (size_t)cap));
    }
    if (r <= 0) {
        int err = errno;
        free(ids);
        return -err;
    }
    int n = r / (int)sizeof(uint64_t);
    int count = 0;
    for (int i = 0; i < n && count < max; i++) {
        struct proc_threadinfo ti;
        int got;
        if (useIds) {
            got = proc_pidinfo(pid, PROC_PIDTHREADID64INFO, ids[i], &ti, sizeof(ti));
        } else {
            got = proc_pidinfo(pid, PROC_PIDTHREADINFO, ids[i], &ti, sizeof(ti));
        }
        if (got != (int)sizeof(ti)) {
            continue;
        }
        si_thread_info *t = &out[count++];
        memset(t, 0, sizeof(*t));
        t->threadId = ids[i];
        t->userTimeNs = ti.pth_user_time;
        t->systemTimeNs = ti.pth_system_time;
        t->cpuUsage = ti.pth_cpu_usage;
        t->policy = ti.pth_policy;
        t->runState = ti.pth_run_state;
        t->flags = ti.pth_flags;
        t->sleepTime = ti.pth_sleep_time;
        t->currentPriority = ti.pth_curpri;
        t->priority = ti.pth_priority;
        t->maxPriority = ti.pth_maxpriority;
        strlcpy(t->name, ti.pth_name, sizeof(t->name));
    }
    free(ids);
    return count;
}

int si_pid_regions(pid_t pid, si_region_info *out, int max) {
    uint64_t address = 0;
    int count = 0;
    while (count < max) {
        struct proc_regionwithpathinfo rp;
        memset(&rp, 0, sizeof(rp));
        int r = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &rp, sizeof(rp));
        if (r <= 0) {
            if (count == 0 && errno != 0 && errno != EINVAL && errno != ESRCH) {
                return -errno;
            }
            break;
        }
        struct proc_regioninfo *ri = &rp.prp_prinfo;
        si_region_info *o = &out[count++];
        memset(o, 0, sizeof(*o));
        o->address = ri->pri_address;
        o->size = ri->pri_size;
        o->offset = ri->pri_offset;
        o->protection = ri->pri_protection;
        o->maxProtection = ri->pri_max_protection;
        o->userTag = ri->pri_user_tag;
        o->shareMode = ri->pri_share_mode;
        o->pagesResident = ri->pri_pages_resident;
        o->pagesSwappedOut = ri->pri_pages_swapped_out;
        o->pagesDirtied = ri->pri_pages_dirtied;
        o->privatePagesResident = ri->pri_private_pages_resident;
        o->sharedPagesResident = ri->pri_shared_pages_resident;
        o->depth = ri->pri_depth;
        o->isSubmap = (ri->pri_flags & PROC_REGION_SUBMAP) ? 1 : 0;
        strlcpy(o->path, rp.prp_vip.vip_path, sizeof(o->path));
        uint64_t next = ri->pri_address + ri->pri_size;
        if (next <= address) {
            break;
        }
        address = next;
    }
    return count;
}

// ---------------------------------------------------------------------------

int si_cs_status(pid_t pid, uint32_t *flags) {
    uint32_t f = 0;
    if (csops(pid, 0 /* CS_OPS_STATUS */, &f, sizeof(f)) != 0) {
        return -errno;
    }
    *flags = f;
    return 0;
}

int si_is_sandboxed(pid_t pid) {
    typedef int (*sandbox_check_fn)(pid_t, const char *, int, ...);
    static sandbox_check_fn fn = NULL;
    static int resolved = 0;
    if (!resolved) {
        fn = (sandbox_check_fn)dlsym(RTLD_DEFAULT, "sandbox_check");
        resolved = 1;
    }
    if (!fn) {
        return -1;
    }
    return fn(pid, NULL, 0) != 0 ? 1 : 0;
}

pid_t si_responsible_pid(pid_t pid) {
    typedef pid_t (*resp_fn)(pid_t);
    static resp_fn fn = NULL;
    static int resolved = 0;
    if (!resolved) {
        fn = (resp_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        resolved = 1;
    }
    if (!fn) {
        return -1;
    }
    return fn(pid);
}

// ---------------------------------------------------------------------------

int si_cpu_ticks_per_core(si_cpu_ticks *out, int max) {
    natural_t cpuCount = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) != KERN_SUCCESS) {
        return -1;
    }
    int n = (int)cpuCount < max ? (int)cpuCount : max;
    for (int i = 0; i < n; i++) {
        integer_t *ticks = &info[i * CPU_STATE_MAX];
        out[i].user = (uint32_t)ticks[CPU_STATE_USER];
        out[i].system = (uint32_t)ticks[CPU_STATE_SYSTEM];
        out[i].idle = (uint32_t)ticks[CPU_STATE_IDLE];
        out[i].nice = (uint32_t)ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(integer_t));
    return n;
}

int si_vm_statistics(si_vm_stats *out) {
    memset(out, 0, sizeof(*out));
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);
    out->pageSize = pageSize;

    uint64_t mem = 0;
    size_t size = sizeof(mem);
    sysctlbyname("hw.memsize", &mem, &size, NULL, 0);
    out->totalBytes = mem;

    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) {
        return -1;
    }
    out->freePages = vm.free_count;
    out->activePages = vm.active_count;
    out->inactivePages = vm.inactive_count;
    out->wiredPages = vm.wire_count;
    out->speculativePages = vm.speculative_count;
    out->compressorPages = vm.compressor_page_count;
    out->compressedPages = vm.total_uncompressed_pages_in_compressor;
    out->purgeablePages = vm.purgeable_count;
    out->externalPages = vm.external_page_count;
    out->internalPages = vm.internal_page_count;
    out->pageins = vm.pageins;
    out->pageouts = vm.pageouts;
    out->faults = vm.faults;
    out->cowFaults = vm.cow_faults;
    out->compressions = vm.compressions;
    out->decompressions = vm.decompressions;
    out->swapins = vm.swapins;
    out->swapouts = vm.swapouts;

    struct xsw_usage swap;
    size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) {
        out->swapTotal = swap.xsu_total;
        out->swapUsed = swap.xsu_used;
    }
    int level = 0;
    size = sizeof(level);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, NULL, 0) == 0) {
        out->pressureLevel = level;
    }
    return 0;
}

int si_net_interfaces(si_netif *out, int max) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0) {
        return -1;
    }
    char *buf = malloc(len);
    if (!buf) {
        return -1;
    }
    if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) {
        free(buf);
        return -1;
    }
    int count = 0;
    char *end = buf + len;
    for (char *next = buf; next < end && count < max;) {
        struct if_msghdr *ifm = (struct if_msghdr *)next;
        if (ifm->ifm_msglen == 0) {
            break;
        }
        next += ifm->ifm_msglen;
        if (ifm->ifm_type != RTM_IFINFO2) {
            continue;
        }
        struct if_msghdr2 *if2 = (struct if_msghdr2 *)ifm;
        si_netif *n = &out[count];
        memset(n, 0, sizeof(*n));
        char name[IF_NAMESIZE] = {0};
        if (!if_indextoname(if2->ifm_index, name)) {
            struct sockaddr_dl *sdl = (struct sockaddr_dl *)(if2 + 1);
            size_t nlen = sdl->sdl_nlen < sizeof(name) - 1 ? sdl->sdl_nlen : sizeof(name) - 1;
            memcpy(name, sdl->sdl_data, nlen);
        }
        strlcpy(n->name, name, sizeof(n->name));
        n->flags = (uint32_t)if2->ifm_flags;
        n->type = if2->ifm_data.ifi_type;
        n->ibytes = if2->ifm_data.ifi_ibytes;
        n->obytes = if2->ifm_data.ifi_obytes;
        n->ipackets = if2->ifm_data.ifi_ipackets;
        n->opackets = if2->ifm_data.ifi_opackets;
        n->ierrors = if2->ifm_data.ifi_ierrors;
        n->oerrors = if2->ifm_data.ifi_oerrors;
        n->baudrate = if2->ifm_data.ifi_baudrate;
        count++;
    }
    free(buf);
    return count;
}

static uint64_t si_dict_u64(CFDictionaryRef dict, const char *key) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFNumberRef num = (CFNumberRef)CFDictionaryGetValue(dict, k);
    CFRelease(k);
    uint64_t v = 0;
    if (num && CFGetTypeID(num) == CFNumberGetTypeID()) {
        CFNumberGetValue(num, kCFNumberSInt64Type, &v);
    }
    return v;
}

int si_disk_io_totals(si_disk_io *out) {
    memset(out, 0, sizeof(*out));
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass), &iter) != KERN_SUCCESS) {
        return -1;
    }
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iter))) {
        CFDictionaryRef stats = (CFDictionaryRef)IORegistryEntryCreateCFProperty(
            entry, CFSTR(kIOBlockStorageDriverStatisticsKey), kCFAllocatorDefault, 0);
        if (stats) {
            if (CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                out->bytesRead += si_dict_u64(stats, kIOBlockStorageDriverStatisticsBytesReadKey);
                out->bytesWritten += si_dict_u64(stats, kIOBlockStorageDriverStatisticsBytesWrittenKey);
                out->opsRead += si_dict_u64(stats, kIOBlockStorageDriverStatisticsReadsKey);
                out->opsWritten += si_dict_u64(stats, kIOBlockStorageDriverStatisticsWritesKey);
                out->timeReadNs += si_dict_u64(stats, kIOBlockStorageDriverStatisticsTotalReadTimeKey);
                out->timeWriteNs += si_dict_u64(stats, kIOBlockStorageDriverStatisticsTotalWriteTimeKey);
            }
            CFRelease(stats);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
    return 0;
}

int64_t si_boot_time(void) {
    struct timeval tv;
    size_t size = sizeof(tv);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &tv, &size, NULL, 0) != 0) {
        return 0;
    }
    return tv.tv_sec;
}

// ---------------------------------------------------------------------------
// Open at Login. LSSharedFileList is deprecated, but it's still how the session login items are
// read and changed outside System Settings; macOS keeps it in step with Background Task Management.

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void si_login_item_path(LSSharedFileListItemRef item, char *buf, size_t size) {
    buf[0] = 0;
    CFURLRef url = LSSharedFileListItemCopyResolvedURL(item, kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes, NULL);
    if (url) {
        CFURLGetFileSystemRepresentation(url, true, (UInt8 *)buf, (CFIndex)size);
        CFRelease(url);
    }
}

static void si_login_item_name(LSSharedFileListItemRef item, char *buf, size_t size) {
    buf[0] = 0;
    CFStringRef name = LSSharedFileListItemCopyDisplayName(item);
    if (name) {
        CFStringGetCString(name, buf, (CFIndex)size, kCFStringEncodingUTF8);
        CFRelease(name);
    }
}

int si_login_items(si_login_item **out) {
    *out = NULL;
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return -1;
    UInt32 seed = 0;
    CFArrayRef snapshot = LSSharedFileListCopySnapshot(list, &seed);
    CFIndex n = snapshot ? CFArrayGetCount(snapshot) : 0;
    si_login_item *items = calloc((size_t)(n > 0 ? n : 1), sizeof(si_login_item));
    for (CFIndex i = 0; items && i < n; i++) {
        LSSharedFileListItemRef item = (LSSharedFileListItemRef)CFArrayGetValueAtIndex(snapshot, i);
        si_login_item_name(item, items[i].name, sizeof(items[i].name));
        si_login_item_path(item, items[i].path, sizeof(items[i].path));
        CFTypeRef hidden = LSSharedFileListItemCopyProperty(item, kLSSharedFileListLoginItemHidden);
        if (hidden) {
            if (CFGetTypeID(hidden) == CFBooleanGetTypeID()) {
                items[i].hidden = CFBooleanGetValue((CFBooleanRef)hidden);
            } else if (CFGetTypeID(hidden) == CFNumberGetTypeID()) {
                CFNumberGetValue((CFNumberRef)hidden, kCFNumberSInt32Type, &items[i].hidden);
            }
            CFRelease(hidden);
        }
    }
    if (snapshot) CFRelease(snapshot);
    CFRelease(list);
    if (!items) return -1;
    *out = items;
    return (int)n;
}

int si_login_item_remove(const char *path, const char *name) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return -EIO;
    UInt32 seed = 0;
    CFArrayRef snapshot = LSSharedFileListCopySnapshot(list, &seed);
    int result = -ENOENT;
    for (CFIndex i = 0; snapshot && i < CFArrayGetCount(snapshot); i++) {
        LSSharedFileListItemRef item = (LSSharedFileListItemRef)CFArrayGetValueAtIndex(snapshot, i);
        char itemPath[1024], itemName[256];
        si_login_item_path(item, itemPath, sizeof(itemPath));
        si_login_item_name(item, itemName, sizeof(itemName));
        int match = path && path[0] ? strcmp(itemPath, path) == 0 : (itemPath[0] == 0 && name && strcmp(itemName, name) == 0);
        if (match) {
            result = LSSharedFileListItemRemove(list, item) == noErr ? 0 : -EIO;
            break;
        }
    }
    if (snapshot) CFRelease(snapshot);
    CFRelease(list);
    return result;
}

int si_login_item_add(const char *path, int hidden) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return -EIO;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), true);
    CFDictionaryRef properties = NULL;
    if (hidden) {
        const void *keys[] = { kLSSharedFileListLoginItemHidden };
        const void *values[] = { kCFBooleanTrue };
        properties = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    LSSharedFileListItemRef item = url ? LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast, NULL, NULL, url, properties, NULL) : NULL;
    if (item) CFRelease(item);
    if (properties) CFRelease(properties);
    if (url) CFRelease(url);
    CFRelease(list);
    return item ? 0 : -EIO;
}

#pragma clang diagnostic pop
