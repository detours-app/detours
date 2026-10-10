#include "include/ArchiveStreamBridge.h"
#include "../SevenZip/CPP/7zip/Archive/IArchive.h"
#include "../SevenZip/CPP/7zip/IPassword.h"
#include "../SevenZip/CPP/Common/MyCom.h"
#include "../SevenZip/CPP/Common/UTFConvert.h"
#include "../SevenZip/CPP/Windows/PropVariant.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <limits>
#include <mutex>
#include <set>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

STDAPI GetNumberOfFormats(UINT32 *count);
STDAPI GetHandlerProperty2(UInt32 index, PROPID property, PROPVARIANT *value);
STDAPI CreateArchiver(const GUID *classID, const GUID *interfaceID, void **object);

namespace {
struct ReaderState {
    detours_archive_progress callback;
    void *context;
    const char *password;
    const char *inputName;
    detours_archive_volume volume;
    bool rar;
    int32_t failure = 0;
    std::set<std::string> volumeNames;
    uint64_t bytes = 0;
    std::atomic<bool> passwordRequested{false};
    std::atomic<bool> passwordRejected{false};
    std::mutex mutex;
    HRESULT report(uint64_t added = 0) {
        std::lock_guard<std::mutex> guard(mutex);
        if (added > std::numeric_limits<uint64_t>::max() - bytes) return E_FAIL;
        bytes += added;
        return callback && callback(context, bytes) != 0 ? E_ABORT : S_OK;
    }
    HRESULT secret(BSTR *value) {
        passwordRequested = true;
        *value = nullptr;
        if (!password) { passwordRejected = true; return E_ABORT; }
        AString_Wipe encoded;
        encoded += password;
        UString_Wipe decoded;
        if (!ConvertUTF8ToUnicode(encoded, decoded)) return E_INVALIDARG;
        *value = SysAllocString(decoded);
        return *value ? S_OK : E_OUTOFMEMORY;
    }
};

class Input final : public IInStream, public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(IInStream)
    Z7_COM_QI_ENTRY(ISequentialInStream)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE
    Z7_IFACE_COM7_IMP(ISequentialInStream)
    Z7_IFACE_COM7_IMP(IInStream)
    int descriptor;
    uint64_t length;
    uint64_t offset = 0;
    ReaderState &state;
    std::string volumeName;
public:
    Input(int file, uint64_t size, ReaderState &reader): descriptor(file), length(size), state(reader) {}
    Input(std::string name, uint64_t size, ReaderState &reader):
        descriptor(-1), length(size), state(reader), volumeName(std::move(name)) {}
};
Z7_COM7F_IMF(Input::Read(void *data, UInt32 size, UInt32 *processed)) {
    if (processed) *processed = 0;
    RINOK(state.report())
    if (offset >= length) return S_OK;
    size = static_cast<UInt32>(std::min<uint64_t>(std::min<UInt32>(size, 65536), length - offset));
    if (!size) return S_OK;
    int source = descriptor;
    if (!volumeName.empty()) {
        source = state.volume(state.context, volumeName.c_str());
        if (source < 0) return E_ABORT;
        struct stat info;
        if (fstat(source, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
            static_cast<uint64_t>(info.st_size) != length) { close(source); return E_FAIL; }
    }
    ssize_t count;
    do { count = pread(source, data, size, static_cast<off_t>(offset)); } while (count < 0 && errno == EINTR);
    if (!volumeName.empty()) close(source);
    if (count <= 0) return E_FAIL;
    offset += static_cast<uint64_t>(count);
    if (processed) *processed = static_cast<UInt32>(count);
    return state.report(static_cast<uint64_t>(count));
}
Z7_COM7F_IMF(Input::Seek(Int64 distance, UInt32 origin, UInt64 *position)) {
    uint64_t base;
    if (origin == SEEK_SET) base = 0;
    else if (origin == SEEK_CUR) base = offset;
    else if (origin == SEEK_END) base = length;
    else return E_INVALIDARG;
    if (distance < 0) {
        const uint64_t backwards = static_cast<uint64_t>(-(distance + 1)) + 1;
        if (backwards > base) return E_INVALIDARG;
        offset = base - backwards;
    } else {
        if (static_cast<uint64_t>(distance) > static_cast<uint64_t>(std::numeric_limits<off_t>::max()) - base) return E_INVALIDARG;
        offset = base + static_cast<uint64_t>(distance);
    }
    if (position) *position = offset;
    return state.report();
}

class Open final : public IArchiveOpenCallback, public ICryptoGetTextPassword,
                   public IArchiveOpenVolumeCallback, public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(IArchiveOpenCallback)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
    Z7_COM_QI_ENTRY(IArchiveOpenVolumeCallback)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE
    Z7_IFACE_COM7_IMP(IArchiveOpenCallback)
    Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IArchiveOpenVolumeCallback)
    ReaderState &state;
