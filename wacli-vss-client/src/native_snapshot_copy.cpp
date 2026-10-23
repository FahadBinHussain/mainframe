#include "vss_client.h"

#ifdef _WIN32
#include <aclapi.h>
#include <algorithm>
#include <cwctype>
#include <memory>
#include <sddl.h>
#include <string>
#include <utility>
#include <vector>
#include <windows.h>

namespace wacli::vss {
namespace {
struct Handle {
    HANDLE h = INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE v = INVALID_HANDLE_VALUE) : h(v) {}
    ~Handle() {
        if (h != INVALID_HANDLE_VALUE)
            CloseHandle(h);
    }
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
};
struct Finder {
    HANDLE h = INVALID_HANDLE_VALUE;
    explicit Finder(HANDLE v) : h(v) {}
    ~Finder() {
        if (h != INVALID_HANDLE_VALUE)
            FindClose(h);
    }
};
struct Entry {
    std::wstring relative;
    bool directory = false;
    unsigned long long size = 0;
};
struct Root {
    std::wstring shadow, destination;
    std::vector<Entry> entries;
};

std::wstring join(const std::wstring &parent, const std::wstring &child) {
    return parent + (parent.back() == L'\\' ? L"" : L"\\") + child;
}

std::wstring to_wide(const std::string &v) {
    if (v.empty() || v.size() > 32760 || v.find('\0') != std::string::npos)
        return {};
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, v.data(), (int)v.size(), nullptr, 0);
    if (n <= 0)
        return {};
    std::wstring r((size_t)n, L'\0');
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, v.data(), (int)v.size(), r.data(),
                               n) == n
               ? r
               : std::wstring{};
}
std::string to_utf8(const std::wstring &v) {
    if (v.empty())
        return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, v.data(), (int)v.size(), nullptr, 0,
                                nullptr, nullptr);
    if (n <= 0)
        return {};
    std::string r((size_t)n, '\0');
    return WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, v.data(), (int)v.size(), r.data(), n,
                               nullptr, nullptr) == n
               ? r
               : std::string{};
}
bool component_ok(const std::wstring &n) {
    if (n.empty() || n == L"." || n == L".." || n.back() == L'.' || n.back() == L' ')
        return false;
    for (wchar_t c : n)
        if (c < 32 || c == L':' || c == L'/' || c == L'\\' || c == L'<' || c == L'>' || c == L'"' ||
            c == L'|' || c == L'?' || c == L'*')
            return false;
    std::wstring s = n.substr(0, n.find(L'.'));
    for (auto &c : s)
        c = (wchar_t)std::towupper(c);
    if (s == L"CON" || s == L"PRN" || s == L"AUX" || s == L"NUL" || s == L"CONIN$" ||
        s == L"CONOUT$")
        return false;
    if (s.size() == 4 && (s.substr(0, 3) == L"COM" || s.substr(0, 3) == L"LPT") &&
        ((s[3] >= L'0' && s[3] <= L'9') || s[3] == L'\u00b9' || s[3] == L'\u00b2' ||
         s[3] == L'\u00b3'))
        return false;
    return true;
}

