/* -*- mode: c; c-basic-offset: 8 -*- */
/*
    queue.d -- waiting queue for threads.
*/
/*
    Copyright (c) 2011, Juan Jose Garcia Ripoll.

    ECL is free software; you can redistribute it and/or
    modify it under the terms of the GNU Library General Public
    License as published by the Free Software Foundation; either
    version 2 of the License, or (at your option) any later version.

    See file '../Copyright' for full details.
*/

#define AO_ASSUME_WINDOWS98 /* We need this for CAS */
#ifdef HAVE_SCHED_H
#include <sched.h>
#endif
#include <signal.h>
#include <ecl/ecl.h>
#include <ecl/internal.h>

#define print_lock(a,b,...) (void)0

void ECL_INLINE
ecl_get_spinlock(cl_env_ptr the_env, cl_object *lock)
{
	cl_object own_process = the_env->own_process;
	while (!AO_compare_and_swap_full((AO_t*)lock, (AO_t)Cnil,
					 (AO_t)own_process)) {
		sched_yield();
	}
}

#ifndef HAVE_SCHED_H
int
sched_yield()
{
	ecl_musleep(0.0, 1);
}
#endif

void ECL_INLINE
ecl_giveup_spinlock(cl_object *lock)
{
	*lock = Cnil;
}

cl_object
ecl_make_atomic_queue()
{
	return ecl_list1(Cnil);
}

void
ecl_atomic_queue_nconc(cl_env_ptr the_env, cl_object lock_list_pair, cl_object new_tail)
{
	ecl_disable_interrupts_env(the_env);
	{
		cl_object *lock = &ECL_CONS_CAR(lock_list_pair);
		cl_object *queue = &ECL_CONS_CDR(lock_list_pair);
		ecl_get_spinlock(the_env, lock);
		ecl_nconc(lock_list_pair, new_tail);
		ecl_giveup_spinlock(lock);
	}
	ecl_enable_interrupts_env(the_env);
}

cl_object
ecl_atomic_queue_pop(cl_env_ptr the_env, cl_object lock_list_pair)
{
	cl_object output;
	ecl_disable_interrupts_env(the_env);
	{
		cl_object *lock = &ECL_CONS_CAR(lock_list_pair);
		cl_object *queue = &ECL_CONS_CDR(lock_list_pair);
		ecl_get_spinlock(the_env, lock);
		output = *queue;
		if (!Null(output)) {
			*queue = ECL_CONS_CDR(output);
			output = ECL_CONS_CAR(output);
		}
		ecl_giveup_spinlock(lock);
	}
	ecl_enable_interrupts_env(the_env);
	return output;
}

cl_object
ecl_atomic_queue_pop_all(cl_env_ptr the_env, cl_object lock_list_pair)
{
	cl_object output;
	ecl_disable_interrupts_env(the_env);
	{
		cl_object *lock = &ECL_CONS_CAR(lock_list_pair);
		cl_object *queue = &ECL_CONS_CDR(lock_list_pair);
		ecl_get_spinlock(the_env, lock);
		output = *queue;
		*queue = Cnil;
		ecl_giveup_spinlock(lock);
	}
	ecl_enable_interrupts_env(the_env);
	return output;
}

void
ecl_atomic_queue_delete(cl_env_ptr the_env, cl_object lock_list_pair, cl_object item)
{
	ecl_disable_interrupts_env(the_env);
	{
		cl_object *lock = &ECL_CONS_CAR(lock_list_pair);
		cl_object *queue = &ECL_CONS_CDR(lock_list_pair);
		ecl_get_spinlock(the_env, lock);
		*queue = ecl_delete_eq(item, *queue);
		*lock = Cnil;
	}
	ecl_enable_interrupts_env(the_env);
}

/*----------------------------------------------------------------------
 * THREAD SCHEDULER & WAITING
 */

static cl_object
bignum_set_time(cl_object bignum, struct ecl_timeval *time)
{
	_ecl_big_set_index(bignum, time->tv_sec);
	_ecl_big_mul_ui(bignum, bignum, 1000);
	_ecl_big_add_ui(bignum, bignum, (time->tv_usec + 999) / 1000);
	return bignum;
}

static cl_object
elapsed_time(struct ecl_timeval *start)
{
	cl_object delta_big = _ecl_big_register0();
	cl_object aux_big = _ecl_big_register1();
	struct ecl_timeval now;
	ecl_get_internal_real_time(&now);
	bignum_set_time(aux_big, start);
	bignum_set_time(delta_big, &now);
	_ecl_big_sub(delta_big, delta_big, aux_big);
	_ecl_big_register_free(aux_big);
	return delta_big;
}

static double
waiting_time(cl_index iteration, struct ecl_timeval *start)
{
	/* Waiting time is smaller than 0.10 s */
	double time;
	cl_object top = MAKE_FIXNUM(10 * 1000);
	cl_object delta_big = elapsed_time(start);
	_ecl_big_div_ui(delta_big, delta_big, iteration);
	if (ecl_number_compare(delta_big, top) < 0) {
		time = ecl_to_double(delta_big) * 1.5;
	} else {
		time = 0.10;
	}
	_ecl_big_register_free(delta_big);
	return time;
}

