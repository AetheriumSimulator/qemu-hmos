/*
 * Signal-free coroutine stack bootstrap for the embedded HarmonyOS core.
 *
 * The switching/pooling contract follows QEMU's sigaltstack backend, but a
 * coroutine must not temporarily replace ArkRuntime's process signal handlers.
 * Only the first entry needs assembly; subsequent switches use sigsetjmp on
 * the coroutine's real stack, without editing libc's private jmp_buf layout.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0

#include "qemu/osdep.h"
#include "qemu/coroutine_int.h"

#ifdef CONFIG_SAFESTACK
#error "hmos-stack requires explicit SafeStack support before it can be used"
#endif
#ifdef CONFIG_ASAN
#error "hmos-stack requires sanitizer fiber hooks before it can use ASan"
#endif

typedef struct {
    Coroutine base;
    void *stack;
    size_t stack_size;
    sigjmp_buf env;
} CoroutineHmosStack;

typedef struct {
    Coroutine *current;
    CoroutineHmosStack leader;
} CoroutineThreadState;

static pthread_key_t thread_state_key;

static void coroutine_thread_cleanup(void *opaque)
{
    g_free(opaque);
}

static void __attribute__((constructor)) coroutine_init(void)
{
    int ret = pthread_key_create(&thread_state_key, coroutine_thread_cleanup);
    if (ret != 0) {
        fprintf(stderr, "unable to create coroutine TLS: %s\n", strerror(ret));
        abort();
    }
}

static CoroutineThreadState *coroutine_get_thread_state(void)
{
    CoroutineThreadState *s = pthread_getspecific(thread_state_key);
    if (!s) {
        s = g_malloc0(sizeof(*s));
        s->current = &s->leader.base;
        if (pthread_setspecific(thread_state_key, s) != 0) {
            g_free(s);
            abort();
        }
    }
    return s;
}

/* This function cannot return: entry restores the creator's saved context.
 * Keep it out of inline asm so no compiler-generated frame accesses can run
 * after changing SP. x18 (HarmonyOS platform register) is left untouched.
 */
extern void qemu_hmos_enter_stack(void *top, void (*entry)(void *), void *opaque)
    __attribute__((noreturn, visibility("hidden")));

#if defined(__aarch64__)
__asm__(".text\n"
        ".align 2\n"
        ".hidden qemu_hmos_enter_stack\n"
        ".type qemu_hmos_enter_stack, %function\n"
        "qemu_hmos_enter_stack:\n"
        "mov sp, x0\n"
        "mov x0, x2\n"
        "mov x30, xzr\n"
        "br x1\n"
        ".size qemu_hmos_enter_stack, .-qemu_hmos_enter_stack\n");
#elif defined(__x86_64__)
__asm__(".text\n"
        ".hidden qemu_hmos_enter_stack\n"
        ".type qemu_hmos_enter_stack, @function\n"
        "qemu_hmos_enter_stack:\n"
        "mov %rdi, %rsp\n"
        "mov %rdx, %rdi\n"
        "call *%rsi\n"
        "ud2\n"
        ".size qemu_hmos_enter_stack, .-qemu_hmos_enter_stack\n");
#else
#error "hmos-stack currently implements only AArch64 and x86_64 ELF hosts"
#endif

static void coroutine_bootstrap(void *opaque)
{
    CoroutineHmosStack *self = opaque;
    Coroutine *co = &self->base;
    if (!sigsetjmp(self->env, 0)) {
        siglongjmp(*(sigjmp_buf *)co->entry_arg, 1);
    }
    while (true) {
        co->entry(co->entry_arg);
        qemu_coroutine_switch(co, co->caller, COROUTINE_TERMINATE);
    }
}

Coroutine *qemu_coroutine_new(void)
{
    CoroutineHmosStack *co = g_malloc0(sizeof(*co));
    sigjmp_buf creator;
    co->stack_size = COROUTINE_STACK_SIZE;
    co->stack = qemu_alloc_stack(&co->stack_size);
    co->base.entry_arg = &creator;
    /* Both supported ABIs require a 16-byte-aligned stack at the call site. */
    uintptr_t top = ((uintptr_t)co->stack + co->stack_size) & ~(uintptr_t)15;
    if (!sigsetjmp(creator, 0)) {
        qemu_hmos_enter_stack((void *)top, coroutine_bootstrap, co);
    }
    return &co->base;
}

void qemu_coroutine_delete(Coroutine *base)
{
    CoroutineHmosStack *co = DO_UPCAST(CoroutineHmosStack, base, base);
    qemu_free_stack(co->stack, co->stack_size);
    g_free(co);
}

CoroutineAction qemu_coroutine_switch(Coroutine *from, Coroutine *to,
                                      CoroutineAction action)
{
    CoroutineHmosStack *source = DO_UPCAST(CoroutineHmosStack, base, from);
    CoroutineHmosStack *target = DO_UPCAST(CoroutineHmosStack, base, to);
    coroutine_get_thread_state()->current = to;
    int result = sigsetjmp(source->env, 0);
    if (result == 0) {
        siglongjmp(target->env, action);
    }
    return result;
}

Coroutine *qemu_coroutine_self(void)
{
    return coroutine_get_thread_state()->current;
}

bool qemu_in_coroutine(void)
{
    CoroutineThreadState *s = pthread_getspecific(thread_state_key);
    return s && s->current->caller;
}
