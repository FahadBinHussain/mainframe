#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <map>
#include <string>
#include <vector>

#define WINAPI
#define CALLBACK
#define TRUE 1
#define FALSE 0
using BOOL = int;
using BYTE = unsigned char;
using WORD = unsigned short;
using DWORD = unsigned long;
using LONG = long;
using WCHAR = wchar_t;
using LPCWSTR = const wchar_t *;
using LPWSTR = wchar_t *;
using LPVOID = void *;
using HANDLE = void *;
using PSECURITY_DESCRIPTOR = void *;
using REGSAM = unsigned long;
using HRESULT = long;
using UINT = unsigned int;
using DWORD_PTR = uintptr_t;
using PSID = void *;
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#define CP_UTF8 65001
#define MB_ERR_INVALID_CHARS 8
#define WC_ERR_INVALID_CHARS 0x80
#define FILE_READ_ATTRIBUTES 0x80
#define GENERIC_READ 0x80000000UL
#define GENERIC_WRITE 0x40000000UL
#define FILE_WRITE_ATTRIBUTES 0x100
#define FILE_SHARE_READ 1
#define FILE_SHARE_WRITE 2
#define FILE_SHARE_DELETE 4
#define OPEN_EXISTING 3
#define CREATE_NEW 1
#define FILE_FLAG_BACKUP_SEMANTICS 0x02000000
#define FILE_FLAG_OPEN_REPARSE_POINT 0x00200000
#define FILE_FLAG_SEQUENTIAL_SCAN 0x08000000
#define FILE_ATTRIBUTE_NORMAL 0x80
#define FILE_ATTRIBUTE_DIRECTORY 0x10
#define FILE_ATTRIBUTE_REPARSE_POINT 0x400
#define FILE_ATTRIBUTE_ENCRYPTED 0x4000
#define FILE_ATTRIBUTE_SPARSE_FILE 0x200
#define FILE_ATTRIBUTE_COMPRESSED 0x800
#define FILE_ATTRIBUTE_OFFLINE 0x1000
#define FILE_ATTRIBUTE_TEMPORARY 0x100
#define FILE_ATTRIBUTE_DEVICE 0x40
#define FILE_ATTRIBUTE_VIRTUAL 0x10000
#define ERROR_SUCCESS 0
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_PATH_NOT_FOUND 3
#define ERROR_ACCESS_DENIED 5
#define ERROR_ALREADY_EXISTS 183
#define ERROR_NO_MORE_FILES 18
#define ERROR_HANDLE_EOF 38
#define DACL_SECURITY_INFORMATION 4
#define SDDL_REVISION_1 1
#define TOKEN_QUERY 8
#define TokenUser 1
#define DRIVE_FIXED 3
#define DRIVE_UNKNOWN 0
#define FILE_PERSISTENT_ACLS 0x00000008
#define FAILED(x) ((x) < 0)

struct GUID {
  unsigned long Data1;
  unsigned short Data2, Data3;
  unsigned char Data4[8];
};
struct SECURITY_ATTRIBUTES {
  DWORD nLength;
  PSECURITY_DESCRIPTOR lpSecurityDescriptor;
  BOOL bInheritHandle;
};
struct SID_AND_ATTRIBUTES {
  PSID Sid;
  DWORD Attributes;
};
struct TOKEN_USER {
  SID_AND_ATTRIBUTES User;
};
struct BY_HANDLE_FILE_INFORMATION {
  DWORD dwFileAttributes{}, nFileSizeHigh{}, nFileSizeLow{};
  DWORD nNumberOfLinks = 1;
};
struct WIN32_FIND_DATAW {
  DWORD dwFileAttributes{};
  WCHAR cFileName[260]{};
};
struct WIN32_FIND_STREAM_DATA {
  struct {
    long long QuadPart = 0;
  } StreamSize;
  WCHAR cStreamName[296]{};
};
enum STREAM_INFO_LEVELS { FindStreamInfoStandard = 0 };

