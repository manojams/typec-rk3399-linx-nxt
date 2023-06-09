/* SPDX-License-Identifier: GPL-2.0 */
// Copyright (C) 2018 Hangzhou C-SKY Microsystems co.,ltd.

#include <linux/linkage.h>
#include <abi/entry.h>
#include <abi/pgtable-bits.h>
#include <asm/errno.h>
#include <asm/setup.h>
#include <asm/unistd.h>
#include <asm/asm-offsets.h>
#include <linux/threads.h>
#include <asm/page.h>
#include <asm/thread_info.h>

.macro	zero_fp
#ifdef CONFIG_STACKTRACE
	movi	r8, 0
#endif
.endm

.macro	context_tracking
#ifdef CONFIG_CONTEXT_TRACKING_USER
	mfcr	a0, epsr
	btsti	a0, 31
	bt	1f
	jbsr	user_exit_callable
	ldw	a0, (sp, LSAVE_A0)
	ldw	a1, (sp, LSAVE_A1)
	ldw	a2, (sp, LSAVE_A2)
	ldw	a3, (sp, LSAVE_A3)
#if defined(__CSKYABIV1__)
	ldw	r6, (sp, LSAVE_A4)
	ldw	r7, (sp, LSAVE_A5)
#endif
1:
#endif
.endm

.text
ENTRY(csky_pagefault)
	SAVE_ALL 0
	zero_fp
	context_tracking
	psrset  ee
	mov     a0, sp
	jbsr    do_page_fault
	jmpi    ret_from_exception

ENTRY(csky_systemcall)
	SAVE_ALL TRAP0_SIZE
	zero_fp
	context_tracking
	psrset  ee, ie

	lrw     r9, __NR_syscalls
	cmphs   syscallid, r9		/* Check nr of syscall */
	bt      1f

	lrw     r9, sys_call_table
	ixw     r9, syscallid
	ldw     syscallid, (r9)
	cmpnei  syscallid, 0
	bf      ret_from_exception

	mov     r9, sp
	bmaski  r10, THREAD_SHIFT
	andn    r9, r10
	ldw     r10, (r9, TINFO_FLAGS)
	lrw	r9, _TIF_SYSCALL_WORK
	and	r10, r9
	cmpnei	r10, 0
	bt      csky_syscall_trace
#if defined(__CSKYABIV2__)
	subi    sp, 8
	stw  	r5, (sp, 0x4)
	stw  	r4, (sp, 0x0)
	jsr     syscallid                      /* Do system call */
	addi 	sp, 8
#else
	jsr     syscallid
#endif
	stw     a0, (sp, LSAVE_A0)      /* Save return value */
1:
#ifdef CONFIG_DEBUG_RSEQ
	mov	a0, sp
	jbsr	rseq_syscall
#endif
	jmpi    ret_from_exception

csky_syscall_trace:
	mov	a0, sp                  /* sp = pt_regs pointer */
	jbsr	syscall_trace_enter
	cmpnei	a0, 0
	bt	1f
	/* Prepare args before do system call */
	ldw	a0, (sp, LSAVE_A0)
	ldw	a1, (sp, LSAVE_A1)
	ldw	a2, (sp, LSAVE_A2)
	ldw	a3, (sp, LSAVE_A3)
#if defined(__CSKYABIV2__)
	subi	sp, 8
	ldw	r9, (sp, LSAVE_A4)
	stw	r9, (sp, 0x0)
	ldw	r9, (sp, LSAVE_A5)
	stw	r9, (sp, 0x4)
	jsr	syscallid                     /* Do system call */
	addi	sp, 8
#else
	ldw	r6, (sp, LSAVE_A4)
	ldw	r7, (sp, LSAVE_A5)
	jsr	syscallid                     /* Do system call */
#endif
	stw	a0, (sp, LSAVE_A0)	/* Save return value */

1:
#ifdef CONFIG_DEBUG_RSEQ
	mov	a0, sp
	jbsr	rseq_syscall
#endif
	mov     a0, sp                  /* right now, sp --> pt_regs */
	jbsr    syscall_trace_exit
	br	ret_from_exception

ENTRY(ret_from_kernel_thread)
	jbsr	schedule_tail
	mov	a0, r10
	jsr	r9
	jbsr	ret_from_exception