void
ecl_wait_on(cl_object (*condition)(cl_env_ptr, cl_object), cl_object o)
{
	const cl_env_ptr the_env = ecl_process_env();
	volatile cl_object own_process = the_env->own_process;
	volatile cl_object record;
	volatile sigset_t original;

	/* 0) We reserve a record for the queue. In order to a void
	 * using the garbage collector, we reuse records */
	record = own_process->process.queue_record;
	unlikely_if (record == Cnil) {
		record = ecl_list1(own_process);
	} else {
		own_process->process.queue_record = Cnil;
	}

	/* 1) First we block all signals. */
	{
		sigset_t empty;
		sigemptyset(&empty);
		pthread_sigmask(SIG_SETMASK, &original, &empty);
	}

	/* 2) Now we add ourselves to the queue. In order to avoid a
	 * call to the GC, we try to reuse records. */
	ecl_atomic_queue_nconc(the_env, o->lock.waiter, record);
	own_process->process.waiting_for = o;

	CL_UNWIND_PROTECT_BEGIN(the_env) {
		/* 3) At this point we may receive signals, but we
		 * might have missed a wakeup event if that happened
		 * between 0) and 2), which is why we start with the
		 * check*/
		cl_object queue = ECL_CONS_CDR(o->lock.waiter);
		if (ECL_CONS_CAR(queue) != own_process ||
		    condition(the_env, o) == Cnil)
		{
			do {
				/* This will wait until we get a signal that
				 * demands some code being executed. Note that
				 * this includes our communication signals and
				 * the signals used by the GC. Note also that
				 * as a consequence we might throw / return
				 * which is why need to protect it all with
				 * UNWIND-PROTECT. */
				sigsuspend(&original);
			} while (condition(the_env, o) == Cnil);
		}
	} CL_UNWIND_PROTECT_EXIT {
		/* 4) At this point we wrap up. We remove ourselves
		   from the queue and restore signals, which were */
		own_process->process.waiting_for = Cnil;
		ecl_atomic_queue_delete(the_env, o->lock.waiter, own_process);
		own_process->process.queue_record = record;
		ECL_RPLACD(record, Cnil);
		pthread_sigmask(SIG_SETMASK, NULL, &original);
	} CL_UNWIND_PROTECT_END;
}

static void
wakeup_this(cl_object p, int flags)
{
	if (flags & ECL_WAKEUP_RESET_FLAG)
		p->process.waiting_for = Cnil;
	print_lock("awaking\t\t%d", Cnil, fix(p->process.name));
	ecl_interrupt_process(p, Cnil);
}

static void
wakeup_all(cl_env_ptr the_env, cl_object waiter, int flags)
{
	cl_object queue = ecl_atomic_queue_pop_all(the_env, waiter);
	queue = cl_nreverse(queue);
	while (!Null(queue)) {
		cl_object process = ECL_CONS_CAR(queue);
		queue = ECL_CONS_CDR(queue);
		if (process->process.active)
			wakeup_this(ECL_CONS_CAR(queue), flags);
	}
}

static void
wakeup_one(cl_env_ptr the_env, cl_object waiter, int flags)
{
	do {
		cl_object next = ECL_CONS_CDR(waiter);
		if (Null(next))
			return;
		next = ECL_CONS_CAR(next);
		if (next->process.active) {
			wakeup_this(next, flags);
			return;
		}
	} while (1);
}

void
ecl_wakeup_waiters(cl_env_ptr the_env, cl_object o, int flags)
{
	cl_object waiter = o->lock.waiter;
	print_lock("releasing\t", o);
	if (ECL_CONS_CDR(waiter) != Cnil) {
		if (flags & ECL_WAKEUP_ALL) {
			wakeup_all(the_env, waiter, flags);
		} else {
			wakeup_one(the_env, waiter, flags);
		}
	}
	sched_yield();
}

#undef print_lock

void
print_lock(char *prefix, cl_object l, ...)
{
	static cl_object lock = Cnil;
	va_list args;
	va_start(args, lock);
	if (l == Cnil || l->lock.name == MAKE_FIXNUM(0)) {
		cl_env_ptr env = ecl_process_env();
		ecl_get_spinlock(env, &lock);
		printf("\n%d\t", fix(env->own_process->process.name));
		vprintf(prefix, args);
		if (l != Cnil) {
			cl_object p = ECL_CONS_CDR(l->lock.waiter);
			while (p != Cnil) {
				printf(" %d", fix(ECL_CONS_CAR(p)->process.name));
				p = ECL_CONS_CDR(p);
			}
		}
		fflush(stdout);
		ecl_giveup_spinlock(&lock);
	}
}
/*#define print_lock(a,b,c) (void)0*/
