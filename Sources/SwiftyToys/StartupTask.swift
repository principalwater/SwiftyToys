// SPDX-License-Identifier: MIT

import BrightnessCore
import WinSDK
import WindowsDisplayABI

/// Owns a COM reference without allowing Swift to copy it or release it twice.
private struct COMReference<Interface>: ~Copyable {
    let pointer: UnsafeMutablePointer<Interface>
    init(_ pointer: UnsafeMutablePointer<Interface>?) throws(WindowsError) {
        guard let pointer else { throw .unsupported("Task Scheduler returned an empty COM reference.") }
        self.pointer = pointer
    }
    deinit {
        pointer.withMemoryRebound(to: IUnknown.self, capacity: 1) {
            _ = $0.pointee.lpVtbl.pointee.Release($0)
        }
    }
}
private struct OwnedBSTR: ~Copyable {
    let raw: BSTR
    init(_ value: String) throws(WindowsError) {
        guard let string = withWideString(value, { SysAllocString($0) }) else {
            throw .unsupported("Could not allocate a COM string.")
        }
        raw = string
    }
    deinit { SysFreeString(raw) }
}
private func checkCOM(_ result: HRESULT, _ operation: String) throws(WindowsError) {
    guard result >= 0 else { throw .status(operation, result) }
}
private func normalizedPath(_ path: String) throws(WindowsError) -> String {
    var buffer = Array(repeating: WCHAR(0), count: 32768)
    let length = withWideString(path) { GetFullPathNameW($0, DWORD(buffer.count), &buffer, nil) }
    guard length > 0, length < buffer.count else { throw .api("GetFullPathName", GetLastError()) }
    return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
}
/// Start the matching interactive task through native COM. No shell or child
/// schtasks process is needed, and a stale task cannot launch another binary.
func startResident() throws {
    let taskFile = try NativeFiles.path("startup-task.txt")
    let taskName =
        try NativeFiles.exists(taskFile)
        ? try NativeFiles.text(taskFile).trimmingWhitespace()
        : "SwiftyToys"
    guard isValidStartupTaskName(taskName) else {
        throw WindowsError.unsupported("Invalid startup task name.")
    }
    let initialized = CoInitializeEx(nil, DWORD(COINIT_MULTITHREADED.rawValue))
    try checkCOM(initialized, "Initialize Task Scheduler COM")
    defer { CoUninitialize() }
    var classID = GUID(
        Data1: 0x0f87_369f, Data2: 0xa4e5, Data3: 0x4cfc, Data4: (0xbd, 0x3e, 0x73, 0xe6, 0x15, 0x45, 0x72, 0xdd))
    var serviceID = GUID(
        Data1: 0x2fab_a4c7, Data2: 0x4da9, Data3: 0x4013, Data4: (0x96, 0x97, 0x20, 0xcc, 0x3f, 0xd4, 0x0f, 0x85))
    var object: UnsafeMutableRawPointer?
    try checkCOM(
        CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &serviceID, &object),
        "Open Task Scheduler")
    let service = try COMReference(object?.assumingMemoryBound(to: ITaskService.self))
    let empty = VARIANT()
    try checkCOM(
        service.pointer.pointee.lpVtbl.pointee.Connect(service.pointer, empty, empty, empty, empty),
        "Connect Task Scheduler")
    let rootName = try OwnedBSTR("\\")
    var folderPointer: UnsafeMutablePointer<ITaskFolder>?
    try checkCOM(
        service.pointer.pointee.lpVtbl.pointee.GetFolder(service.pointer, rootName.raw, &folderPointer),
        "Open startup task folder")
    let folder = try COMReference(folderPointer)
    let name = try OwnedBSTR(taskName)
    var taskPointer: UnsafeMutablePointer<IRegisteredTask>?
    try checkCOM(
        folder.pointer.pointee.lpVtbl.pointee.GetTask(folder.pointer, name.raw, &taskPointer),
        "Find startup task; run install.ps1 if it is missing")
    let task = try COMReference(taskPointer)
    var definitionPointer: UnsafeMutablePointer<ITaskDefinition>?
    try checkCOM(
        task.pointer.pointee.lpVtbl.pointee.get_Definition(task.pointer, &definitionPointer), "Read task definition")
    let definition = try COMReference(definitionPointer)
    var actionsPointer: UnsafeMutablePointer<IActionCollection>?
    try checkCOM(
        definition.pointer.pointee.lpVtbl.pointee.get_Actions(definition.pointer, &actionsPointer),
        "Read startup actions")
    let actions = try COMReference(actionsPointer)
    var count: LONG = 0
    try checkCOM(actions.pointer.pointee.lpVtbl.pointee.get_Count(actions.pointer, &count), "Count startup actions")
    guard count == 1 else {
        throw WindowsError.unsupported("Startup task must contain one SwiftyToys action; run the installer.")
    }
    var actionPointer: UnsafeMutablePointer<IAction>?
    try checkCOM(
        actions.pointer.pointee.lpVtbl.pointee.get_Item(actions.pointer, 1, &actionPointer), "Read startup action")
    let action = try COMReference(actionPointer)
    var execID = GUID(
        Data1: 0x4c3d_624d, Data2: 0xfd6b, Data3: 0x49a3, Data4: (0xb9, 0xb7, 0x09, 0xcb, 0x3c, 0xd3, 0xf0, 0x47))
    object = nil
    try checkCOM(
        action.pointer.pointee.lpVtbl.pointee.QueryInterface(action.pointer, &execID, &object),
        "Read executable startup action")
    let executable = try COMReference(object?.assumingMemoryBound(to: IExecAction.self))
    var path: BSTR?
    var arguments: BSTR?
    defer {
        SysFreeString(path)
        SysFreeString(arguments)
    }
    try checkCOM(
        executable.pointer.pointee.lpVtbl.pointee.get_Path(executable.pointer, &path), "Read startup executable")
    try checkCOM(
        executable.pointer.pointee.lpVtbl.pointee.get_Arguments(executable.pointer, &arguments),
        "Read startup arguments")
    let actionPath =
        path.map { String(decoding: UnsafeBufferPointer(start: $0, count: Int(SysStringLen($0))), as: UTF16.self) }
        ?? ""
    guard !actionPath.isEmpty, arguments == nil || SysStringLen(arguments) == 0,
        try equalWindowsNames(normalizedPath(actionPath), normalizedPath(executablePath()))
    else {
        throw WindowsError.unsupported("Startup task points to a different executable; run this version's installer.")
    }
    var runningPointer: UnsafeMutablePointer<IRunningTask>?
    try checkCOM(
        task.pointer.pointee.lpVtbl.pointee.Run(task.pointer, empty, &runningPointer), "Start SwiftyToys task")
    let running = try COMReference(runningPointer)
    _ = running.pointer
}
