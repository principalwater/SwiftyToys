// SPDX-License-Identifier: MIT
// Header-only import of the platform SDK. No C/C++ application implementation.
#pragma once
#pragma clang module import WinSDK
#include <Windows.h>
#include <commctrl.h>
#include <wtsapi32.h>
#include <magnification.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <windef.h>
#include <winnt.h>
#include <d3dkmthk.h>
#include <physicalmonitorenumerationapi.h>
#include <highlevelmonitorconfigurationapi.h>
#include <lowlevelmonitorconfigurationapi.h>
#include <hidsdi.h>
#include <hidpi.h>
#include <taskschd.h>
#include <winevt.h>
#include <powrprof.h>
#include <bcrypt.h>
#include <wintrust.h>
#include "AMDABI.h"
// WinSDK's Swift overlay turns GetMessageW's three states into Bool.
// A declaration alias preserves the native -1 / 0 / positive result.
extern int WINAPI BC_GetMessageW(MSG *, HWND, UINT, UINT) __asm__("GetMessageW");
// TPM_RETURNCMD returns a command ID, rather than a Boolean success value.
extern int WINAPI BC_TrackPopupMenu(HMENU, UINT, int, int, int, HWND, const RECT *) __asm__("TrackPopupMenu");
