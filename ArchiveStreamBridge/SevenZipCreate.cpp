#include "include/ArchiveStreamBridge.h"
#include "../SevenZip/CPP/7zip/Archive/IArchive.h"
#include "../SevenZip/CPP/7zip/IPassword.h"
#include "../SevenZip/CPP/Common/UTFConvert.h"
#include "../SevenZip/CPP/Common/MyCom.h"
#include "../SevenZip/CPP/Windows/PropVariant.h"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <limits>
#include <mutex>
#include <sys/stat.h>
#include <unistd.h>

STDAPI GetNumberOfFormats(UINT32 *count);
STDAPI GetHandlerProperty2(UInt32 index, PROPID property, PROPVARIANT *value);
STDAPI CreateArchiver(const GUID *classID, const GUID *interfaceID, void **object);

namespace {
HRESULT createArchive(int32_t format, CMyComPtr<IOutArchive> &archive) {
    const wchar_t *names[] = {L"7z", L"zip", L"tar", L"gzip", L"bzip2", L"xz"};
    if (format < 0 || format >= 6) return E_INVALIDARG;
    UINT32 count = 0;
    RINOK(GetNumberOfFormats(&count))
    for (UINT32 index = 0; index < count; ++index) {
        NWindows::NCOM::CPropVariant name;
        RINOK(GetHandlerProperty2(index, NArchive::NHandlerPropID::kName, &name))
        if (name.vt != VT_BSTR || wcscmp(name.bstrVal, names[format]) != 0) continue;
        NWindows::NCOM::CPropVariant identifier;
        RINOK(GetHandlerProperty2(index, NArchive::NHandlerPropID::kClassID, &identifier))
        if (identifier.vt != VT_BSTR || SysStringByteLen(identifier.bstrVal) != sizeof(GUID)) return E_FAIL;
        GUID classID;
        memcpy(&classID, identifier.bstrVal, sizeof(classID));
        void *object = nullptr;
        RINOK(CreateArchiver(&classID, &IID_IOutArchive, &object))
        archive.Attach(static_cast<IOutArchive *>(object));
        return S_OK;
    }
    return CLASS_E_CLASSNOTAVAILABLE;
}

struct Progress {
    detours_archive_progress callback;
    void *context;
    uint64_t bytes = 0;
    std::mutex mutex;
    HRESULT report(uint64_t added = 0) {
        std::lock_guard<std::mutex> guard(mutex);
        if (added > std::numeric_limits<uint64_t>::max() - bytes) return E_FAIL;
        bytes += added;
        return callback && callback(context, bytes) != 0 ? E_ABORT : S_OK;
    }
};

class Input final : public ISequentialInStream, public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(ISequentialInStream)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE
    Z7_IFACE_COM7_IMP(ISequentialInStream)
    const detours_archive_entry &entry;
    int descriptor;
    Progress &progress;
    uint64_t offset = 0;
public:
    Input(const detours_archive_entry &item, int file, Progress &reporter): entry(item), descriptor(file), progress(reporter) {}
    ~Input() { if (descriptor >= 0) close(descriptor); }
};

Z7_COM7F_IMF(Input::Read(void *data, UInt32 size, UInt32 *processed)) {
    if (processed) *processed = 0;
    RINOK(progress.report())
    size = static_cast<UInt32>(std::min<uint64_t>(std::min<UInt32>(size, 65536), entry.size - offset));
    if (!size) return S_OK;
    ssize_t count;
    if (entry.link_bytes) {
        memcpy(data, static_cast<const char *>(entry.link_bytes) + offset, size);
        count = size;
    } else {
        do { count = pread(descriptor, data, size, static_cast<off_t>(offset)); } while (count < 0 && errno == EINTR);
        if (count <= 0) return E_FAIL;
    }
    offset += static_cast<uint64_t>(count);
    if (processed) *processed = static_cast<UInt32>(count);
    return progress.report(static_cast<uint64_t>(count));
}

class Output final : public IOutStream, public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(IOutStream)
    Z7_COM_QI_ENTRY(ISequentialOutStream)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE
    Z7_IFACE_COM7_IMP(ISequentialOutStream)
    Z7_IFACE_COM7_IMP(IOutStream)
    int descriptor;
    uint64_t offset = 0;
    Progress &progress;
public:
    Output(int file, Progress &reporter): descriptor(file), progress(reporter) {}
};

