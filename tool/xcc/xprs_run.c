/*
 * The bundled compiler's entry (tool/build_compiler.sh): what xcc's _start
 * does, under another name, with the compiler's messages sent to
 * /tmp/cc.log once the C library (its view of the preopened folders
 * included) is set up. The app's runtime would run a _start inside
 * instantiation, and delivers captured output only after a call returns.
 */
#include <stdio.h>
#include <stdlib.h>

extern void __wasm_call_ctors(void);
extern int __main_void(void);

void xprs_run(void) {
    __wasm_call_ctors();
    FILE *log = fopen("/tmp/cc.log", "w");
    if (log) {
        stdout = log;
        stderr = log;
    }
    exit(__main_void());
}
