#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One register per Windows session. "Local\\" in C++ is the single backslash
  // Windows expects; a doubled one made the name invalid and the app exited.
  HANDLE register_mutex = ::CreateMutexW(nullptr, FALSE, L"Local\\CartunezPOSRegister");
  if (!register_mutex) return EXIT_FAILURE;
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND counter = ::FindWindowW(nullptr, L"Cartunez POS");
    if (counter) {
      ::ShowWindow(counter, SW_RESTORE);
      ::SetForegroundWindow(counter);
    }
    ::CloseHandle(register_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1360, 860);
  if (!window.Create(L"Cartunez POS", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(register_mutex);
  return EXIT_SUCCESS;
}