Z7_COM7F_IMF(Output::Write(const void *data, UInt32 size, UInt32 *processed)) {
    if (processed) *processed = 0;
    const auto *bytes = static_cast<const char *>(data);
    UInt32 total = 0;
    while (total < size) {
        RINOK(progress.report())
        const UInt32 bounded = std::min<UInt32>(size - total, 65536);
        if (offset > static_cast<uint64_t>(std::numeric_limits<off_t>::max()) - bounded) return E_INVALIDARG;
        ssize_t count;
        do { count = pwrite(descriptor, bytes + total, bounded, static_cast<off_t>(offset)); } while (count < 0 && errno == EINTR);
        if (count <= 0) return E_FAIL;
        total += static_cast<UInt32>(count);
        offset += static_cast<uint64_t>(count);
        if (processed) *processed = total;
        RINOK(progress.report(static_cast<uint64_t>(count)))
    }
    return S_OK;
}

Z7_COM7F_IMF(Output::Seek(Int64 distance, UInt32 origin, UInt64 *position)) {
    uint64_t base;
    if (origin == SEEK_SET) base = 0;
    else if (origin == SEEK_CUR) base = offset;
    else if (origin == SEEK_END) {
        struct stat information;
        if (fstat(descriptor, &information) != 0 || information.st_size < 0) return E_FAIL;
        base = static_cast<uint64_t>(information.st_size);
    } else return E_INVALIDARG;
    if (distance < 0) {
        const uint64_t backwards = static_cast<uint64_t>(-(distance + 1)) + 1;
        if (backwards > base) return E_INVALIDARG;
        offset = base - backwards;
    } else {
        if (static_cast<uint64_t>(distance) > static_cast<uint64_t>(std::numeric_limits<off_t>::max()) - base) return E_INVALIDARG;
        offset = base + static_cast<uint64_t>(distance);
    }
    if (position) *position = offset;
    return S_OK;
}

Z7_COM7F_IMF(Output::SetSize(UInt64 size)) {
    RINOK(progress.report())
    if (size > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) return E_INVALIDARG;
    return ftruncate(descriptor, static_cast<off_t>(size)) == 0 ? S_OK : E_FAIL;
}

class Update final : public IArchiveUpdateCallback, public ICryptoGetTextPassword2, public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(IArchiveUpdateCallback)
    Z7_COM_QI_ENTRY(IProgress)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword2)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE
    Z7_IFACE_COM7_IMP(IProgress)
    Z7_IFACE_COM7_IMP(IArchiveUpdateCallback)
    Z7_IFACE_COM7_IMP(ICryptoGetTextPassword2)
    const detours_archive_entry *entries;
    uint32_t count;
    const char *password;
    detours_archive_input openInput;
    Progress &progress;
public:
    Update(const detours_archive_entry *items, uint32_t length, const char *secret, detours_archive_input opener, Progress &reporter):
        entries(items), count(length), password(secret), openInput(opener), progress(reporter) {}
};