bool inspect(const std::wstring &p, bool dir, unsigned long long &size, std::string &e,
             DWORD share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE) {
    Handle h(CreateFileW(p.c_str(), FILE_READ_ATTRIBUTES, share, nullptr, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (h.h == INVALID_HANDLE_VALUE) {
        e = "entry inaccessible";
        return false;
    }
    BY_HANDLE_FILE_INFORMATION i{};
    if (!GetFileInformationByHandle(h.h, &i)) {
        e = "entry metadata unavailable";
        return false;
    }
    if (((i.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != dir ||
        (i.dwFileAttributes &
         (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_ENCRYPTED | FILE_ATTRIBUTE_SPARSE_FILE |
          FILE_ATTRIBUTE_COMPRESSED | FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_TEMPORARY |
          FILE_ATTRIBUTE_DEVICE | FILE_ATTRIBUTE_VIRTUAL)) != 0 ||
        (!dir && i.nNumberOfLinks != 1)) {
        e = "entry unsupported";
        return false;
    }
    size = dir ? 0 : ((unsigned long long)i.nFileSizeHigh << 32 | i.nFileSizeLow);
    WIN32_FIND_STREAM_DATA sd{};
    Finder f(FindFirstStreamW(p.c_str(), FindStreamInfoStandard, &sd, 0));
    if (f.h == INVALID_HANDLE_VALUE) {
        if (GetLastError() != ERROR_HANDLE_EOF) {
            e = "stream enumeration failed";
            return false;
        }
    } else {
        do {
            if (std::wstring(sd.cStreamName) != L"::$DATA" ||
                (dir && sd.StreamSize.QuadPart != 0)) {
                e = "alternate stream unsupported";
                return false;
            }
        } while (FindNextStreamW(f.h, &sd));
        if (GetLastError() != ERROR_HANDLE_EOF) {
            e = "stream enumeration incomplete";
            return false;
        }
    }
    return true;
}

bool inventory(const std::wstring &root, std::vector<Entry> &out, std::string &e) {
    unsigned long long z = 0;
    if (!inspect(root, true, z, e))
        return false;
    std::vector<std::wstring> q{L""};
    size_t count = 0;
    while (!q.empty()) {
        std::wstring rel = std::move(q.back());
        q.pop_back();
        std::wstring cur = rel.empty() ? root : join(root, rel);
        WIN32_FIND_DATAW d{};
        Finder f(FindFirstFileW(join(cur, L"*").c_str(), &d));
        if (f.h == INVALID_HANDLE_VALUE) {
            if (GetLastError() == ERROR_FILE_NOT_FOUND)
                continue;
            e = "directory enumeration failed";
            return false;
        }
        do {
            std::wstring n(d.cFileName);
            if (n == L"." || n == L"..")
                continue;
            if (++count > 200000 || !component_ok(n)) {
                e = "inventory unsupported";
                return false;
            }
            std::wstring child = rel.empty() ? n : rel + L"\\" + n;
            if (root.size() + child.size() + 1 > 32760 ||
                std::count(child.begin(), child.end(), L'\\') > 128) {
                e = "inventory path exceeds development limits";
                return false;
            }
            bool dir = (d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            unsigned long long size = 0;
            if (!inspect(join(cur, n), dir, size, e))
                return false;
            out.push_back({child, dir, size});
            if (dir)
                q.push_back(child);
        } while (FindNextFileW(f.h, &d));
        if (GetLastError() != ERROR_NO_MORE_FILES) {
            e = "directory enumeration incomplete";
            return false;
        }
    }
    std::sort(out.begin(), out.end(), [](const Entry &a, const Entry &b) {
        return a.relative == b.relative ? a.directory < b.directory : a.relative < b.relative;
    });
    return true;
}
bool same(const std::vector<Entry> &a, const std::vector<Entry> &b) {
    if (a.size() != b.size())
        return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (a[i].relative != b[i].relative || a[i].directory != b[i].directory ||
            a[i].size != b[i].size)
            return false;
    return true;
}

bool copy_bytes(const std::wstring &s, const std::wstring &d, unsigned long long expected,
                std::string &e) {
    Handle in(CreateFileW(s.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                          FILE_FLAG_SEQUENTIAL_SCAN | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (in.h == INVALID_HANDLE_VALUE) {
        e = "source file open failed";
        return false;
    }
    Handle out(CreateFileW(d.c_str(), GENERIC_WRITE | FILE_WRITE_ATTRIBUTES, 0, nullptr, CREATE_NEW,
                           FILE_ATTRIBUTE_NORMAL, nullptr));
    if (out.h == INVALID_HANDLE_VALUE) {
        e = "output file create failed";
        return false;
    }
    std::vector<unsigned char> buf(64 * 1024);
    unsigned long long total = 0;
    for (;;) {
        DWORD n = 0;
        if (!ReadFile(in.h, buf.data(), (DWORD)buf.size(), &n, nullptr)) {
            e = "source file read failed";
            return false;
        }
        if (!n)
            break;
        DWORD w = 0;
        if (!WriteFile(out.h, buf.data(), n, &w, nullptr) || w != n) {
            e = "output file write failed";
            return false;
        }
        total += n;
        if (total > expected) {
            e = "file size mismatch";
            return false;
        }
    }
    if (total != expected || !FlushFileBuffers(out.h)) {
        e = "output file verification failed";
        return false;
    }
    return true;
}
bool compare_bytes(const std::wstring &a, const std::wstring &b, unsigned long long expected,
                   std::string &e) {
    Handle x(CreateFileW(a.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                         FILE_FLAG_SEQUENTIAL_SCAN | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    Handle y(CreateFileW(b.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                         FILE_FLAG_SEQUENTIAL_SCAN | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (x.h == INVALID_HANDLE_VALUE || y.h == INVALID_HANDLE_VALUE) {
        e = "output reopen failed";
        return false;
    }
    std::vector<unsigned char> p(64 * 1024), q(64 * 1024);
    unsigned long long total = 0;
    for (;;) {
        DWORD np = 0, nq = 0;
        if (!ReadFile(x.h, p.data(), (DWORD)p.size(), &np, nullptr) ||
            !ReadFile(y.h, q.data(), (DWORD)q.size(), &nq, nullptr) || np != nq ||
            !std::equal(p.begin(), p.begin() + np, q.begin())) {
            e = "output bytes mismatch";
            return false;
        }
        if (!np)
            break;
        total += np;
    }
    if (total != expected) {
        e = "output size mismatch";
        return false;
    }
    return true;
}

bool pin(const std::wstring &p, std::vector<std::unique_ptr<Handle>> &pins, std::string &e) {
    auto h = std::make_unique<Handle>(CreateFileW(
        p.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (h->h == INVALID_HANDLE_VALUE) {
        e = "directory pin failed";
        return false;
    }
    // Validate the pinned object itself, not only an earlier path observation.
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(h->h, &info) ||
        !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        e = "pinned directory unsupported";
        return false;
    }
    pins.push_back(std::move(h));
    return true;
}
bool pin_output_file(const std::wstring &path, std::vector<std::unique_ptr<Handle>> &pins,
                     std::string &error) {
    auto handle =
        std::make_unique<Handle>(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                             OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    BY_HANDLE_FILE_INFORMATION info{};
    if (handle->h == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(handle->h, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
        error = "staged file pin failed";
        return false;
    }
    pins.push_back(std::move(handle));
    return true;
}
bool remove_tree(const std::wstring &r) {
    WIN32_FIND_DATAW d{};
    Finder f(FindFirstFileW(join(r, L"*").c_str(), &d));
    if (f.h != INVALID_HANDLE_VALUE) {
        do {
            std::wstring n(d.cFileName);
            if (n == L"." || n == L"..")
                continue;
            std::wstring p = join(r, n);
            if (d.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
                if ((d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? !RemoveDirectoryW(p.c_str())
                                                                    : !DeleteFileW(p.c_str()))
                    return false;
            } else if (d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (!remove_tree(p))
                    return false;
            } else if (!DeleteFileW(p.c_str()))
                return false;
        } while (FindNextFileW(f.h, &d));
        if (GetLastError() != ERROR_NO_MORE_FILES)
            return false;
    } else if (GetLastError() != ERROR_FILE_NOT_FOUND) {
        return false;
    }
    return RemoveDirectoryW(r.c_str()) != FALSE;
}

class NativeSnapshotCopy final : public SnapshotCopy {
    std::wstring parent_, staging_;
    std::vector<Root> roots_;
    std::vector<std::unique_ptr<Handle>> parent_pins_;
    std::vector<std::unique_ptr<Handle>> pins_;
    std::vector<std::unique_ptr<Handle>> source_pins_;
    bool complete_ = false;
    bool used_ = false;
    bool valid_parent(std::string &e) {
        if (parent_.size() < 3 || parent_.size() > 160 || parent_[0] < L'A' || parent_[0] > L'Z' ||
            parent_[1] != L':' || parent_[2] != L'\\' ||
            (parent_.size() > 3 && parent_.back() == L'\\')) {
            e = "private parent is not canonical";
            return false;
        }
        if (GetDriveTypeW(parent_.substr(0, 3).c_str()) != DRIVE_FIXED) {
            e = "private parent is not on a local fixed drive";
            return false;
        }
        DWORD filesystem_flags = 0;
        if (!GetVolumeInformationW(parent_.substr(0, 3).c_str(), nullptr, 0, nullptr, nullptr,
                                   &filesystem_flags, nullptr, 0) ||
            !(filesystem_flags & FILE_PERSISTENT_ACLS)) {
            e = "private staging requires persistent ACL support";
            return false;
        }
        for (size_t b = 3; b < parent_.size();) {
            size_t x = parent_.find(L'\\', b);
            if (x == std::wstring::npos)
                x = parent_.size();
            if (!component_ok(parent_.substr(b, x - b))) {
                e = "private parent is not canonical";
                return false;
            }
            b = x + 1;
        }
        wchar_t longp[32768]{};
        DWORD n = GetLongPathNameW(parent_.c_str(), longp, 32768);
        if (!n || n >= 32768 || parent_ != longp) {
            e = "private parent is not canonical";
            return false;
        }
        unsigned long long ignored = 0;
        if (!pin(parent_.substr(0, 3), parent_pins_, e) ||
            !inspect(parent_.substr(0, 3), true, ignored, e))
            return false;
        for (size_t x = 3; x < parent_.size();) {
            size_t y = parent_.find(L'\\', x);
            if (y == std::wstring::npos)
                y = parent_.size();
            unsigned long long z = 0;
            if (!pin(parent_.substr(0, y), parent_pins_, e))
                return false;
            if (!inspect(parent_.substr(0, y), true, z, e, FILE_SHARE_READ | FILE_SHARE_WRITE))
                return false;
            if (y == parent_.size())
                break;
            x = y + 1;
        }
        return true;
    }
    bool create_dir(const std::wstring &p, std::string &e) {
        if (!CreateDirectoryW(p.c_str(), nullptr)) {
            e = "output directory create failed";
            return false;
        }
        return pin(p, pins_, e);
    }
    bool create_private(std::string &e) {
        HANDLE tok = nullptr;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) {
            e = "staging identity unavailable";
            return false;
        }
        Handle th(tok);
        DWORD n = 0;
        GetTokenInformation(th.h, TokenUser, nullptr, 0, &n);
        if (n < sizeof(TOKEN_USER) || n > 65536) {
            e = "staging identity size invalid";
            return false;
        }
        std::vector<unsigned char> b(n);
        if (!GetTokenInformation(th.h, TokenUser, b.data(), n, &n)) {
            e = "staging identity unavailable";
            return false;
        }
        PSID sid = ((TOKEN_USER *)b.data())->User.Sid;
        LPWSTR ss = nullptr;
        if (!ConvertSidToStringSidW(sid, &ss)) {
            e = "staging identity unavailable";
            return false;
        }
        struct LocalString {
            LPWSTR p;
            ~LocalString() { LocalFree(p); }
        } owned_sid{ss};
        std::wstring sids(ss);
        std::wstring sddl = L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + sids + L")";
        PSECURITY_DESCRIPTOR sd = nullptr;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1,
                                                                  &sd, nullptr)) {
            e = "staging ACL setup failed";
            return false;
        }
        struct Free {
            PSECURITY_DESCRIPTOR p;
            ~Free() { LocalFree(p); }
        } free{sd};
        SECURITY_ATTRIBUTES sa{sizeof(sa), sd, FALSE};
        for (unsigned i = 0; i < 8; ++i) {
            GUID id{};
            if (FAILED(CoCreateGuid(&id))) {
                e = "staging identity generation failed";
                return false;
            }
            wchar_t t[40]{};
            if (!StringFromGUID2(id, t, 40)) {
                e = "staging identity conversion failed";
                return false;
            }
            std::wstring p = join(parent_, L"vss-stage-" + std::wstring(t + 1));
            if (CreateDirectoryW(p.c_str(), &sa)) {
                staging_.swap(p); // No allocation after creating the owned directory.
                return pin(staging_, pins_, e);
            }
            if (GetLastError() != ERROR_ALREADY_EXISTS) {
                e = "staging directory create failed";
                return false;
            }
        }
        e = "staging identity collision";
        return false;
    }
    bool fail() {
        discard_();
        return false;
    }
    void discard_() noexcept {
        std::string ignored;
        discard(ignored);
    }

  public:
    explicit NativeSnapshotCopy(const std::string &p) : parent_(to_wide(p)) {}
    ~NativeSnapshotCopy() override { discard_(); }
    std::string staging_directory() const override { return to_utf8(staging_); }
    bool stage(const std::vector<ResolvedRoot> &maps, const std::vector<SnapshotInfo> &snaps,
               Backend &backend, std::string &e) override {
        if (used_ || complete_ || !staging_.empty() || parent_.empty() || maps.empty() ||
            snaps.empty()) {
            e = "snapshot copy state invalid";
            return false;
        }
        used_ = true;
        try {
            // Reject every overlap before creating even an empty staging tree.
            // Trim the source's trailing root separator so C:\\ also covers C:\\private.
            auto fold = [](std::wstring v) {
                for (auto &c : v)
                    c = static_cast<wchar_t>(std::towupper(c));
                return v;
            };
            const auto fp = fold(parent_);
            for (const auto &mapping : maps) {
                const auto source = to_wide(mapping.source_root);
                if (source.size() < 3 || source.size() > 240 || source[0] < L'A' ||
                    source[0] > L'Z' || source[1] != L':' || source[2] != L'\\' ||
                    (source.size() > 3 && source.back() == L'\\')) {
                    e = "source root invalid";
                    return false;
                }
                for (size_t b = 3; b < source.size();) {
                    auto end = source.find(L'\\', b);
                    if (end == std::wstring::npos)
                        end = source.size();
                    if (!component_ok(source.substr(b, end - b))) {
                        e = "source root invalid";
                        return false;
                    }
                    b = end + 1;
                }
                auto fs = fold(source);
                if (fs.back() == L'\\')
                    fs.pop_back();
                if (fp == fs || (fp.size() > fs.size() && fp.compare(0, fs.size(), fs) == 0 &&
                                 fp[fs.size()] == L'\\')) {
                    e = "private parent overlaps source";
                    return false;
                }
            }
            if (!valid_parent(e) || !create_private(e))
                return fail();
            roots_.reserve(maps.size());
            for (const auto &m : maps) {
                if (m.source_root.size() < 3 || m.source_root[1] != ':' ||
                    m.source_root[2] != '\\') {
                    e = "source root invalid";
                    return fail();
                }
                auto it = std::find_if(snaps.begin(), snaps.end(), [&](const SnapshotInfo &s) {
                    return s.volume_guid == m.volume_guid;
                });
                if (it == snaps.end()) {
                    e = "snapshot membership missing";
                    return fail();
                }
                std::string dev;
                if (!backend.snapshot_device(*it, dev, e))
                    return fail();
                std::wstring sh = to_wide(dev), suffix = to_wide(m.source_root.substr(3));
                if (sh.empty() ||
                    sh.rfind(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy", 0) != 0 ||
                    (suffix.empty() && m.source_root.size() != 3)) {
                    e = "snapshot device or root invalid";
                    return fail();
                }
                std::wstring source = to_wide(m.source_root);
                if (source.empty()) {
                    e = "source root invalid";
                    return fail();
                }
                std::wstring prefix = L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy";
                size_t dn = prefix.size();
                if (sh.size() <= dn || sh.compare(0, dn, prefix) != 0 ||
                    sh.find_first_not_of(L"0123456789", dn) != std::wstring::npos) {
                    e = "snapshot device or root invalid";
                    return fail();
                }
                if (source.empty() || source.size() < 3) {
                    e = "source root invalid";
                    return fail();
                }
                std::wstring shadow_root = sh + L"\\";
                unsigned long long volume_size = 0;
                if (!pin(shadow_root, source_pins_, e) ||
                    !inspect(shadow_root, true, volume_size, e))
                    return fail();
                for (size_t b = 3; b < source.size();) {
                    size_t x = source.find(L'\\', b);
                    if (x == std::wstring::npos)
                        x = source.size();
                    if (!component_ok(source.substr(b, x - b))) {
                        e = "source root invalid";
                        return fail();
                    }
                    shadow_root = join(shadow_root, source.substr(b, x - b));
                    unsigned long long az = 0;
                    if (!pin(shadow_root, source_pins_, e) ||
                        !inspect(shadow_root, true, az, e, FILE_SHARE_READ | FILE_SHARE_WRITE))
                        return fail();
                    b = x + 1;
                }
                Root r{shadow_root, staging_ + L"\\root" + std::to_wstring(roots_.size()), {}};
                unsigned long long z = 0;
                if (!inspect(r.shadow, true, z, e, FILE_SHARE_READ | FILE_SHARE_WRITE))
                    return fail();
                if (!inventory(r.shadow, r.entries, e))
                    return fail();
                for (const auto &entry : r.entries) {
                    if (r.destination.size() + entry.relative.size() + 1 > 240) {
                        e = "staging path exceeds development limit";
                        return fail();
                    }
                }
                roots_.push_back(std::move(r));
            }
            for (auto &r : roots_) {
                if (!create_dir(r.destination, e))
                    return fail();
                for (auto &x : r.entries) {
                    std::wstring d = r.destination + L"\\" + x.relative;
                    if (x.directory) {
                        if (!create_dir(d, e))
                            return fail();
                    } else if (!copy_bytes(join(r.shadow, x.relative), d, x.size, e) ||
                               !pin_output_file(d, pins_, e))
                        return fail();
                }
            }
            if (!verify(e))
                return fail();
            complete_ = true;
            return true;
        } catch (...) {
            e = "snapshot copy failed";
            return fail();
        }
    }
    bool verify(std::string &e) override {
        if (staging_.empty() || roots_.empty()) {
            e = "snapshot copy not staged";
            return false;
        }
        unsigned long long ignored = 0;
        if (!inspect(staging_, true, ignored, e))
            return false;
        WIN32_FIND_DATAW td{};
        Finder tf(FindFirstFileW((staging_ + L"\\*").c_str(), &td));
        std::vector<std::wstring> top;
        if (tf.h == INVALID_HANDLE_VALUE) {
            e = "staging inventory failed";
            return false;
        }
        do {
            std::wstring n(td.cFileName);
            if (n == L"." || n == L"..")
                continue;
            if ((td.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                (td.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                e = "staging top-level inventory mismatch";
                return false;
            }
            top.push_back(n);
        } while (FindNextFileW(tf.h, &td));
        if (GetLastError() != ERROR_NO_MORE_FILES || top.size() != roots_.size()) {
            e = "staging top-level inventory mismatch";
            return false;
        }
        std::sort(top.begin(), top.end());
        std::vector<std::wstring> expected;
        for (size_t i = 0; i < roots_.size(); ++i)
            expected.push_back(L"root" + std::to_wstring(i));
        std::sort(expected.begin(), expected.end());
        if (top != expected) {
            e = "staging top-level inventory mismatch";
            return false;
        }
        for (auto &r : roots_) {
            std::vector<Entry> src, dst;
            if (!inventory(r.shadow, src, e) || !same(r.entries, src) ||
                !inventory(r.destination, dst, e) || !same(r.entries, dst)) {
                e = "staged inventory mismatch";
                return false;
            }
            for (auto &x : r.entries)
                if (!x.directory && !compare_bytes(join(r.shadow, x.relative),
                                                   r.destination + L"\\" + x.relative, x.size, e))
                    return false;
        }
        // The VSS requester still owns the set. Only close source handles here;
        // retaining no-delete-share handles could obstruct DeleteSnapshots.
        // The shadow namespace is immutable, and subsequent verify calls reopen
        // only the same validated shadow paths, never their live drive aliases.
        source_pins_.clear();
        return true;
    }
    bool discard(std::string &e) noexcept override {
        try {
            // No-delete-share pins protect the copy/verification phase, but must
            // be closed before removal. Ancestors of the private staging tree
            // stay pinned; the protected ACL excludes other users. This is not
            // a security boundary against another process of the same owner.
            pins_.clear();
            source_pins_.clear();
            if (!staging_.empty() && !remove_tree(staging_)) {
                e = "staging cleanup failed";
                return false;
            }
            staging_.clear();
            roots_.clear();
            parent_pins_.clear();
            complete_ = false;
            return true;
        } catch (...) {
            // Never allocate an error string or terminate from a destructor.
            return false;
        }
    }
};
} // namespace
std::unique_ptr<SnapshotCopy> make_native_snapshot_copy(const std::string &p) {
    return std::make_unique<NativeSnapshotCopy>(p);
}
} // namespace wacli::vss
#endif
