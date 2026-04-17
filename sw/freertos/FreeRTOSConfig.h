// FreeRTOS config for the RV32IMA SoC (Urbana FPGA + Verilator sim).
//
// Tick sourced from the native SiFive-style CLINT at 0x0200_0000:
//   mtime    at 0x0200_BFF8 (64-bit free-running, 1 tick / cpu cycle)
//   mtimecmp at 0x0200_4000 (64-bit)
// Context switch pends use CLINT msip (handled internally by the port).
//
// CPU frequency is 50 MHz on silicon; Verilator sim has no wall clock but
// mtime still advances one count per cycle so the numerical relationship is
// the same (each tick is 50k cycles of simulation).

#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#define configCPU_CLOCK_HZ                      50000000UL
#define configTICK_RATE_HZ                      ( ( TickType_t ) 1000 )
#define configMTIME_BASE_ADDRESS                0x0200BFF8UL
#define configMTIMECMP_BASE_ADDRESS             0x02004000UL

#define configISR_STACK_SIZE_WORDS              256

#define configUSE_PREEMPTION                    1
#define configUSE_IDLE_HOOK                     0
#define configUSE_TICK_HOOK                     0
#define configUSE_16_BIT_TICKS                  0
#define configMAX_PRIORITIES                    5
#define configMINIMAL_STACK_SIZE                ( ( unsigned short ) 128 ) /* in words */
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) 8192 )
#define configMAX_TASK_NAME_LEN                 8
#define configUSE_TRACE_FACILITY                0
#define configIDLE_SHOULD_YIELD                 1

#define configUSE_MUTEXES                       0
#define configQUEUE_REGISTRY_SIZE               0
#define configCHECK_FOR_STACK_OVERFLOW          0
#define configUSE_RECURSIVE_MUTEXES             0
#define configUSE_MALLOC_FAILED_HOOK            0
#define configUSE_COUNTING_SEMAPHORES           0
#define configUSE_TIMERS                        0

#define INCLUDE_vTaskPrioritySet                0
#define INCLUDE_uxTaskPriorityGet               0
#define INCLUDE_vTaskDelete                     0
#define INCLUDE_vTaskCleanUpResources           0
#define INCLUDE_vTaskSuspend                    0
#define INCLUDE_vTaskDelayUntil                 1
#define INCLUDE_vTaskDelay                      1
#define INCLUDE_xTaskGetSchedulerState          0
#define INCLUDE_xTaskGetCurrentTaskHandle       0
#define INCLUDE_uxTaskGetStackHighWaterMark     0

#define configASSERT( x )                                   \
    do {                                                    \
        if ( ( x ) == 0 ) {                                 \
            extern void vAssertCalled( const char*, int );  \
            vAssertCalled( __FILE__, __LINE__ );            \
        }                                                   \
    } while ( 0 )

#endif /* FREERTOS_CONFIG_H */
