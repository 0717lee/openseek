/*
 * Small native integrations owned by the desktop host. The MoonBit wrappers
 * select the Windows paths; keeping the stubs buildable elsewhere lets the
 * package retain one native configuration.
 */

#include <stdint.h>

#include "moonbit.h"

#if defined(_WIN32)

#include <windows.h>
#include <shellapi.h>

#if !defined(_MSC_VER)
#error "SeekMoon's Windows desktop host requires an MSVC-compatible compiler"
#endif

#pragma comment(lib, "shell32.lib")
#pragma comment(linker, "/SUBSYSTEM:WINDOWS")
#pragma comment(linker, "/ENTRY:mainCRTStartup")

#endif

MOONBIT_FFI_EXPORT int32_t
moonbit_openseek_desktop_platform_open(moonbit_string_t target) {
#if defined(_WIN32)
  /*
   * ShellExecuteW receives the target as data. In particular, characters such
   * as '&' and '|' never pass through cmd.exe and cannot become commands.
   */
  INT_PTR result =
      (INT_PTR)ShellExecuteW(NULL, L"open", (const wchar_t *)target, NULL, NULL,
                            SW_SHOWNORMAL);
  if (result > 32) {
    return 0;
  }
  /* ShellExecuteW may report failure as zero; preserve non-zero exit semantics. */
  return result == 0 ? 1 : (int32_t)result;
#else
  (void)target;
  return 1;
#endif
}
