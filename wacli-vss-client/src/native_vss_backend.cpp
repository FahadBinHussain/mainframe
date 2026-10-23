#include "vss_client.h"
#ifdef _WIN32
#include <windows.h>
#include <vsbackup.h>
#include <algorithm>
#include <cwctype>
#include <map>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace wacli::vss {
namespace {
std::string failure(const char* stage, HRESULT hr) {
    std::ostringstream out;
    out << stage << " HRESULT=0x" << std::hex << static_cast<unsigned long>(hr);
    return out.str();
}
std::wstring wide(const std::string& input) {
    if (input.empty() || input.size() > 32760 || input.find('\0') != std::string::npos) return {};
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                                         static_cast<int>(input.size()), nullptr, 0);
    if (count <= 0) return {};
    std::wstring output(static_cast<std::size_t>(count), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                            static_cast<int>(input.size()), output.data(), count) != count) return {};
    return output;
}
std::string utf8(const std::wstring& input) {
    if (input.empty()) return {};
    const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input.data(),
                                         static_cast<int>(input.size()), nullptr, 0, nullptr, nullptr);
    if (count <= 0) return {};
    std::string output(static_cast<std::size_t>(count), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input.data(),
                            static_cast<int>(input.size()), output.data(), count, nullptr, nullptr) != count) return {};
    return output;
}
std::string guid_text(const GUID& id) {
    wchar_t text[40]{};
    if (!StringFromGUID2(id, text, 40)) return {};
    return utf8(text);
}
std::string volume_text(const wchar_t* input) {
    if (!input) return {};
    std::wstring text(input);
    for (auto& ch : text) ch = static_cast<wchar_t>(std::towlower(ch));
    return utf8(text);
}
struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE h) : value(h) {}
    ~Handle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};