public:
    explicit Open(ReaderState &reader): state(reader) {}
};
Z7_COM7F_IMF(Open::SetTotal(const UInt64 *, const UInt64 *)) { return state.report(); }
Z7_COM7F_IMF(Open::SetCompleted(const UInt64 *, const UInt64 *)) { return state.report(); }
Z7_COM7F_IMF(Open::CryptoGetTextPassword(BSTR *value)) { return state.secret(value); }
Z7_COM7F_IMF(Open::GetProperty(PROPID property, PROPVARIANT *value)) {
    NWindows::NCOM::CPropVariant result;
    if (property == kpidName && state.inputName) {
        UString name;
        if (!ConvertUTF8ToUnicode(AString(state.inputName), name)) return E_INVALIDARG;
        result = name;
    }
    result.Detach(value);
    return S_OK;
}
Z7_COM7F_IMF(Open::GetStream(const wchar_t *name, IInStream **stream)) {
    *stream = nullptr;
    RINOK(state.report())
    if (!state.rar || !name || !*name || wcschr(name, L'/') || wcschr(name, L'\\') ||
        wcschr(name, L':') || wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0) return E_INVALIDARG;
    AString encoded;
    ConvertUnicodeToUTF8(UString(name), encoded);
    state.volumeNames.insert(encoded.Ptr());
    if (state.volumeNames.size() > 1024) { state.failure = -1007; return E_ABORT; }
    if (!state.volume) { state.failure = -1006; return S_FALSE; }
    const int descriptor = state.volume(state.context, encoded.Ptr());
    if (descriptor < 0) { state.failure = -1006; return E_ABORT; }
    struct stat info;
    const bool valid = fstat(descriptor, &info) == 0 && S_ISREG(info.st_mode) && info.st_size >= 0;
    close(descriptor);
    if (!valid) return E_INVALIDARG;
    CMyComPtr<IInStream> input = new Input(encoded.Ptr(), static_cast<uint64_t>(info.st_size), state);
    *stream = input.Detach();
    return S_OK;
}

class Output final : public ISequentialOutStream, public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(ISequentialOutStream)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE
    Z7_IFACE_COM7_IMP(ISequentialOutStream)
    int descriptor;
    uint64_t offset = 0;
    uint64_t length;
    bool bounded;
    ReaderState &state;
public:
    Output(int file, ReaderState &reader, uint64_t size, bool hasSize):
        descriptor(file), length(size), bounded(hasSize), state(reader) {}
    ~Output() { close(descriptor); }
    HRESULT flush() {
        if (bounded && offset != length) return E_FAIL;
        return fsync(descriptor) == 0 ? S_OK : E_FAIL;
    }
};
Z7_COM7F_IMF(Output::Write(const void *data, UInt32 size, UInt32 *processed)) {
    if (processed) *processed = 0;
    if (bounded && (offset > length || size > length - offset)) return E_FAIL;
    UInt32 total = 0;
    while (total < size) {
        RINOK(state.report())
        const UInt32 bounded = std::min<UInt32>(size - total, 65536);
        if (offset > static_cast<uint64_t>(std::numeric_limits<off_t>::max()) - bounded) return E_INVALIDARG;
        ssize_t count;
        do { count = pwrite(descriptor, static_cast<const char *>(data) + total, bounded, static_cast<off_t>(offset)); }
        while (count < 0 && errno == EINTR);
        if (count <= 0) return E_FAIL;
        total += static_cast<UInt32>(count);
        offset += static_cast<uint64_t>(count);
        if (processed) *processed = total;
        RINOK(state.report(static_cast<uint64_t>(count)))
    }
    return S_OK;
}