namespace fake_win32 {
struct Node {
  bool dir = false;
  bool reparse = false;
  std::string bytes;
  std::vector<std::wstring> streams;
  bool had_security_attributes = false;
  std::wstring security_descriptor;
};
struct H {
  enum Kind { file, find, stream };
  Kind kind = file;
  std::wstring path;
  size_t pos = 0;
  std::vector<std::wstring> names;
  DWORD access = 0;
  DWORD share = 0;
  bool fail_flush = false;
};
inline std::map<std::wstring, Node> fs;
inline std::vector<H *> live_handles;
inline DWORD err = 0;
inline bool fail_read = false;
inline bool fail_write = false;
inline bool short_write = false;
inline bool fail_flush = false;
inline bool fail_remove = false;
inline bool fail_enum = false;
inline int fail_enum_after = -1;
inline unsigned enum_calls = 0;
inline bool fail_drive_type = false;
inline bool fail_volume_info = false;
inline unsigned source_read_count = 0;
inline std::vector<std::wstring> read_paths;
inline unsigned guid = 1;
inline void reset() {
  for (auto *h : live_handles)
    delete h;
  live_handles.clear();
  fs.clear();
  err = 0;
  fail_read = fail_write = short_write = fail_flush = fail_remove = fail_enum =
      false;
  fail_enum_after = -1;
  enum_calls = 0;
  fail_drive_type = false;
  fail_volume_info = false;
  source_read_count = 0;
  read_paths.clear();
  guid = 1;
}
inline std::wstring norm(std::wstring p) {
  while (p.size() > 1 && p.back() == L'\\')
    p.pop_back();
  return p;
}
inline void dir(const std::wstring &p) {
  fs[norm(p)] = {true, false, {}, {}, false, {}};
}
inline void file(const std::wstring &p, const std::string &b) {
  fs[norm(p)] = {false, false, b, {}, false, {}};
}
inline void reparse(const std::wstring &p, bool d) {
  fs[norm(p)] = {d, true, {}, {}, false, {}};
}
inline std::wstring parent(const std::wstring &p) {
  auto x = p.find_last_of(L'\\');
  return x == std::wstring::npos ? L"" : p.substr(0, x);
}
inline void seterr(DWORD e) { err = e; }
inline bool enumeration_fails() {
  ++enum_calls;
  return fail_enum ||
         (fail_enum_after >= 0 && enum_calls > (unsigned)fail_enum_after);
}
inline bool sharing_allows(const H &old, DWORD access, DWORD share) {
  const bool read = (access & GENERIC_READ) != 0;
  const bool write = (access & (GENERIC_WRITE | FILE_WRITE_ATTRIBUTES)) != 0;
  return (!read || (old.share & FILE_SHARE_READ)) &&
         (!write || (old.share & FILE_SHARE_WRITE)) &&
         (!(old.access & GENERIC_READ) || (share & FILE_SHARE_READ)) &&
         (!(old.access & (GENERIC_WRITE | FILE_WRITE_ATTRIBUTES)) ||
          (share & FILE_SHARE_WRITE));
}
inline bool path_has_live_no_delete_handle(const std::wstring &p) {
  auto x = norm(p);
  for (auto *h : live_handles)
    if (h->kind == H::file && h->path == x && !(h->share & FILE_SHARE_DELETE))
      return true;
  return false;
}
} // namespace fake_win32