Z7_COM7F_IMF(Update::SetTotal(UInt64)) { return progress.report(); }
Z7_COM7F_IMF(Update::SetCompleted(const UInt64 *)) { return progress.report(); }
Z7_COM7F_IMF(Update::SetOperationResult(Int32 result)) { return result == 0 ? S_OK : E_FAIL; }
Z7_COM7F_IMF(Update::GetUpdateItemInfo(UInt32 index, Int32 *newData, Int32 *newProperties, UInt32 *archiveIndex)) {
    if (index >= count) return E_INVALIDARG;
    *newData = 1;
    *newProperties = 1;
    *archiveIndex = static_cast<UInt32>(-1);
    return progress.report();
}
Z7_COM7F_IMF(Update::GetProperty(UInt32 index, PROPID property, PROPVARIANT *value)) {
    if (index >= count) return E_INVALIDARG;
    const auto &entry = entries[index];
    NWindows::NCOM::CPropVariant result;
    switch (property) {
    case kpidPath: {
        UString name;
        if (!ConvertUTF8ToUnicode(AString(entry.name), name)) return E_INVALIDARG;
        result = name;
        break;
    }
    case kpidIsDir: result = (entry.is_directory != 0); break;
    case kpidSize: result = static_cast<UInt64>(entry.size); break;
    case kpidAttrib: result = static_cast<UInt32>(0x8000 | (entry.mode << 16)); break;
    case kpidPosixAttrib: result = static_cast<UInt32>(entry.mode); break;
    case kpidUserId: result = static_cast<UInt32>(entry.user_id); break;
    case kpidGroupId: result = static_cast<UInt32>(entry.group_id); break;
    case kpidSymLink: {
        if (!entry.link_bytes) break;
        if (entry.size > std::numeric_limits<UInt32>::max()) return E_INVALIDARG;
        AString bytes;
        bytes.SetFrom(static_cast<const char *>(entry.link_bytes), static_cast<UInt32>(entry.size));
        UString target;
        if (!ConvertUTF8ToUnicode(bytes, target)) return E_INVALIDARG;
        result = target;
        break;
    }
    case kpidHardLink: {
        if (!entry.hard_link) break;
        UString target;
        if (!ConvertUTF8ToUnicode(AString(entry.hard_link), target)) return E_INVALIDARG;
        result = target;
        break;
    }
    case kpidMTime: {
        FILETIME time;
        time.dwLowDateTime = static_cast<UInt32>(entry.modified_filetime);
        time.dwHighDateTime = static_cast<UInt32>(entry.modified_filetime >> 32);
        result = time;
        break;
    }
    default: break;
    }
    result.Detach(value);
    return S_OK;
}
Z7_COM7F_IMF(Update::GetStream(UInt32 index, ISequentialInStream **stream)) {
    *stream = nullptr;
    if (index >= count) return E_INVALIDARG;
    RINOK(progress.report())
    if (!entries[index].is_directory) {
        int descriptor = -1;
        if (!entries[index].link_bytes) {
            descriptor = openInput ? openInput(progress.context, index) : dup(entries[index].descriptor);
            if (descriptor < 0) return E_FAIL;
        }
        CMyComPtr<ISequentialInStream> input = new Input(entries[index], descriptor, progress);
        *stream = input.Detach();
    }
    return S_OK;
}
Z7_COM7F_IMF(Update::CryptoGetTextPassword2(Int32 *defined, BSTR *value)) {
    *defined = password && *password ? 1 : 0;
    *value = nullptr;
    if (*defined) {
        UString secret;
        if (!ConvertUTF8ToUnicode(AString(password), secret)) return E_INVALIDARG;
        *value = SysAllocString(secret);
        if (!*value) return E_OUTOFMEMORY;
    }
    return S_OK;
}
}

extern "C" int32_t detours_archive_create(int32_t format, int output, const detours_archive_entry *entries,
                                           uint32_t count, const char *password,
                                           detours_archive_input open_input,
                                           detours_archive_progress callback, void *context) {
    try {
        struct stat information;
        if (fstat(output, &information) != 0 || !S_ISREG(information.st_mode) || information.st_size != 0) return E_INVALIDARG;
        if (count && !entries) return E_INVALIDARG;
        for (uint32_t index = 0; index < count; ++index) {
            const auto &entry = entries[index];
            if (!entry.name || !*entry.name || entry.size > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) return E_INVALIDARG;
            if (!entry.is_directory && !entry.link_bytes && entry.descriptor < 0 && !open_input) return E_INVALIDARG;
        }
        Progress progress{callback, context};
        CMyComPtr<IOutArchive> archive;
        RINOK(createArchive(format, archive))
        if (password && *password) {
            if (format != DETOURS_ARCHIVE_SEVEN_Z && format != DETOURS_ARCHIVE_ZIP) return E_INVALIDARG;
            CMyComPtr<ISetProperties> properties;
            RINOK(archive.QueryInterface(IID_ISetProperties, &properties))
            const wchar_t *names[] = {format == DETOURS_ARCHIVE_ZIP ? L"em" : L"he"};
            NWindows::NCOM::CPropVariant encrypted;
            if (format == DETOURS_ARCHIVE_ZIP) encrypted = L"AES256";
            else encrypted = true;
            RINOK(properties->SetProperties(names, &encrypted, 1))
        }
        CMyComPtr<IOutStream> stream = new Output(output, progress);
        CMyComPtr<IArchiveUpdateCallback> update = new Update(entries, count, password, open_input, progress);
        const HRESULT result = archive->UpdateItems(stream, count, update);
        if (result != S_OK) return result;
        return fsync(output) == 0 ? S_OK : E_FAIL;
    } catch (...) { return E_FAIL; }
}
