// SPDX-License-Identifier: MIT
import WinSDK

enum NativeSearchFolderPicker {
    static func choose(owner: HWND?) throws -> String? {
        let initialized = CoInitializeEx(nil,DWORD(COINIT_APARTMENTTHREADED.rawValue))
        guard initialized >= 0 || initialized == HRESULT(bitPattern:0x80010106) else { throw WindowsError.status("Initialize folder picker",initialized) }
        defer { if initialized >= 0 { CoUninitialize() } }
        var classID = CLSID_FileOpenDialog, interfaceID = IID_IFileOpenDialog, raw: UnsafeMutableRawPointer?
        var result = CoCreateInstance(&classID,nil,DWORD(CLSCTX_INPROC_SERVER.rawValue),&interfaceID,&raw)
        guard result >= 0, let dialog = raw?.assumingMemoryBound(to:IFileOpenDialog.self) else { throw WindowsError.status("Create folder picker",result) }
        defer { _ = dialog.pointee.lpVtbl.pointee.Release(dialog) }
        result = dialog.pointee.lpVtbl.pointee.SetOptions(dialog,FILEOPENDIALOGOPTIONS(FOS_PICKFOLDERS.rawValue | FOS_FORCEFILESYSTEM.rawValue | FOS_PATHMUSTEXIST.rawValue | FOS_NOCHANGEDIR.rawValue))
        guard result >= 0 else { throw WindowsError.status("Configure folder picker",result) }
        _ = withWideString("Choose a local folder for semantic search") { dialog.pointee.lpVtbl.pointee.SetTitle(dialog,$0) }
        result = dialog.pointee.lpVtbl.pointee.Show(dialog,owner)
        if result == HRESULT(bitPattern:0x800704c7) { return nil }
        guard result >= 0 else { throw WindowsError.status("Choose semantic folder",result) }
        var item: UnsafeMutablePointer<IShellItem>?
        result = dialog.pointee.lpVtbl.pointee.GetResult(dialog,&item)
        guard result >= 0, let item else { throw WindowsError.status("Read selected folder",result) }
        defer { _ = item.pointee.lpVtbl.pointee.Release(item) }
        var path: PWSTR?
        result = item.pointee.lpVtbl.pointee.GetDisplayName(item,SIGDN_FILESYSPATH,&path)
        guard result >= 0, let path else { throw WindowsError.status("Read folder path",result) }
        defer { CoTaskMemFree(path) }
        var count = 0; while count < 32768, path[count] != 0 { count += 1 }
        guard count < 32768 else { throw WindowsError.unsupported("The selected folder path is too long.") }
        let text = String(decoding:UnsafeBufferPointer(start:path,count:count),as:UTF16.self)
        guard NativeSearchFiles.validFolder(text) else { throw WindowsError.unsupported("Choose a local folder without links. Network shares and private workspace folders are excluded.") }
        return text
    }
}