class Extract final : public IArchiveExtractCallback, public ICryptoGetTextPassword, public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(IArchiveExtractCallback)
    Z7_COM_QI_ENTRY(IProgress)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE
    Z7_IFACE_COM7_IMP(IProgress)
    Z7_IFACE_COM7_IMP(IArchiveExtractCallback)
    Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
    IInArchive *archive;
    detours_archive_input output;
    struct stat source;
    ReaderState &state;
    CMyComPtr<ISequentialOutStream> current;
    Output *currentOutput = nullptr;
public:
    Extract(IInArchive *reader, detours_archive_input opener, const struct stat &input, ReaderState &reporter):
        archive(reader), output(opener), source(input), state(reporter) {}
};
Z7_COM7F_IMF(Extract::SetTotal(UInt64)) { return state.report(); }
Z7_COM7F_IMF(Extract::SetCompleted(const UInt64 *)) { return state.report(); }
Z7_COM7F_IMF(Extract::PrepareOperation(Int32)) { return state.report(); }
Z7_COM7F_IMF(Extract::CryptoGetTextPassword(BSTR *value)) { return state.secret(value); }
Z7_COM7F_IMF(Extract::SetOperationResult(Int32 result)) {
    if (state.rar && result != NArchive::NExtract::NOperationResult::kOK) {
        if (result == NArchive::NExtract::NOperationResult::kWrongPassword) state.failure = -1002;
        else if (result == NArchive::NExtract::NOperationResult::kUnsupportedMethod) state.failure = -1005;
        else state.failure = state.passwordRequested ? -1003 : -1004;
        return E_FAIL;
    }
    if (state.passwordRequested && (result == NArchive::NExtract::NOperationResult::kWrongPassword ||
        result == NArchive::NExtract::NOperationResult::kDataError || result == NArchive::NExtract::NOperationResult::kCRCError)) {
        state.passwordRejected = true;
    }
    if (result != NArchive::NExtract::NOperationResult::kOK) return E_FAIL;
    if (currentOutput) RINOK(currentOutput->flush())
    current.Release();
    currentOutput = nullptr;
    return state.report();
}
Z7_COM7F_IMF(Extract::GetStream(UInt32 index, ISequentialOutStream **stream, Int32 mode)) {
    *stream = nullptr;
    current.Release();
    currentOutput = nullptr;
    RINOK(state.report())
    if (mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
    NWindows::NCOM::CPropVariant directory;
    RINOK(archive->GetProperty(index, kpidIsDir, &directory))
    if (directory.vt == VT_BOOL && directory.boolVal != VARIANT_FALSE) return S_OK;
    const int descriptor = output(state.context, index);
    if (descriptor < 0) return E_ABORT;
    struct stat information;
    if (fstat(descriptor, &information) != 0 || !S_ISREG(information.st_mode) || information.st_size != 0 ||
        (information.st_dev == source.st_dev && information.st_ino == source.st_ino)) {
        close(descriptor);
        return E_INVALIDARG;
    }
    NWindows::NCOM::CPropVariant size;
    const HRESULT readSize = archive->GetProperty(index, kpidSize, &size);
    if (readSize != S_OK || (size.vt == VT_UI8 && size.uhVal.QuadPart > static_cast<uint64_t>(std::numeric_limits<off_t>::max()))) {
        close(descriptor);
        return E_INVALIDARG;
    }
    currentOutput = new Output(descriptor, state, size.vt == VT_UI8 ? size.uhVal.QuadPart : 0, state.rar && size.vt == VT_UI8);
    current = currentOutput;
    *stream = current;
    (*stream)->AddRef();
    return S_OK;
}

HRESULT propertyText(IInArchive *archive, UInt32 index, PROPID property, AString &text) {
    NWindows::NCOM::CPropVariant value;
    RINOK(archive->GetProperty(index, property, &value))
    if (value.vt == VT_EMPTY) return S_OK;
    if (value.vt != VT_BSTR) return E_FAIL;
    // Embedded NULs must not be shortened into a different filesystem name.
    if (wcslen(value.bstrVal) != SysStringLen(value.bstrVal)) return E_INVALIDARG;
    ConvertUnicodeToUTF8(UString(value.bstrVal), text);
    return S_OK;
}
HRESULT visitMember(IInArchive *archive, UInt32 index, detours_archive_visit visit, void *context) {
    AString name, symbolic, hard;
    RINOK(propertyText(archive, index, kpidPath, name))
    RINOK(propertyText(archive, index, kpidSymLink, symbolic))
    RINOK(propertyText(archive, index, kpidHardLink, hard))
    detours_archive_member member{};
    member.name = name.Ptr();
    member.symbolic_link = symbolic.IsEmpty() ? nullptr : symbolic.Ptr();
    member.hard_link = hard.IsEmpty() ? nullptr : hard.Ptr();
    NWindows::NCOM::CPropVariant value;
    RINOK(archive->GetProperty(index, kpidIsDir, &value))
    member.is_directory = value.vt == VT_BOOL && value.boolVal != VARIANT_FALSE;
    value.Clear();
    RINOK(archive->GetProperty(index, kpidEncrypted, &value))
    member.is_encrypted = value.vt == VT_BOOL && value.boolVal != VARIANT_FALSE;
    value.Clear();
    RINOK(archive->GetProperty(index, kpidSplitBefore, &value))
    member.split_before = value.vt == VT_BOOL && value.boolVal != VARIANT_FALSE;
    value.Clear();
    RINOK(archive->GetProperty(index, kpidSplitAfter, &value))
    member.split_after = value.vt == VT_BOOL && value.boolVal != VARIANT_FALSE;
    value.Clear();
    RINOK(archive->GetProperty(index, kpidSize, &value))
    if (value.vt == VT_UI8) { member.size = value.uhVal.QuadPart; member.has_size = 1; }
    value.Clear();
    RINOK(archive->GetProperty(index, kpidMTime, &value))
    if (value.vt == VT_FILETIME) {
        member.modified_filetime = (static_cast<uint64_t>(value.filetime.dwHighDateTime) << 32) | value.filetime.dwLowDateTime;
        member.has_modified = 1;
    }
    value.Clear();
    RINOK(archive->GetProperty(index, kpidPosixAttrib, &value))
    if (value.vt == VT_UI4) member.mode = value.ulVal;
    else {
        value.Clear();
        RINOK(archive->GetProperty(index, kpidAttrib, &value))
        if (value.vt == VT_UI4 && (value.ulVal & 0x8000)) member.mode = value.ulVal >> 16;
    }
    return visit(context, index, &member) == 0 ? S_OK : E_ABORT;
}

HRESULT openFormat(int32_t format, CMyComPtr<IInArchive> &archive) {
    const wchar_t *names[] = {L"7z", L"zip", L"tar", L"gzip", L"bzip2", L"xz", L"Rar", L"Rar5"};
    if (format < 0 || format >= 8) return E_INVALIDARG;
    UINT32 count = 0;
    RINOK(GetNumberOfFormats(&count))
    for (UINT32 index = 0; index < count; ++index) {
        NWindows::NCOM::CPropVariant name, identifier;
        RINOK(GetHandlerProperty2(index, NArchive::NHandlerPropID::kName, &name))
        if (name.vt != VT_BSTR || wcscmp(name.bstrVal, names[format]) != 0) continue;
        RINOK(GetHandlerProperty2(index, NArchive::NHandlerPropID::kClassID, &identifier))
        if (identifier.vt != VT_BSTR || SysStringByteLen(identifier.bstrVal) != sizeof(GUID)) return E_FAIL;
        GUID classID;
        memcpy(&classID, identifier.bstrVal, sizeof(classID));
        void *object = nullptr;
        RINOK(CreateArchiver(&classID, &IID_IInArchive, &object))
        archive.Attach(static_cast<IInArchive *>(object));
        return S_OK;
    }
    return CLASS_E_CLASSNOTAVAILABLE;
}

HRESULT checkRarIntegrity(IInArchive *archive, ReaderState &state) {
    if (state.failure) return state.failure;
    NWindows::NCOM::CPropVariant flags, error;
    RINOK(archive->GetArchiveProperty(kpidErrorFlags, &flags))
    RINOK(archive->GetArchiveProperty(kpidError, &error))
    if (error.vt == VT_BSTR && SysStringLen(error.bstrVal)) return -1006;
    if (flags.vt != VT_EMPTY && flags.vt != VT_UI4) return -1004;
    if (flags.vt == VT_UI4 && flags.ulVal) {
        if (flags.ulVal & (kpv_ErrorFlags_UnsupportedMethod | kpv_ErrorFlags_UnsupportedFeature)) return -1005;
        if (flags.ulVal & kpv_ErrorFlags_EncryptedHeadersError) return -1003;
        return -1004;
    }
    return S_OK;
}
}

