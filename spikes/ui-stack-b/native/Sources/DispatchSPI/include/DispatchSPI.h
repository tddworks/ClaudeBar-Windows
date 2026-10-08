#pragma once

// libdispatch's hook for draining the main queue from a foreign run loop
// (swift-corelibs-libdispatch private/private.h). CoreFoundation calls it when
// the main queue's wake handle fires; a WinUI host calls it from its UI thread.
// Only used on Windows; on Apple platforms the signature differs.
#if defined(_WIN32)
__declspec(dllimport) void _dispatch_main_queue_callback_4CF(void *_Nullable msg);
#endif
