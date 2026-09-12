#include "flutter_window.h"

#include <optional>
#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  screen_capture_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "sylphy/screen_capture",
          &flutter::StandardMethodCodec::GetInstance());
  screen_capture_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "setStreamProof") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = call.arguments()
            ? std::get_if<bool>(call.arguments()) : nullptr;
        if (!enabled) {
          result->Error("invalid_arguments", "Expected a boolean.");
          return;
        }
        if (*enabled) {
          // Older Windows versions silently downgrade exclusion to a black
          // rectangle. Require the version that actually supports exclusion.
          OSVERSIONINFOEXW version = {};
          version.dwOSVersionInfoSize = sizeof(version);
          version.dwMajorVersion = 10;
          version.dwBuildNumber = 19041;
          DWORDLONG conditions = 0;
          VER_SET_CONDITION(conditions, VER_MAJORVERSION, VER_GREATER_EQUAL);
          VER_SET_CONDITION(conditions, VER_MINORVERSION, VER_GREATER_EQUAL);
          VER_SET_CONDITION(conditions, VER_BUILDNUMBER, VER_GREATER_EQUAL);
          BOOL composition = FALSE;
          if (!VerifyVersionInfoW(&version,
                  VER_MAJORVERSION | VER_MINORVERSION | VER_BUILDNUMBER,
                  conditions) ||
              FAILED(DwmIsCompositionEnabled(&composition)) || !composition) {
            result->Error("unsupported", "Requires Windows 10 2004 and DWM.");
            return;
          }
        }
        constexpr DWORD kExcludeFromCapture = 0x00000011;
        const DWORD affinity = *enabled ? kExcludeFromCapture : WDA_NONE;
        // Affinity belongs to the top-level HWND, not Flutter's child view.
        if (!SetWindowDisplayAffinity(GetHandle(), affinity)) {
          result->Error("capture_protection_failed",
                        std::to_string(GetLastError()));
          return;
        }
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (screen_capture_channel_) {
    screen_capture_channel_->SetMethodCallHandler(nullptr);
    screen_capture_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