extern "C" int32_t detours_rar_inspect(int32_t format, int input, const char *password,
                                       detours_rar_volume_info *info, detours_archive_visit visit,
                                       detours_archive_progress progress, void *context) {
    try {
        struct stat information;
        if ((format != 6 && format != 7) || !info || !visit || fstat(input, &information) != 0 ||
            !S_ISREG(information.st_mode) || information.st_size < 0) return E_INVALIDARG;
        ReaderState state{progress, context, password, nullptr, nullptr, true};
        CMyComPtr<IInArchive> archive;
        RINOK(openFormat(format, archive))
        CMyComPtr<IInStream> stream = new Input(input, static_cast<uint64_t>(information.st_size), state);
        CMyComPtr<IArchiveOpenCallback> opener = new Open(state);
        const HRESULT opened = archive->Open(stream, nullptr, opener);
        if (state.passwordRejected) return -1001;
        if (opened != S_OK) return state.passwordRequested ? -1003 : -1004;
        NWindows::NCOM::CPropVariant flags, volume, index;
        RINOK(archive->GetArchiveProperty(kpidErrorFlags, &flags))
        if (flags.vt == VT_UI4 && flags.ulVal) {
            if (flags.ulVal & (kpv_ErrorFlags_UnsupportedMethod | kpv_ErrorFlags_UnsupportedFeature)) return -1005;
            if (flags.ulVal & kpv_ErrorFlags_EncryptedHeadersError) return -1003;
            return -1004;
        }
        RINOK(archive->GetArchiveProperty(kpidIsVolume, &volume))
        RINOK(archive->GetArchiveProperty(kpidVolumeIndex, &index))
        *info = {};
        info->is_volume = volume.vt == VT_BOOL && volume.boolVal != VARIANT_FALSE;
        info->has_index = index.vt == VT_UI4;
        if (info->has_index) info->index = index.ulVal;
        UInt32 count = 0;
        RINOK(archive->GetNumberOfItems(&count))
        for (UInt32 item = 0; item < count; ++item) {
            RINOK(state.report())
            RINOK(visitMember(archive, item, visit, context))
        }
        return archive->Close();
    } catch (...) { return E_FAIL; }
}

