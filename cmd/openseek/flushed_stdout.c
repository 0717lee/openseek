#ifdef __cplusplus
extern "C" {
#endif

#include <stdio.h>

#include "moonbit.h"

MOONBIT_FFI_EXPORT int
openseek_write_flushed_stdout_line(moonbit_bytes_t data) {
  int len = Moonbit_array_length(data);
  if (len > 0) {
    size_t written = fwrite(data, 1, (size_t)len, stdout);
    if (written != (size_t)len) {
      return -1;
    }
  }
  if (fputc('\n', stdout) == EOF) {
    return -1;
  }
  return fflush(stdout) == 0 ? 0 : -1;
}

#ifdef __cplusplus
}
#endif