ENTRY(ret_from_fork)
	jbsr	schedule_tail
	mov	r9, sp
	bmaski	r10, THREAD_SHIFT
	andn	r9, r10
	ldw	r10, (r9, TINFO_FLAGS)
	lrw	r9, _TIF_SYSCALL_WORK
	and	r10, r9
	cmpnei	r10, 0
	bf	ret_from_exception
	mov	a0, sp			/* sp = pt_regs pointer */
	jbsr	syscall_trace_exit

ret_from_exception:
	psrclr	ie
	ld	r9, (sp, LSAVE_PSR)
	btsti	r9, 31

	bt	1f
	/*
	 * Load address of current->thread_info, Then get address of task_struct
	 * Get task_needreshed in task_struct
	 */
	mov	r9, sp
	bmaski	r10, THREAD_SHIFT
	andn	r9, r10

	ldw	r10, (r9, TINFO_FLAGS)
	lrw	r9, _TIF_WORK_MASK
	and	r10, r9
	cmpnei	r10, 0
	bt	exit_work
#ifdef CONFIG_CONTEXT_TRACKING_USER
	jbsr	user_enter_callable
#endif
1:
#ifdef CONFIG_PREEMPTION
	mov	r9, sp
	bmaski	r10, THREAD_SHIFT
	andn	r9, r10

	ldw	r10, (r9, TINFO_PREEMPT)
	cmpnei	r10, 0
	bt	2f
	jbsr	preempt_schedule_irq	/* irq en/disable is done inside */
2:
#endif

#ifdef CONFIG_TRACE_IRQFLAGS
	ld	r10, (sp, LSAVE_PSR)
	btsti	r10, 6
	bf	2f
	jbsr	trace_hardirqs_on
2:
#endif
	RESTORE_ALL

exit_work:
	lrw	r9, ret_from_exception
	mov	lr, r9

	btsti	r10, TIF_NEED_RESCHED
	bt	work_resched

	psrset	ie
	mov	a0, sp
	mov	a1, r10
	jmpi	do_notify_resume

work_resched:
	jmpi	schedule

ENTRY(csky_trap)
	SAVE_ALL 0
	zero_fp
	context_tracking
	psrset	ee
	mov	a0, sp                 /* Push Stack pointer arg */
	jbsr	trap_c                 /* Call C-level trap handler */
	jmpi	ret_from_exception

/*
 * Prototype from libc for abiv1:
 * register unsigned int __result asm("a0");
 * asm( "trap 3" :"=r"(__result)::);
 */
ENTRY(csky_get_tls)
	USPTOKSP

	RD_MEH	a0
	WR_MEH	a0

	/* increase epc for continue */
	mfcr	a0, epc
	addi	a0, TRAP0_SIZE
	mtcr	a0, epc

	/* get current task thread_info with kernel 8K stack */
	bmaski	a0, THREAD_SHIFT
	not	a0
	subi	sp, 1
	and	a0, sp
	addi	sp, 1

	/* get tls */
	ldw	a0, (a0, TINFO_TP_VALUE)

	KSPTOUSP
	rte

ENTRY(csky_irq)
	SAVE_ALL 0
	zero_fp
	context_tracking
	psrset	ee

#ifdef CONFIG_TRACE_IRQFLAGS
	jbsr	trace_hardirqs_off
#endif


	mov	a0, sp
	jbsr	generic_handle_arch_irq

	jmpi	ret_from_exception

/*
 * a0 =  prev task_struct *
 * a1 =  next task_struct *
 * a0 =  return next
 */
ENTRY(__switch_to)
	lrw	a3, TASK_THREAD
	addu	a3, a0

	SAVE_SWITCH_STACK

	stw	sp, (a3, THREAD_KSP)

	/* Set up next process to run */
	lrw	a3, TASK_THREAD
	addu	a3, a1

	ldw	sp, (a3, THREAD_KSP)	/* Set next kernel sp */

#if  defined(__CSKYABIV2__)
	addi	a3, a1, TASK_THREAD_INFO
	ldw	tls, (a3, TINFO_TP_VALUE)
#endif

	RESTORE_SWITCH_STACK

	rts
ENDPROC(__switch_to)