extern "C" int32_t detours_archive_read(int32_t format, int input, const char *password,
                                        const char *input_name, detours_archive_volume open_volume,
                                        detours_archive_visit visit, detours_archive_input output,
                                        detours_archive_progress progress, void *context) {
    try {
        struct stat information;
        if (!visit || fstat(input, &information) != 0 || !S_ISREG(information.st_mode) || information.st_size < 0) return E_INVALIDARG;
        ReaderState state{progress, context, password, input_name, open_volume, format == 6 || format == 7};
        if (input_name) state.volumeNames.insert(input_name);
        CMyComPtr<IInArchive> archive;
        RINOK(openFormat(format, archive))
        CMyComPtr<IInStream> stream = new Input(input, static_cast<uint64_t>(information.st_size), state);
        CMyComPtr<IArchiveOpenCallback> opener = new Open(state);
        const HRESULT opened = archive->Open(stream, nullptr, opener);
        if (state.rar) {
            if (state.failure) return state.failure;
            if (state.passwordRejected) return -1001;
            if (opened != S_OK) return state.passwordRequested ? -1003 : -1004;
            RINOK(checkRarIntegrity(archive, state))
        }
        if (opened != S_OK) return state.passwordRejected || (state.passwordRequested && opened == S_FALSE) ? -1001 : opened;
        UInt32 count = 0;
        RINOK(archive->GetNumberOfItems(&count))
        for (UInt32 index = 0; index < count; ++index) {
            RINOK(state.report())
            RINOK(visitMember(archive, index, visit, context))
        }
        if (output) {
            CMyComPtr<IArchiveExtractCallback> extractor = new Extract(archive, output, information, state);
            const HRESULT extracted = archive->Extract(nullptr, static_cast<UInt32>(-1), 0, extractor);
            if (state.rar) {
                if (state.failure) return state.failure;
                if (state.passwordRejected) return -1001;
                if (extracted != S_OK) return state.passwordRequested ? -1003 : -1004;
                RINOK(checkRarIntegrity(archive, state))
            }
            if (extracted != S_OK) return state.passwordRejected ? -1001 : extracted;
        }
        return archive->Close();
    } catch (...) { return E_FAIL; }
}
