/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "aether_runtime.h"
int main(void) { return aether_runtime_abi() == AETHER_RUNTIME_ABI ? 0 : 1; }