struct Finder {
    HANDLE value;
    explicit Finder(HANDLE h) : value(h) {}
    ~Finder() { if (value != INVALID_HANDLE_VALUE) FindClose(value); }
};
bool valid_component(const std::wstring& part) {
    if (part.empty() || part == L"." || part == L".." || part.back() == L'.' || part.back() == L' ') return false;
    for (auto ch : part) {
        if (ch < 32 || ch == L':' || ch == L'/' || ch == L'<' || ch == L'>' ||
            ch == L'"' || ch == L'|' || ch == L'?' || ch == L'*') return false;
    }
    std::wstring name = part.substr(0, part.find(L'.'));
    for (auto& ch : name) ch = static_cast<wchar_t>(std::towupper(ch));
    if (name == L"CON" || name == L"PRN" || name == L"AUX" || name == L"NUL" ||
        name == L"CONIN$" || name == L"CONOUT$") return false;
    if (name.size() == 4 && (name.substr(0, 3) == L"COM" || name.substr(0, 3) == L"LPT") &&
        ((name[3] >= L'0' && name[3] <= L'9') || name[3] == L'\u00b9' ||
         name[3] == L'\u00b2' || name[3] == L'\u00b3')) return false;
    return true;
}
bool inspect(const std::wstring& path, bool require_directory, std::string& error) {
    Handle file(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (file.value == INVALID_HANDLE_VALUE) { error = "source entry inaccessible"; return false; }
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(file.value, &info)) { error = "source entry metadata unavailable"; return false; }
    if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
        (require_directory && (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0)) {
        error = "source reparse or unsupported entry";
        return false;
    }
    return true;
}
class NativeResolver final : public VolumeResolver {
public:
    bool resolve(const std::string& root, ResolvedRoot& output, std::string& error) override {
        const auto path = wide(root);
        // Deliberately do not accept device/UNC/volume syntax as caller roots.
        if (path.size() < 3 || path.size() > 240 || path[0] < L'A' || path[0] > L'Z' ||
            path[1] != L':' || path[2] != L'\\' || (path.size() > 3 && path.back() == L'\\')) {
            error = "noncanonical drive-absolute source root"; return false;
        }
        if (GetDriveTypeW(path.substr(0, 3).c_str()) != DRIVE_FIXED) {
            error = "nonlocal or unsupported source drive"; return false;
        }
        if (!inspect(path.substr(0, 3), true, error)) return false;
        for (std::size_t begin = 3; begin < path.size();) {
            auto end = path.find(L'\\', begin);
            if (end == std::wstring::npos) end = path.size();
            if (!valid_component(path.substr(begin, end - begin)) ||
                !inspect(path.substr(0, end), true, error)) {
                if (error.empty()) error = "ambiguous source path component";
                return false;
            }
            begin = end + 1;
        }
        // Reject aliases (including 8.3 spellings) rather than claiming approval
        // of a different canonical tree. The short MAX_PATH subset is deliberate.
        wchar_t expanded[32768]{};
        const DWORD expanded_size = GetLongPathNameW(path.c_str(), expanded, 32768);
        if (expanded_size == 0 || expanded_size >= 32768 || path != expanded) {
            error = "source root is not its canonical long path"; return false;
        }
        wchar_t mount[32768]{};
        wchar_t volume[128]{};
        if (!GetVolumePathNameW(path.c_str(), mount, 32768) ||
            !GetVolumeNameForVolumeMountPointW(mount, volume, 128)) {
            error = "source volume resolution failed"; return false;
        }
        const std::string identity = volume_text(volume);
        if (!canonical_volume(identity)) { error = "unsupported source volume identity"; return false; }
        // Enumerate the ENTIRE explicit tree; never skip a mount, unreadable
        // entry or reparse point. Bounded, no recursive following of links.
        std::vector<std::pair<std::wstring, unsigned>> pending{{path, 0}};
        std::size_t entries = 0;
        while (!pending.empty()) {
            auto current = std::move(pending.back()); pending.pop_back();
            if (current.second > 128 || current.first.size() > 240 || ++entries > 100000) {
                error = "source inventory exceeds development limits"; return false;
            }
            if (!inspect(current.first, true, error)) return false;
            WIN32_FIND_DATAW data{};
            Finder finder(FindFirstFileW((current.first + L"\\*").c_str(), &data));
            if (finder.value == INVALID_HANDLE_VALUE) {
                if (GetLastError() == ERROR_FILE_NOT_FOUND) continue;
                error = "source directory enumeration failed"; return false;
            }
            do {
                const std::wstring name(data.cFileName);
                if (name == L"." || name == L"..") continue;
                if (++entries > 100000 || !valid_component(name)) {
                    error = "unsupported source inventory entry"; return false;
                }
                const auto child = current.first + L"\\" + name;
                if (child.size() > 240 || (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                    !inspect(child, false, error)) {
                    if (error.empty()) error = "source reparse or unsupported entry";
                    return false;
                }
                if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
                    pending.emplace_back(child, current.second + 1);
            } while (FindNextFileW(finder.value, &data));
            if (GetLastError() != ERROR_NO_MORE_FILES) {
                error = "source enumeration incomplete"; return false;
            }
        }
        output = {root, identity};
        return true;
    }
};
class NativeBackend final : public Backend {
    IVssBackupComponents* components_ = nullptr;
    IVssAsync* async_ = nullptr;
    GUID set_ = GUID_NULL;
    bool com_owned_ = false;
    bool started_ = false;
    bool terminal_ = false;
    bool snapshot_finished_ = false;
    bool used_ = false;
    std::map<std::string, GUID> snapshots_;
public:
    ~NativeBackend() override {
        if (started_) cleanup(false, 0);
        if (async_) async_->Release();
        if (components_) components_->Release();
        if (com_owned_) CoUninitialize();
    }
    bool initialize(std::string& error) override {
        if (used_) { error = "requester is single-use"; return false; }
        used_ = true;
        HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(hr)) { error = failure("CoInitializeEx", hr); return false; }
        com_owned_ = true; // S_FALSE also needs a matching CoUninitialize.
        hr = CoInitializeSecurity(nullptr, -1, nullptr, nullptr, RPC_C_AUTHN_LEVEL_PKT_PRIVACY,
                                  RPC_C_IMP_LEVEL_IMPERSONATE, nullptr, EOAC_NONE, nullptr);
        // Do not assume an embedding host's existing COM security policy is safe.
        if (FAILED(hr)) { error = failure("CoInitializeSecurity", hr); return false; }
        hr = CreateVssBackupComponents(&components_);
        if (FAILED(hr)) { error = failure("CreateVssBackupComponents", hr); return false; }
        hr = components_->InitializeForBackup(nullptr);
        if (FAILED(hr)) { error = failure("InitializeForBackup", hr); return false; }
        return true;
    }
    bool set_writerless_backup_context(std::string& error) override {
        const HRESULT hr = components_->SetContext(VSS_CTX_FILE_SHARE_BACKUP);
        if (FAILED(hr)) { error = failure("SetContext", hr); return false; }
        return true;
    }
    bool start_snapshot_set(std::string& id, std::string& error) override {
        const HRESULT hr = components_->StartSnapshotSet(&set_);
        if (FAILED(hr)) { error = failure("StartSnapshotSet", hr); return false; }
        started_ = true;
        try {
            id = guid_text(set_);
        } catch (...) {
            cleanup(false, 0);
            throw;
        }
        if (id.empty()) {
            error = "set identity conversion failed";
            cleanup(false, 0);
            return false;
        }
        return true;
    }
    bool add_to_snapshot_set(const std::string& volume, std::string& id, std::string& error) override {
        auto path = wide(volume);
        BOOL supported = FALSE;
        HRESULT hr = components_->IsVolumeSupported(GUID_NULL, const_cast<VSS_PWSZ>(path.c_str()), &supported);
        if (FAILED(hr) || !supported) { error = "required source volume unsupported by VSS"; return false; }
        GUID snapshot = GUID_NULL;
        hr = components_->AddToSnapshotSet(const_cast<VSS_PWSZ>(path.c_str()), GUID_NULL, &snapshot);
        if (FAILED(hr)) { error = failure("AddToSnapshotSet", hr); return false; }
        id = guid_text(snapshot);
        if (id.empty() || snapshots_.count(id)) { error = "invalid snapshot identity"; return false; }
        snapshots_.emplace(id, snapshot);
        return true;
    }
    bool do_snapshot_set(std::string& error) override {
        const HRESULT hr = components_->DoSnapshotSet(&async_);
        if (FAILED(hr) || !async_) { error = failure("DoSnapshotSet", hr); return false; }
        return true;
    }
    AsyncState query_status(std::string& error) override {
        if (!async_) { error = "missing async operation"; return AsyncState::failed; }
        HRESULT status = E_UNEXPECTED;
        INT reserved = 0;
        const HRESULT hr = async_->QueryStatus(&status, &reserved);
        if (FAILED(hr)) { error = failure("QueryStatus", hr); return AsyncState::failed; }
        if (status == VSS_S_ASYNC_PENDING) { Sleep(100); return AsyncState::pending; }
        terminal_ = true;
        if (status == VSS_S_ASYNC_FINISHED) {
            snapshot_finished_ = true;
            return AsyncState::finished;
        }
        if (status == VSS_S_ASYNC_CANCELLED) return AsyncState::cancelled;
        error = failure("VSS operation", status);
        return AsyncState::failed;
    }
    bool verify_snapshot_set(const std::vector<SnapshotInfo>& expected, std::string& error) override {
        if (!components_ || !started_ || !snapshot_finished_) { error = "snapshot set is not held"; return false; }
        if (expected.size() != snapshots_.size()) { error = "snapshot count mismatch"; return false; }
        for (const auto& snapshot : expected) {
            const auto member = snapshots_.find(snapshot.snapshot_id);
            if (member == snapshots_.end()) { error = "snapshot membership missing"; return false; }
            VSS_SNAPSHOT_PROP property{};
            const HRESULT hr = components_->GetSnapshotProperties(member->second, &property);
            if (FAILED(hr)) { error = failure("GetSnapshotProperties", hr); return false; }
            // No exceptions may bypass VssFreeSnapshotProperties.
            struct Properties { VSS_SNAPSHOT_PROP& p; ~Properties() { VssFreeSnapshotProperties(&p); } } owned{property};
            const bool valid = IsEqualGUID(property.m_SnapshotId, member->second) &&
                IsEqualGUID(property.m_SnapshotSetId, set_) &&
                volume_text(property.m_pwszOriginalVolumeName) == snapshot.volume_guid &&
                property.m_lSnapshotsCount == static_cast<LONG>(expected.size()) &&
                property.m_eStatus == VSS_SS_CREATED && property.m_pwszSnapshotDeviceObject &&
                property.m_pwszSnapshotDeviceObject[0] != L'\0';
            if (!valid) { error = "snapshot properties mismatch"; return false; }
        }
        return true;
    }
    bool snapshot_device(const SnapshotInfo& expected, std::string& device, std::string& error) override {
        if (!components_ || !started_ || !snapshot_finished_) { error = "snapshot set is not held"; return false; }
        const auto member = snapshots_.find(expected.snapshot_id);
        if (member == snapshots_.end()) { error = "snapshot membership missing"; return false; }
        VSS_SNAPSHOT_PROP property{};
        const HRESULT hr = components_->GetSnapshotProperties(member->second, &property);
        if (FAILED(hr)) { error = failure("GetSnapshotProperties", hr); return false; }
        struct Properties { VSS_SNAPSHOT_PROP& p; ~Properties() { VssFreeSnapshotProperties(&p); } } owned{property};
        if (!IsEqualGUID(property.m_SnapshotId, member->second) ||
            !IsEqualGUID(property.m_SnapshotSetId, set_) ||
            property.m_lSnapshotsCount != static_cast<LONG>(snapshots_.size()) ||
            property.m_eStatus != VSS_SS_CREATED ||
            volume_text(property.m_pwszOriginalVolumeName) != expected.volume_guid ||
            !property.m_pwszSnapshotDeviceObject || property.m_pwszSnapshotDeviceObject[0] == L'\0') {
            error = "snapshot device properties mismatch"; return false;
        }
        device = utf8(property.m_pwszSnapshotDeviceObject);
        if (device.empty()) { error = "snapshot device conversion failed"; return false; }
        return true;
    }
    CleanupResult cleanup(bool finished, std::size_t expected) noexcept override {
        CleanupResult result;
        try {
            bool cancellation_complete = true;
            if (async_ && !terminal_) {
                const HRESULT hr = async_->Cancel();
                cancellation_complete = SUCCEEDED(hr);
                bool observed_terminal = false;
                for (unsigned i = 0; i < 100; ++i) {
                    std::string ignored;
                    const auto state = query_status(ignored);
                    if (terminal_) { observed_terminal = true; break; }
                    if (state == AsyncState::failed) break;
                }
                cancellation_complete = cancellation_complete && observed_terminal;
            }
            // Never race DeleteSnapshots against an operation whose terminal
            // state could not be observed. Release/auto-release is only a
            // backstop; the returned cleanup result must remain uncertain.
            if (async_ && !terminal_) {
                result.error = "async terminal state unconfirmed; deletion not attempted";
                return result;
            }
            LONG deleted = 0;
            GUID undeleted = GUID_NULL;
            HRESULT hr = S_OK;
            if (started_)
                hr = components_->DeleteSnapshots(set_, VSS_OBJECT_SNAPSHOT_SET, TRUE, &deleted, &undeleted);
            result.deleted = deleted < 0 ? 0 : static_cast<std::size_t>(deleted);
            // Before DoSnapshotSet has succeeded, there may be no materialized
            // shadow to delete. Auto-release remains an additional backstop.
            const bool deleted_ok = SUCCEEDED(hr) || (!finished && hr == VSS_E_OBJECT_NOT_FOUND);
            const bool count_ok = !finished || result.deleted == expected;
            result.complete = cancellation_complete && deleted_ok && count_ok;
            if (!cancellation_complete) result.error = "async cancellation outcome unconfirmed";
            else if (!deleted_ok) result.error = failure("DeleteSnapshots", hr);
            else if (!count_ok) result.error = "partial snapshot set deletion";
            if (result.complete) started_ = false;
        } catch (...) {
            result.complete = false;
            // Avoid allocating in this noexcept catch path.
        }
        return result;
    }
};
}
std::unique_ptr<VolumeResolver> make_native_resolver() { return std::make_unique<NativeResolver>(); }
std::unique_ptr<Backend> make_native_backend() { return std::make_unique<NativeBackend>(); }
}
#endif