inline DWORD GetLastError() { return fake_win32::err; }
inline void SetLastError(DWORD e) { fake_win32::err = e; }
inline int MultiByteToWideChar(UINT, DWORD, const char *s, int n, wchar_t *out,
                               int cap) {
  if (!s || n <= 0)
    return 0;
  std::wstring w;
  for (int i = 0; i < n; i++) {
    unsigned char c = s[i];
    if (c >= 128)
      return 0;
    w.push_back((wchar_t)c);
  }
  if (!out)
    return (int)w.size();
  if (cap < (int)w.size())
    return 0;
  std::copy(w.begin(), w.end(), out);
  return (int)w.size();
}
inline int WideCharToMultiByte(UINT, DWORD, const wchar_t *s, int n, char *out,
                               int cap, const char *, BOOL *) {
  if (!s || n <= 0)
    return 0;
  for (int i = 0; i < n; i++)
    if (s[i] > 127)
      return 0;
  if (!out)
    return n;
  if (cap < n)
    return 0;
  for (int i = 0; i < n; i++)
    out[i] = (char)s[i];
  return n;
}
inline HANDLE CreateFileW(LPCWSTR p, DWORD access, DWORD share, DWORD *,
                          DWORD creation, DWORD, void *) {
  std::wstring x = fake_win32::norm(p);
  auto it = fake_win32::fs.find(x);
  if (creation == CREATE_NEW) {
    if (it != fake_win32::fs.end()) {
      fake_win32::seterr(ERROR_ALREADY_EXISTS);
      return INVALID_HANDLE_VALUE;
    }
    fake_win32::file(x, "");
    it = fake_win32::fs.find(x);
  }
  if (it == fake_win32::fs.end() ||
      ((access & GENERIC_READ) && it->second.dir)) {
    fake_win32::seterr(ERROR_FILE_NOT_FOUND);
    return INVALID_HANDLE_VALUE;
  }
  for (auto *old : fake_win32::live_handles) {
    if (old->kind == fake_win32::H::file && old->path == x &&
        !fake_win32::sharing_allows(*old, access, share)) {
      fake_win32::seterr(ERROR_ACCESS_DENIED);
      return INVALID_HANDLE_VALUE;
    }
  }
  auto *h = new fake_win32::H;
  h->kind = fake_win32::H::file;
  h->path = x;
  h->access = access;
  h->share = share;
  h->fail_flush = fake_win32::fail_flush;
  fake_win32::live_handles.push_back(h);
  return h;
}
inline BOOL CloseHandle(HANDLE q) {
  auto *h = static_cast<fake_win32::H *>(q);
  auto it = std::find(fake_win32::live_handles.begin(),
                      fake_win32::live_handles.end(), h);
  if (it != fake_win32::live_handles.end())
    fake_win32::live_handles.erase(it);
  delete h;
  return TRUE;
}
inline BOOL GetFileInformationByHandle(HANDLE q,
                                       BY_HANDLE_FILE_INFORMATION *i) {
  auto *h = static_cast<fake_win32::H *>(q);
  auto it = fake_win32::fs.find(h->path);
  if (it == fake_win32::fs.end())
    return FALSE;
  i->dwFileAttributes = (it->second.dir ? FILE_ATTRIBUTE_DIRECTORY : 0) |
                        (it->second.reparse ? FILE_ATTRIBUTE_REPARSE_POINT : 0);
  uint64_t n = it->second.bytes.size();
  i->nFileSizeLow = (DWORD)n;
  i->nFileSizeHigh = (DWORD)(n >> 32);
  i->nNumberOfLinks = 1;
  return TRUE;
}
inline BOOL ReadFile(HANDLE q, void *b, DWORD n, DWORD *got, void *) {
  auto *h = static_cast<fake_win32::H *>(q);
  auto &node = fake_win32::fs[h->path];
  fake_win32::read_paths.push_back(h->path);
  if (h->path.find(L"ShadowCopy") != std::wstring::npos)
    ++fake_win32::source_read_count;
  if (fake_win32::fail_read) {
    *got = 0;
    return FALSE;
  }
  size_t k = std::min<size_t>(n, node.bytes.size() -
                                     std::min(h->pos, node.bytes.size()));
  memcpy(b, node.bytes.data() + h->pos, k);
  h->pos += k;
  *got = (DWORD)k;
  return TRUE;
}
inline BOOL WriteFile(HANDLE q, const void *b, DWORD n, DWORD *got, void *) {
  auto *h = static_cast<fake_win32::H *>(q);
  if (fake_win32::fail_write) {
    *got = 0;
    return FALSE;
  }
  DWORD k = fake_win32::short_write && n ? n - 1 : n;
  auto &v = fake_win32::fs[h->path].bytes;
  v.append((const char *)b, k);
  *got = k;
  return TRUE;
}
inline BOOL FlushFileBuffers(HANDLE) {
  return fake_win32::fail_flush ? FALSE : TRUE;
}
inline BOOL CreateDirectoryW(LPCWSTR p, void *security) {
  auto x = fake_win32::norm(p);
  if (fake_win32::fs.count(x)) {
    fake_win32::seterr(ERROR_ALREADY_EXISTS);
    return FALSE;
  }
  if (!fake_win32::fs.count(fake_win32::parent(x))) {
    fake_win32::seterr(ERROR_PATH_NOT_FOUND);
    return FALSE;
  }
  fake_win32::dir(x);
  auto &node = fake_win32::fs[x];
  if (security) {
    auto *sa = static_cast<SECURITY_ATTRIBUTES *>(security);
    node.had_security_attributes = sa->lpSecurityDescriptor != nullptr;
    if (node.had_security_attributes)
      node.security_descriptor =
          static_cast<const wchar_t *>(sa->lpSecurityDescriptor);
  }
  return TRUE;
}
inline std::vector<std::wstring> children(const std::wstring &root) {
  std::vector<std::wstring> v;
  auto prefix = fake_win32::norm(root) + L"\\";
  for (auto &[p, n] : fake_win32::fs)
    if (p.rfind(prefix, 0) == 0 &&
        p.find(L'\\', prefix.size()) == std::wstring::npos)
      v.push_back(p.substr(prefix.size()));
  std::sort(v.begin(), v.end());
  return v;
}
inline HANDLE FindFirstFileW(LPCWSTR pat, WIN32_FIND_DATAW *d) {
  auto root = std::wstring(pat);
  if (root.size() >= 2 && root.substr(root.size() - 2) == L"\\*")
    root.resize(root.size() - 2);
  auto names = children(root);
  if (names.empty()) {
    fake_win32::seterr(ERROR_FILE_NOT_FOUND);
    return INVALID_HANDLE_VALUE;
  }
  if (fake_win32::enumeration_fails()) {
    fake_win32::seterr(ERROR_ACCESS_DENIED);
    return INVALID_HANDLE_VALUE;
  }
  auto *h = new fake_win32::H;
  h->kind = fake_win32::H::find;
  h->path = root;
  h->names = names;
  auto &n = fake_win32::fs[root + L"\\" + names[0]];
  d->dwFileAttributes = (n.dir ? FILE_ATTRIBUTE_DIRECTORY : 0) |
                        (n.reparse ? FILE_ATTRIBUTE_REPARSE_POINT : 0);
  wcsncpy(d->cFileName, names[0].c_str(), 259);
  return h;
}
inline BOOL FindNextFileW(HANDLE q, WIN32_FIND_DATAW *d) {
  auto *h = static_cast<fake_win32::H *>(q);
  if (fake_win32::enumeration_fails()) {
    fake_win32::seterr(ERROR_ACCESS_DENIED);
    return FALSE;
  }
  if (++h->pos >= h->names.size()) {
    fake_win32::seterr(ERROR_NO_MORE_FILES);
    return FALSE;
  }
  auto p = h->path + L"\\" + h->names[h->pos];
  auto &n = fake_win32::fs[p];
  d->dwFileAttributes = (n.dir ? FILE_ATTRIBUTE_DIRECTORY : 0) |
                        (n.reparse ? FILE_ATTRIBUTE_REPARSE_POINT : 0);
  wcsncpy(d->cFileName, h->names[h->pos].c_str(), 259);
  return TRUE;
}
inline BOOL FindClose(HANDLE q) {
  delete static_cast<fake_win32::H *>(q);
  return TRUE;
}
inline HANDLE FindFirstStreamW(LPCWSTR p, STREAM_INFO_LEVELS,
                               WIN32_FIND_STREAM_DATA *d, DWORD) {
  auto it = fake_win32::fs.find(fake_win32::norm(p));
  if (it == fake_win32::fs.end()) {
    fake_win32::seterr(ERROR_FILE_NOT_FOUND);
    return INVALID_HANDLE_VALUE;
  }
  if (it->second.streams.empty()) {
    fake_win32::seterr(ERROR_HANDLE_EOF);
    return INVALID_HANDLE_VALUE;
  }
  auto *h = new fake_win32::H;
  h->kind = fake_win32::H::stream;
  h->path = fake_win32::norm(p);
  wcscpy(d->cStreamName, it->second.streams[0].c_str());
  return h;
}
inline BOOL FindNextStreamW(HANDLE q, WIN32_FIND_STREAM_DATA *d) {
  auto *h = static_cast<fake_win32::H *>(q);
  auto &v = fake_win32::fs[h->path].streams;
  if (++h->pos >= v.size()) {
    fake_win32::seterr(ERROR_HANDLE_EOF);
    return FALSE;
  }
  wcscpy(d->cStreamName, v[h->pos].c_str());
  return TRUE;
}
inline BOOL DeleteFileW(LPCWSTR p) {
  if (fake_win32::fail_remove || fake_win32::path_has_live_no_delete_handle(p))
    return FALSE;
  return fake_win32::fs.erase(fake_win32::norm(p)) ? TRUE : FALSE;
}
inline BOOL RemoveDirectoryW(LPCWSTR p) {
  if (fake_win32::fail_remove || fake_win32::path_has_live_no_delete_handle(p))
    return FALSE;
  auto x = fake_win32::norm(p);
  auto it = fake_win32::fs.find(x);
  if (it == fake_win32::fs.end() || !it->second.dir || !children(x).empty())
    return FALSE;
  fake_win32::fs.erase(it);
  return TRUE;
}
inline DWORD GetDriveTypeW(LPCWSTR) {
  return fake_win32::fail_drive_type ? DRIVE_UNKNOWN : DRIVE_FIXED;
}
inline BOOL GetVolumeInformationW(LPCWSTR, LPWSTR, DWORD, DWORD *, DWORD *,
                                  DWORD *flags, LPWSTR, DWORD) {
  if (fake_win32::fail_volume_info)
    return FALSE;
  if (flags)
    *flags = FILE_PERSISTENT_ACLS;
  return TRUE;
}
inline HRESULT CoCreateGuid(GUID *g) {
  g->Data1 = fake_win32::guid++;
  return 0;
}
inline int StringFromGUID2(GUID g, wchar_t *out, int) {
  swprintf(out, 40, L"{%08lx-0000-0000-0000-000000000000}", g.Data1);
  return 39;
}
inline DWORD GetLongPathNameW(LPCWSTR p, LPWSTR out, DWORD cap) {
  auto n = wcslen(p);
  if (n >= cap)
    return 0;
  wcscpy(out, p);
  return (DWORD)n;
}
inline HANDLE GetCurrentProcess() { return (HANDLE)2; }
inline BOOL OpenProcessToken(HANDLE, DWORD, HANDLE *out) {
  auto *h = new fake_win32::H;
  h->kind = fake_win32::H::file;
  *out = h;
  fake_win32::live_handles.push_back(h);
  return TRUE;
}
inline BOOL GetTokenInformation(HANDLE, int, void *out, DWORD cap, DWORD *n) {
  if (!out) {
    *n = sizeof(TOKEN_USER);
    return FALSE;
  }
  if (cap < sizeof(TOKEN_USER))
    return FALSE;
  ((TOKEN_USER *)out)->User.Sid = (PSID)3;
  *n = sizeof(TOKEN_USER);
  return TRUE;
}
inline BOOL ConvertSidToStringSidW(PSID, LPWSTR *out) {
  const wchar_t *s = L"S-1-5-21-fake";
  auto n = wcslen(s);
  *out = (wchar_t *)std::malloc((n + 1) * sizeof(wchar_t));
  wcscpy(*out, s);
  return TRUE;
}
inline BOOL SetFileSecurityW(LPCWSTR, DWORD, PSECURITY_DESCRIPTOR) {
  return TRUE;
}
inline BOOL ConvertStringSecurityDescriptorToSecurityDescriptorW(
    LPCWSTR s, DWORD, PSECURITY_DESCRIPTOR *out, void *) {
  auto n = (wcslen(s) + 1) * sizeof(wchar_t);
  *out = std::malloc(n);
  std::memcpy(*out, s, n);
  return TRUE;
}
inline void *LocalFree(void *p) {
  std::free(p);
  return nullptr;
}
